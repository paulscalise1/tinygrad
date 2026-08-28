# tinygrad on Intel Macs (TinyGPU with a PCIe NVIDIA GPU)

Unofficial. tinygrad upstream does not support Intel Macs (their CI has no such hardware) and this branch will not be merged
there. It works on a 2019 Mac Pro (Intel Xeon W, T2, macOS 15.6.1) with an RTX 3060 in an internal PCIe slot. Other Ampere and
Ada cards should behave the same, Blackwell is untested. Everything here is MIT licensed like tinygrad itself, see `LICENSE`.

## What this branch changes (git log master..intel-mac)

1. `tinygpu: map sysmem read+write for the GPU`: the dext passed app memory to `PrepareForDMA` as the input struct of the user
   client call, which macOS prepares read only for DMA. Intel's AppleVTD enforces that, so every GPU write into host memory was
   dropped and GSP-RM parked itself. Apple Silicon DART does not enforce it, which is why nobody saw it.
2. `tinygpu: map sysmem in windows`: no silent truncation at DriverKit's 32 segment limit (matters without an IOMMU).
3. `tinygpu: raise the server sysmem allocation cap`: 128 -> 8192.
4. `tinygpu: return a sysmem view of the mapped size`: the server allocates 16 KB minimum, only 4 KB pages are mapped, JIT graphs
   read the length from the view and faulted.
5. `cuda: compile server reads full replies`: kernel binaries over 32 KB were truncated by a short pipe read (BEAM hits it).
6. `nv: GSP boot diagnostics`: env gated, default behaviour unchanged.
7. `cuda: one docker compile server per process`: renderers are rebuilt on every unpickle, and the macOS compile server was
   started in the compiler constructor, so BEAM started a docker container per candidate (hundreds at once, which took down the
   colima docker socket). The server is now started lazily and shared per process: at most `PARALLEL` + 1 containers.

## Requirements

* Intel Mac, macOS 15, an Ampere or newer NVIDIA card in a PCIe slot (or Thunderbolt), Xcode with the DriverKit SDK.
* **SIP disabled** and `systemextensionsctl developer on`. The dext here is ad-hoc signed (the upstream signing identity is not
  available), and macOS only loads such a driver with SIP off. This lowers system security, decide for yourself.
* Docker via colima (the NVRTC compile server runs in a container), python 3.12 venv with tinygrad installed editable. The
  checkout and `TMPDIR` must live under `$HOME`: colima only shares your home directory with containers.

## Install

```sh
git clone https://github.com/paulscalise1/tinygrad.git ~/tinygrad-intel-mac && cd ~/tinygrad-intel-mac   # default branch is intel-mac
python3.12 -m venv .venv && .venv/bin/pip install -e .
colima start --cpu 8 --memory 8
docker build --platform=linux/amd64 -t cuda-amd64:v2.3 -f extra/intel_mac/Dockerfile.cuda-amd64 extra/intel_mac
sh extra/intel_mac/setup_nvcc_osx_intel.sh            # optional, nvcc shim for DEV=NV:NVCC
export TMPDIR=$HOME/.tinygrad-tmp CUDA_DOCKER_IMAGE=cuda-amd64:v2.3   # put these in ~/.zshrc
systemextensionsctl developer on
cd extra/usbgpu/tbgpu/installer && ./install_nosip.sh   # builds, installs /Applications/TinyGPU.app, activates the dext
```
Approve the extension in System Settings > General > Login Items & Extensions > Driver Extensions, then shut down fully
(not restart) and power on. Then:
```sh
extra/intel_mac/preflight.sh          # 21 checks, never touches the GPU
extra/intel_mac/first_test.sh         # test_tiny then tinygrad.llm, logs to ~/tinygpu-logs
DEV=NV .venv/bin/python -m tinygrad.llm --model llama3.2:1b-q4      # 105 tok/s on the RTX 3060
```
Faster kernels (one time search, cached): `PARALLEL=6 BEAM_TIMEOUT_SEC=60 JITBEAM=2 DEV=NV python -m tinygrad.llm`.

## Updating to a new tinygrad

```sh
extra/intel_mac/update.sh        # fetches upstream, rebases intel-mac onto it, rebuilds the app/dext
```
If the rebase conflicts, the script stops and tells you what to do. Reinstall the dext only if the commits under
`extra/usbgpu/tbgpu/installer` changed. The Python side changes take effect immediately.

## Rollback

`rm -rf /Applications/TinyGPU.app`, re-extract the official zip from `~/Library/Caches/tinygrad/downloads/TinyGPU_*.zip` and run
`/Applications/TinyGPU.app/Contents/MacOS/TinyGPU install`, `systemextensionsctl developer off`, re-enable SIP in Recovery.

`RUNBOOK.md` in this directory is the full log of how this was found and tested.

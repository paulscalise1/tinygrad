# RUNBOOK — tinygrad + TinyGPU on a 2019 Mac Pro (Intel Xeon W) with an RTX 3060 12 GB (GA106) in an internal PCIe slot

Status: **unproven platform**. All public TinyGPU successes are Apple Silicon + Thunderbolt/USB4 eGPU. Two prior *Intel Mac*
attempts (both Thunderbolt-3 eGPU, both T2 machines) kernel-panicked during GSP init — see [Prior art](#prior-art) — so
this is an experiment, run it like one: cold boot, nothing unsaved, logs on.

Everything below was set up and verified on 2026-08-18 **without a card installed** (`./preflight.sh` = 18 pass, only the
two "card visible" checks fail). Repo: `~/tinygrad-macpro` (upstream master @ `2cfb421`, local branch `macpro-intel`).

---

## 0. TL;DR — the day the card arrives

1. Shut down. Install the card (x16 slot 1 or 3 preferred; connect ONE 8‑pin aux power cable from the logic board — GA106 is
   170 W = 75 W slot + up to 150 W from the 8‑pin). Cold boot. If the slot shows as disabled in *Expansion Slot Utility*, fix
   the pool allocation there and reboot.
2. `cd ~/tinygrad-macpro && ./preflight.sh` — must be all PASS. It checks: card visible (vendor 0x10de), dext
   `[activated enabled]` **and bound** (ioreg has a `tinygpu` node), TinyGPU server launches, colima+docker, tmpdir mount,
   nvcc shim, NVRTC compile server, firmware cache. It never touches GPU registers.
3. **Cold boot again** (shutdown → wait 10 s → power on). Then `./first_test.sh`. It streams the dext log to
   `~/tinygpu-logs/`, runs `DEBUG=2 DEV=NV python3 test/test_tiny.py TestTiny.test_plus`, and on success `DEV=NV python3 -m tinygrad.llm`.
4. If the machine panics: after reboot grab `/Library/Logs/DiagnosticReports/panic-full-*.ips` (T2 machines also write
   `.../DiagnosticReports/ProxiedDevice-Bridge/`), the `~/tinygpu-logs/*` files, and file an issue (template in §7).

---

## 1. Install order (what was done, in order — repeat this if you rebuild the machine)

| # | Step | Verified by |
|---|------|-------------|
| 1 | `git clone https://github.com/tinygrad/tinygrad ~/tinygrad-macpro`, `python3.12 -m venv .venv`, `.venv/bin/pip install -e .` | `.venv/bin/python -c "import tinygrad"` |
| 2 | TinyGPU release pinned in `tinygrad/runtime/support/system.py::APLRemotePCIDevice.ensure_app` → commit `c0d024f9ff0e1dc8fdf217f255da7101d91e8323` of `tinygrad/tinygpu_releases`. Downloaded to `~/Library/Caches/tinygrad/downloads/TinyGPU_<commit>.zip` (this is exactly where tinygrad's `fetch()` looks, so `ensure_app()` will not re-download or re-run install), `ditto -xk … /Applications`. | `lipo -info` → app **and** dext binary are `x86_64 arm64`; `codesign`/`spctl` → Notarized Developer ID, team `9YG3G8543N` |
| 3 | `/Applications/TinyGPU.app/Contents/MacOS/TinyGPU install` → dext `org.tinygrad.tinygpu.driver2 (1.0.0/3)` | `systemextensionsctl list` → `[activated enabled]` (was `[activated waiting for user]` until approved in *System Settings › General › Login Items & Extensions › Driver Extensions*, and *Privacy & Security*) |
| 4 | Colima (see §2) + Intel nvcc shim: `sh extra/setup_nvcc_osx_intel.sh` → image `cuda-nvcc:12.8` (amd64), `~/.local/bin/{nvcc,nvdisasm}` → `nvccshim` | `nvcc --version` → CUDA 12.8.93; compiled a `sm_86` cubin from `$TMPDIR` |
| 5 | Native amd64 NVRTC compile-server image: `docker build --platform=linux/amd64 -t cuda-amd64:v2.3 extra/intel_mac (Dockerfile.cuda-amd64)` + 1-line local patch (see §3) | compile-server round trip via `compileserver.py` → 2728-byte cubin in ~3 s |
| 6 | GSP firmware pre-cached (see §4) | `preflight.sh` sha256-checks all three files |
| 7 | `preflight.sh`, `first_test.sh`, this file | `./preflight.sh` |

Dext matching (from the dext's Info.plist): `IOProviderClass=IOPCIDevice`, `IOPCIClassMatch=0x03000000` (VGA controller,
class 0x030000), `IOPCITunnelCompatible=1`. Nothing there is Thunderbolt-specific; an internal-slot GA106 (class 0x030000)
should match. If `preflight.sh` says "card present but dext NOT bound", check the card's class in
`system_profiler SPPCIDataType` / `ioreg -l | grep -A20 'vendor-id" = <de10'` — if the card enumerates as class 0x030200
(3D controller, headless SKUs do that) the personality will not match and that is a driver-side fix to report.

## 2. The cold-boot rule (why `first_test.sh` nags you)

`tinygrad/runtime/support/nv/nvdev.py::_early_ip_init` reads `NV_PFB_PRI_MMU_WPR2_ADDR_HI`. If it is non-zero the GPU is
"warm" — GSP already ran this power cycle (a previous tinygrad run, or anything else that booted the GSP) — and the driver
clears bus-mastering and issues a **full PCI reset** (`RemoteCmd.RESET` through the dext) before continuing. That reset is
the riskiest thing the whole init does on an unproven root complex. From a cold boot WPR2 is 0, that path is skipped, and
the flow is: bus-master on → read `NV_PMC_BOOT_0/42` (chip = GA106 → `fw_name=ga102`) → `flcn.wait_for_reset` →
`init_sw` → `init_hw` (booter_load / GSP bootloader / GSP-RM firmware). So: **every attempt starts from
shutdown → 10 s → power on**. Not a restart, not sleep/wake. macOS "restart" does not necessarily power-cycle the slot.

## 3. Colima decision — fix (b): `TMPDIR=$HOME/.tinygrad-tmp`

Problem: tinygrad's compile paths hand *absolute host paths* to programs running inside docker (nvcc shim:
`nvcc -o /var/folders/…/x.cubin /var/folders/…/y.cu`; the TinyGPU socket also defaults to `temp("tinygpu.sock")`).
Docker Desktop shares `/var/folders`; Colima shares only `$HOME` (sshfs) by default. Adding `/var/folders` as a Colima
mount fails because the reverse-sshfs mountpoint has to be created as root inside the VM.

Options considered:

* **(a)** Colima mount for `/var/folders` + a `system` provision script (`mkdir -p /var/folders && chmod 0777 /var/folders`)
  at VM boot. Works, but: needs a root hook that must be kept in `colima.yaml`, breaks silently on `colima delete`/re-create
  or a colima upgrade, reverse-sshfs of a system dir with per-user random paths (`/var/folders/xx/yyyy/T/`) is exactly the
  kind of thing that has been flaky, and it puts more surface area between "docker" and "the file exists".
* **(b) chosen** — `export TMPDIR="$HOME/.tinygrad-tmp"` before anything tinygrad-related. `tempfile.gettempdir()` (used by
  `helpers.temp()`, `NamedTemporaryFile` in `NVCCCompiler`, `cuda_disassemble`) honours `TMPDIR`, so every temp file *and*
  the `tinygpu.sock` unix socket land under `$HOME`, which Colima already shares and the shim already bind-mounts. No root,
  no VM config, survives colima re-creates. Cost: the env var must be set in every shell that runs tinygrad — it is now in
  `~/.zshrc`, and both scripts export it first thing. (It does apply to everything started from your zsh shells; if that
  ever bites, scope it: `alias tg='TMPDIR=$HOME/.tinygrad-tmp'`.)

State of your Colima (`~/.colima/default/colima.yaml`): `mounts: []` (no broken `/var/folders` mount was present — nothing
to remove), `mountType: sshfs`, `provision: []`. I bumped `cpu: 2→4`, `memory: 2→4` (GiB) so the CUDA image builds and
nvcc/nvrtc runs are not starved; revert if you want. It boots as **QEMU** on this Intel host despite `vmType: vz` — that is
what colima 0.8.1 does here and it is fine. Docker context is `colima` (`docker context use colima` if it ever flips back
to `default`). Verified: `docker run --rm -v $TMPDIR:$TMPDIR alpine sh -c 'touch $TMPDIR/.t && ls $TMPDIR'` → `.t`.

### 3a. Two compile paths on macOS, and what Intel needs for each

tinygrad's NV backend on macOS has no native nvrtc, so *both* renderers compile inside docker:

| Renderer (select with) | Compiler | What runs in docker | Intel status |
|---|---|---|---|
| `CUDA` (**default** for `DEV=NV`) | `NVRTCCompiler` → `Compiler.server(osx_docker_cmd)` = `docker run --rm -i -v <repo>:<repo> -e PYTHONPATH=<repo> ghcr.io/tinygrad/cuda-arm64:v2.3 …/compileserver.py` (a persistent stdin/stdout compile server, added 2026‑08‑17 in tinygrad #17574) | python + libnvrtc + libnvJitLink | upstream image is **arm64-only**. It *does* run here via Colima's qemu-aarch64 binfmt (verified: ~7 s startup, slow compiles). For native speed I built **`cuda-amd64:v2.3`** (`extra/intel_mac (Dockerfile.cuda-amd64)/Dockerfile`: Ubuntu 24.04 + python3.12 + cuda-nvrtc-12-8 + libnvjitlink-12-8) and applied a **1-line local patch** to `tinygrad/runtime/support/compiler_cuda.py`: `osx_docker_cmd` now uses `getenv('CUDA_DOCKER_IMAGE', 'ghcr.io/tinygrad/cuda-arm64:v2.3')`. `CUDA_DOCKER_IMAGE=cuda-amd64:v2.3` is exported by `~/.zshrc` and both scripts. Unset it (or drop the patch) to get upstream behaviour. |
| `NVCC` (`DEV=NV:NVCC`) | `NVCCCompiler` → `system("nvcc -arch=sm_86 -cubin -o … …")` → `~/.local/bin/nvcc` shim → `docker exec cuda-nvcc-persistent nvcc …` | `cuda-nvcc:12.8` (from `extra/setup_nvcc_osx_intel.sh`: `--platform=linux/amd64`, apt repo `ubuntu2204/x86_64`) | native, verified end to end from `$TMPDIR`. The Intel shim also bind-mounts `$TMPDIR` if it is *not* under `$HOME`. |

The patch is uncommitted on branch `macpro-intel` (`git diff` shows it). If you `git pull` upstream and it conflicts, the
line is trivial to re-apply; or commit it there and `git rebase origin/master`. Worth upstreaming as-is.

## 4. GSP firmware cache (no network needed on first GPU boot)

`fetch_fw()` in `tinygrad/helpers.py` downloads from
`https://gitlab.com/kernel-firmware/linux-firmware/-/raw/1e2c15348485939baf1b6d1f5a7a3b799d80703d/nvidia/<fw_name>/gsp/<file>`
into `~/Library/Caches/tinygrad/downloads/fw/<md5(url)>` and sha256-checks it. `nvdev.py` maps chip `GA1xx → fw_name=ga102`,
so a GA106 uses the **ga102** bundle. Files pulled by `tinygrad/runtime/support/nv/ip.py` for Ampere (the `fmc-570.144.bin`
chain-of-trust image is Blackwell/`NV_FLCN_COT` only, not needed):

| file | sha256 | cache name |
|---|---|---|
| `booter_load-570.144.bin` | `4497e3ef…a085b` | `78627b80666717520930fc48107fa4b8` |
| `gsp-570.144.bin` (63 MB) | `a8c3ebee…f7f` | `0e142d7e0c5e704064a8b901c3444493` |
| `bootloader-570.144.bin` | `82428f53…7fad` | `70d1d5708fd28a0090cc078fee03219f` |

Re-warm at any time (idempotent):
```sh
cd ~/tinygrad-macpro && .venv/bin/python -c "
from tinygrad.helpers import fetch_fw
for n,s in {'booter_load-570.144.bin':'4497e3eff7e95c774b8a569d17b27c08c9650158d10b229d2be81cdcad9a085b',
            'gsp-570.144.bin':'a8c3ebeed280323aedb51c061f321e73379cce7a9ae643a33dd03915df027f7f',
            'bootloader-570.144.bin':'82428f532240727e95bb3083fbaaba9b2cc7b937314323f2d546ce7245f27fad'}.items():
  print(n, len(fetch_fw('nvidia/ga102/gsp', n, s)))"
```

## 5. Debugging `init_hw` failures

Where things die matters. `DEBUG=2` (what `first_test.sh` uses) already prints "WPR2 is up. Issuing a full reset." if the
warm path is taken. Escalation:

* **`NV_DEBUG=4`** — `nvdev.py::wreg` prints every MMIO register write (`wreg: 0x<addr> = 0x<val>`), so the last line before a
  hang/panic tells you which register poke did it. Do it from another cold boot:
  `NV_DEBUG=4 ./first_test.sh 2>&1 | tee ~/tinygpu-logs/nvdebug4.log` (the script inherits the env var). Match addresses
  against the `include("dev_*", …)` register maps in `nvdev.py`/`ip.py` (e.g. `NV_PFALCON_*`, `NV_PGSP_*`, `NV_PBUS_*`).
* Python-visible symptom in #16097 was `TimeoutError: RPC queue not initialized … 0 != 4096` from `ip.py` (GSP never came
  up), *then* a panic. If you see the timeout, **stop** — do not retry warm; cold boot and collect `NV_DEBUG=4` first.
* dext-side: `~/tinygpu-logs/tinygpu-<stamp>.log` (unified log, `sender CONTAINS "tinygpu"`) — look for
  `bar mapping`, `client connected`, IOMMU/DMA errors, and `AppleVTD`/`DMAR` messages around the crash time
  (`/usr/bin/log show --last 30m --predicate 'sender CONTAINS "tinygpu" OR eventMessage CONTAINS "VTD" OR eventMessage CONTAINS "DMAR"'`).
* Panic reports: `/Library/Logs/DiagnosticReports/panic-full-*.ips` (and `ProxiedDevice-Bridge/` on T2 Macs). The 2019 Mac
  Pro is a T2 machine, so a "x86 CPU CATERR"-style report can show up under `ProxiedDevice-Bridge/` exactly like #16534.
* **`dart=0` boot-arg — last resort VT‑d/DMA diagnostic.** The DriverKit dext maps sysmem for the GPU's DMA (GSP firmware
  buffers, RPC queues) through Apple's IOMMU (`AppleVTD`/DART) on Intel. If the GSP boots but the RPC queue never
  initialises, or the panic is in `AppleVTD`, an IOMMU/DMA-remapping fault is the leading hypothesis and `dart=0`
  disables VT‑d remapping. This requires **SIP disabled** (T2: boot to Recovery ⌘R → *Startup Security Utility* → set
  Reduced Security + allow… then Terminal `csrutil disable`; reboot; `sudo nvram boot-args="dart=0"`; reboot). It lowers
  system security and disables DMA protection for *every* device — use it only to answer the diagnostic question, note the
  result in the issue, then remove it (`sudo nvram -d boot-args`, `csrutil enable`). If it makes the difference, that is a
  strong data point for the tinygpu driver authors (they'd need to fix the DMA mapping path, not you).

## 6. Prior art — Intel Macs

* **tinygrad #16097** — *NV backend kernel panic on Intel MacBook Pro (2019, T2) with RTX 3060 Ti (GA104) eGPU via Razer
  Core X (TB3)*, macOS 15.7.5. Dext bound, BAR mapping OK, socket OK, kernels compiled; `NVDev.init_hw()` → `TimeoutError:
  RPC queue not initialized (0 != 4096)` → hard panic with no recoverable backtrace ("paniclog CRC mismatch"). Also noted:
  the arm64 nvcc script needed the same amd64/x86_64 edits we made in `extra/setup_nvcc_osx_intel.sh`, and the auto-launched
  TinyGPU server via `Popen` was unreliable → launch it manually (`first_test.sh` does).
* **tinygrad #16534** — *Kernel panic (x86 CPU CATERR) on Intel MacBook Pro 2020 (T2) initialising RTX 3080 (GA102) via
  AORUS Gaming Box (TB3)*, macOS 15.7.7. 100 % reproducible on any `DEV=NV` compute; panic reports under
  `/Library/Logs/DiagnosticReports/ProxiedDevice-Bridge/panic-full-*.ips` with `x86 CPU CATERR detected`, `PCIeUp link
  state`, stack in `AppleEmbeddedPCIeUpLinkMgmt`. Author suggested Intel/T2 be documented unsupported or fail fast.

What is different here (and why it is worth trying): **no Thunderbolt** — the card sits directly on the Xeon's PCIe root
complex behind the Mac Pro's PLX switch, so the TB3/`PCIeUp` bridge implicated in #16534 is out of the picture. What is the
same: T2/BridgeOS, Intel VT‑d, and a dext that has only ever been exercised on Apple Silicon DARTs. Either way the result
is a data point nobody has.

## 7. Filing the report (either outcome)

Include: machine (MacPro7,1, macOS `sw_vers`), slot + power cabling, `system_profiler SPPCIDataType` for the card (link
width/speed, class), `systemextensionsctl list` line, TinyGPU zip commit `c0d024f9…`, tinygrad commit + `git diff` (the
`CUDA_DOCKER_IMAGE` patch), Colima 0.8.1/QEMU + fix (b), the `preflight.sh` output, `~/tinygpu-logs/*` for the run
(test_tiny log, dext log, server log), `NV_DEBUG=4` tail if you got one, and the `.ips` panic report(s) if it panicked.
Reference #16097 and #16534 and say explicitly "internal PCIe slot, not Thunderbolt" — that is the new information.

## Appendix — paths

* Repo/venv: `~/tinygrad-macpro`, `.venv/bin/python` (3.12.4)
* TinyGPU: `/Applications/TinyGPU.app` (`… /Contents/MacOS/TinyGPU server <sock>` / `install`), zip cached at
  `~/Library/Caches/tinygrad/downloads/TinyGPU_c0d024f9ff0e1dc8fdf217f255da7101d91e8323.zip`
* Temp/socket: `~/.tinygrad-tmp/` (`tinygpu.sock`), logs: `~/tinygpu-logs/`
* Docker images: `cuda-nvcc:12.8` (shim), `cuda-amd64:v2.3` (compile server), `ghcr.io/tinygrad/cuda-arm64:v2.3` (upstream, qemu)
* Firmware: `~/Library/Caches/tinygrad/downloads/fw/`
* Shell env (`~/.zshrc`): `TMPDIR`, `PATH+=~/.local/bin`, `CUDA_DOCKER_IMAGE`

## 8. Results log

### 2026-08-26 — card installed (Slot 3, x16 @ 8 GT/s, GA106 0x2504, dext bound). Three cold-boot runs, **no panic**.

**Runs 1–2 (VT-d on):** deterministic `TimeoutError: RPC queue not initialized (0 != 4096)` (10 s and 60 s timeouts — same).
Everything before the RPC wait succeeded with hardware acknowledgement: BARs mapped, 9 `PrepareDMA` sysmem buffers
(`large_bar` is False, all boot memory is real sysmem, every buffer a single IOVA segment), FRTS ran and set WPR2
(`WPR2_ADDR_HI=0x02ffee00`), **booter ran on SEC2 and returned mailbox 0** (the SEC2 falcon DMA engine *read* the 63 MB GSP-RM
image out of sysmem fine), GSP RISC-V core went active.

Post-mortem dump (patched `ip.py::NV_GSP.dump_boot_state`, run 2, `~/tinygpu-logs/gsp-logbuf-20260826-165205.bin`):

* `GSP RISCV_CPUCTL = 0x10` → `halted=1, active_stat=0` — the GSP core started, then **halted**.
* `GSP MAILBOX0 = 0x80000000` — the value nouveau treats as "GSP-RM has shut down / halted" (`r535_gsp_fini` waits for it).
* All five libos log regions and the RPC stat-queue header: **untouched by the GSP**. (The 16 non-zero bytes at the head of
  LOGINIT, `0x111400000 / 0x200000`, are the dext's own `(paddr,size)` descriptor table that it writes at the start of every
  mapping — not a GSP write. `alloc_sysmem` now zeroes it.)
* No VT-d/IOMMU/PCIe messages in the unified log; SEC2 mailbox 0; `BSI_SECURE_SCRATCH_14=0x13100000`.

Reading: the SEC2 falcon's DMA reads from sysmem work, but the GSP RISC-V core (own MMU, 64-bit sysmem accesses) never
managed a single write to host memory and halted. Consistent with the RISC-V-side DMA path being blocked/mis-mapped
(AppleVTD) rather than a tinygrad sequencing bug.

**Run 3 (`dart=0`, SIP off):** never reached the GPU. With DMA remapping off the dext returns real physical scatter lists and
**caps `PrepareDMA` at 32 segments, silently truncating** (`PrepareDMA size=63676416 segs=32`); tinygrad's radix3 build then
failed with `ValueError: memoryview assignment: lvalue and rvalue have different structures` in `init_gsp_image`. Inconclusive
for the GSP question; it is a dext limitation worth reporting on its own. Mitigation added (uncommitted, `system.py`):
`NV_SYSMEM_CONTIG=1` asks the dext for physically contiguous buffers for every alloc, and a truncated list now raises a clear
error instead of the memoryview one. Whether the dext honours `contiguous` without an IOMMU is untested (with VT-d on, both
flavours come back as one segment).

**Run 4 (`dart=0` verified via `sysctl kern.bootargs`, `NV_SYSMEM_CONTIG=1`):** the dext ignores the contiguous flag without
an IOMMU — even the first 0x81000-byte alloc came back as `segs=32` covering 0x20000 bytes (32 × 4 KB pages, i.e. the dext
maps page-by-page and stops at 32). Failed cleanly in `init_rm_args` before any GPU access. **Conclusion: the `dart=0`
experiment cannot be run with this dext build** (max 128 KB per sysmem alloc without DMA remapping). The IOMMU question is
for the TinyGPU dext authors, not answerable here. Boot-args reverted; remember to re-enable SIP (Recovery → `csrutil enable`,
Full Security).

## 9. Research notes (2026-08-26 evening) and the run-5 recipe

Sources: NVIDIA open-gpu-kernel-modules (570 branch, sparse clone in the session scratchpad: `kernel_gsp*.c`, `kernel_crashcat_engine*.c`,
`nv-crashcat.h`, `gsp_fw_wpr_meta.h`, `rpc.c`), nouveau r535 GSP code, and the installed TinyGPU dext/app binaries.

What the run-2 post-mortem actually means (from OpenRM):

* `MAILBOX0 == 0x80000000` after the halt is exactly what `_kgspIsProcessorSuspended` (kernel_gsp_tu102.c) waits for:
  `LIBOS_INTERRUPT_PROCESSOR_SUSPENDED`. libos wrote it, i.e. the GSP core suspended itself on purpose (GSP-RM shutdown/panic path),
  it did not wedge. `CPUCTL halted=1` matches.
* OpenRM's first-line diagnostic for this is **CrashCat**: a halted GSP leaves a wayfinder (`0xdead` signature) in
  `NV_PFALCON_FALCON_DEBUGINFO` (GSP base 0x110000 + 0x94) whose L1 pointer lives in MAILBOX0/1 or `COMMON_SCRATCH_GROUP_0..3`
  (0x110300..0x11033c) and points at a report queue in the falcon's DMEM/EMEM (readable through the DMEMC/DMEMD ports at
  0x1101c0/0x1101c4 or EMEMC/EMEMD 0x110ac0/0x110ac4) or in a host-provided sysmem buffer
  (`GspFwWprMeta.sysmemAddrOfCrashReportQueue`, 4 KB, OpenRM always sets it, tinygrad never did). A report carries cause
  (EXCEPTION/TIMEOUT/PANIC/WATCHDOG), the faulting PC, and RISC-V CSRs (`xcause`, `xtval`, `xepc`), all readable over BAR0.
* The Booter writes `GspFwWprMeta.verified = 0xa0a0a0a0a0a0a0a0` into the WPR meta **in sysmem** when it validates it. Reading that
  field back on the host after boot is a direct GPU-write-to-sysmem visibility test that needs no GSP-RM cooperation.
* OpenRM allocates every GSP sysmem buffer (message queues, radix3 image, boot args) as `ADDR_SYSMEM, NV_MEMORY_CACHED`, so the
  whole design assumes snooped/coherent DMA. If DMA on this platform were not coherent, host caches would hide GPU writes; the
  dump now clflushes and re-reads to test that.
* tinygrad's `bar_info()` on macOS returns the dext's mapping addresses (`0x1043f7000`, ...), not the PCI BAR addresses
  (ioreg `assigned-addresses`: BAR0 `0x76000000`, BAR1 `0xb0000000000`, BAR3 `0xb0010000000`). Those go into
  `GspSystemInfo.gpuPhysAddr/gpuPhysFbAddr/gpuPhysInstAddr`. Same on Apple Silicon where it works, so unlikely to be the cause,
  but wrong and worth fixing (read `assigned-addresses` from ioreg).
* Booter success criterion in OpenRM is the same as tinygrad's (SEC2 MAILBOX0 == 0 after execution), so "booter OK" is real.

Local diagnostics added to `tinygrad/runtime/support/nv/ip.py` and `system.py` (all env-gated, default behaviour unchanged):

| knob | effect |
|---|---|
| `NV_RPC_TIMEOUT_MS` | RPC-queue wait timeout (default 10000) |
| (always, on timeout) | `dump_boot_state`: log regions, queue header, GSP/SEC2 registers, WPR meta `verified` flag, clflush coherency probe, CrashCat wayfinder/queue decode, raw dumps in `~/tinygpu-logs/` |
| `NV_GSP_LOGS_FB=1` | put the five libos log regions in VRAM (`LIBOS_MEMORY_REGION_LOC_FB`) so the GSP boot log is readable over BAR1 even if sysmem writes fail |
| `NV_CRASHCAT_SYSMEM=1` | give GSP-RM a 4 KB sysmem CrashCat queue via the WPR meta, like OpenRM |
| `NV_SYSMEM_CONTIG=1` | ask the dext for contiguous sysmem (dext ignores it without an IOMMU, see run 4) |

**Run 5 (VT-d on, normal boot-args, cold boot, colima started):**
```sh
NV_GSP_LOGS_FB=1 NV_CRASHCAT_SYSMEM=1 NV_DEBUG=4 NV_RPC_TIMEOUT_MS=60000 ./first_test.sh 2>&1 | tee ~/tinygpu-logs/run5.log
```
Read the `GSP boot state dump:` block: `wpr_meta ... verified` (did a GPU write reach the host), `coherency probe` (hidden writes in
DRAM), `LOG*` fill levels (now in VRAM, did libos run at all), `crashcat` lines (why it stopped, with PC and CSRs).

## 10. Root cause (2026-08-26 late) and the dext fix

**The TinyGPU dext maps every sysmem buffer read-only for the GPU on Intel Macs.** Chain of evidence, all from source:

1. `extra/usbgpu/tbgpu/installer/Shared/server.c::map_sysmem_fd` passes the whole shm buffer as the **input** struct of
   `IOConnectCallStructMethod(g_conn, 3, ptr, alloc_sz, paddr_buf, &out_sz)`.
2. For an out-of-line input struct the kernel wraps the caller's pages in a `kIODirectionOut` descriptor (xnu `IOUserClient.cpp`).
3. The dext (`TinyGPUDriverUserClient.cpp`, PrepareDMA branch) hands exactly that descriptor to `IODMACommand::PrepareForDMA`.
   In xnu `IOMemoryDescriptor.cpp:4126-4129`, `kIODirectionOut` wires the pages with `UPL_COPYOUT_FROM` and
   `fDMAAccess = kIODMAMapReadAccess` (read-only for the device); `IOGeneralMemoryDescriptor::dmaMap` passes that access to the
   mapper, and `AppleVTD.cpp:567-568` turns it into the VT-d page-table access bits.
4. Result on any Intel Mac with VT-d: the GPU can read everything (booter succeeds, `verified` never readable back), but every GPU
   write into host memory is dropped by the IOMMU, silently (AppleVTD only logs faults from its fault interrupt). GSP-RM cannot post
   its libos logs or the RPC status-queue header, parks itself (`MAILBOX0 = 0x80000000`, halted), and the driver times out. Apple
   Silicon's DART evidently does not enforce the read-only bit, which is why the same dext works there. Both Intel-Mac reports
   (#16097 and this one) die at exactly this first device write.
5. Second bug, independent: `IOAddressSegment segments[32]` is the DriverKit `PrepareForDMA` ABI limit per call. With an IOMMU the
   buffer is one segment so it never matters; without one (`dart=0`) it silently truncates at 32 pages. The `contiguous` flag never
   reaches the dext (dropped in `server.c`) and could not be honoured for app-owned shm anyway.

The `PrepareForDMA` output `flags` (returned but discarded by the dext) would have said it all along: on this machine it returns only
`kIOMemoryDirectionOut` = "memory is readable".

**The fix (uncommitted, branch `macpro-intel`, `git diff -- extra/usbgpu/tbgpu/installer`, also saved as
`~/tinygpu-logs/upload/tinygpu-dext-rw-dma.diff`):**

* `server.c`: pass the shm as the **output** struct (the kernel wraps ool output in a writable `kIODirectionIn` descriptor) and a
  small inband input struct carrying the request flags. The dext writes the `[paddr,len]...(0,0)` table to the head of the buffer
  itself, so the `paddr_buf` copy goes away. Python side unchanged.
* dext `TinyGPUDriverUserClient.cpp`: wrap the output descriptor with `IOMemoryDescriptor::CreateWithMemoryDescriptors(
  kIOMemoryDirectionInOut, 1, ...)` (first attempt used `In`: the kernel reports `flags` from the wrapper's own direction bits,
  `IOUserServer.cpp PrepareForDMA_Impl: mdFlags = fMemory->getFlags()`, so the dext's own read+write check refused it with
  `flags=0x1`, harmlessly, before any GPU access. Run 5a, 2026-08-26 20:36.) The multi-descriptor has no `dmaMap` override, so the base `IOMemoryDescriptor::dmaMap` runs
  (`IOMemoryDescriptor.cpp:4508-4520`): read access plus write access whenever the descriptor is not `PreparedReadOnly`, i.e. a
  read+write IOMMU mapping. Map the buffer in <=32-segment windows (one `IODMACommand` each), fail instead of truncating, refuse
  a mapping whose returned flags are not read+write, and log the flags.
* `TinyGPUDriver.cpp/.iig`: `SetupDMA` takes an offset and returns the flags; the DMA record keeps the wrapper alive until `Stop`.

Built successfully with the project's own dev flow: `cd extra/usbgpu/tbgpu/installer && ./install_nosip.sh --build`
(Xcode 26.0.1, DriverKit SDK 25.0, ad-hoc signed, `build/Debug/TinyGPU.app`). **Not installed yet.**

**Installing and testing the dev build (SIP must stay disabled for an ad-hoc-signed dext):**
```sh
systemextensionsctl developer on            # allow the dev dext to replace the signed one
cd ~/tinygrad-macpro/extra/usbgpu/tbgpu/installer && ./install_nosip.sh   # replaces /Applications/TinyGPU.app, runs "TinyGPU install"
# approve the extension in System Settings > General > Login Items & Extensions > Driver Extensions if prompted, then FULL SHUTDOWN
# after the cold boot:
systemextensionsctl list | grep tinygpu     # must be [activated enabled]; ioreg must show the dext bound
colima start && cd ~/tinygrad-macpro && ./preflight.sh
NV_DEBUG=4 NV_RPC_TIMEOUT_MS=60000 ./first_test.sh 2>&1 | tee ~/tinygpu-logs/run5-fixeddext.log
```
What to look for: the dext log line now reads `PrepareDMA size=... segs=N windows=1 flags=0x3` (0x3 = read+write); with the old
dext it would have been 0x2. Then either the test passes, or the `GSP boot state dump` (WPR meta `verified` flag, `IRQSTAT SWGEN0`,
CrashCat) tells the next story.

**Rollback to the signed release build:** `rm -rf /Applications/TinyGPU.app && ditto -xk
~/Library/Caches/tinygrad/downloads/TinyGPU_c0d024f9ff0e1dc8fdf217f255da7101d91e8323.zip /Applications &&
/Applications/TinyGPU.app/Contents/MacOS/TinyGPU install`, then `systemextensionsctl developer off`, reboot, and re-enable SIP
(Recovery: `csrutil enable`, Full Security) when done experimenting.

Other knobs added today for the run: `NV_FLUSH_BOOT=1` (clflush all sysmem boot buffers before the GPU starts, mirrors OpenRM's
uncached libos init-args page), plus the §9 ones. The dump now also prints `IRQSTAT` (bit 6 = GSP posted a message), `EXTERRSTAT/
ADDR`, `BR_RETCODE`, `BCR_DMACFG`, and `PCI_STATUS`.

### Run 5b (2026-08-26 20:43) with the patched dext: **PASS**

`test_tiny.py TestTiny.test_plus` -> `OK` (4.96 s): GSP-RM booted, the CPU sequencer ran (SEC2-RTOS reload), kernels compiled through the
docker NVRTC server and executed on the RTX 3060 (`*** NV 3 E_3 ... tm 3.33us`). `first_test.sh` then started `tinygrad.llm`, whose
new process found WPR2 set, took the **warm path (full PCI reset through the dext)**, re-booted GSP-RM and loaded Llama 3.2 1B
onto the card (`using model "Llama 3.2 1B Instruct" ... on NV`). No kernel panic. Dext log: every buffer `PrepareDMA ...
windows=1 flags=0x3` (86 mappings). First known tinygrad NV run on an Intel Mac.

Keep the dev dext + `systemextensionsctl developer on` + SIP off until a signed TinyGPU release contains the fix: the signed build
(2026-03-31) still has the read-only mapping. Logs: `~/tinygpu-logs/run5b-fixeddext.log`, `tinygpu-20260826-204337.log`.

## 11. Getting `tinygrad.llm` to run (2026-08-26 evening)

Two more problems after the dext fix, both solved:

1. `NVRTC_ERROR_COMPILATION: cannot open source file "cuda_fp16.h"`: the amd64 compile-server image had libnvrtc but no CUDA headers
   and no `/usr/local/cuda` symlink (tinygrad passes `-I/usr/local/cuda/include`). `extra/intel_mac (Dockerfile.cuda-amd64)/Dockerfile` now also
   installs `cuda-cudart-dev-12-8` and symlinks `/usr/local/cuda`; rebuilt as `cuda-amd64:v2.3`. `jinja2` installed in the venv for
   the chat template, `numpy`/`pytest` for tests.
2. `RuntimeError: Device fault detected` (GSP `MMU_FAULT_QUEUED`) as soon as the JIT used graphs (`JIT=0` and `JIT=2` were fine,
   `HCQ_NO_BIND` was fine, `JIT_BATCH_SIZE=4` still faulted, padding the bound pushbuffer by 64 KB fixed it). Root cause, tinygrad
   side: `APLRemotePCIDevice.alloc_sysmem` returned a CPU view of the server's allocation (minimum 16 KB) while only
   `ceil(size/4K)` pages are mapped into the GPU. `NVCommandQueue.bind` takes the command length from `len(cpu_view)`, so the GPFIFO
   entry claimed 16 KB of commands with only 4 KB mapped and the pushbuffer fetch ran off the mapping. Apple Silicon has 16 KB pages
   so the rounding matches there and nobody saw it. Fix (uncommitted, `system.py`): return `memview.view(0, round_up(size, 4K))`.
   General compute was never affected (`scratchpad/stress.py`: matmul/softmax/sum/fp16/64 MB round trips all match numpy).

Run it:
```sh
cd ~/tinygrad-macpro && DEV=NV .venv/bin/python -m tinygrad.llm
```
First response is slow (every new kernel shape compiles through docker, cached afterwards). Each process finds the GPU warm and
does the PCI reset through the dext, which is fine.

## 12. Untested / caveats for upstreaming

* **Apple Silicon regression risk is untested.** The dext change swaps the DMA buffer from the input struct to the output struct and
  wraps it in an InOut multi-descriptor. On Intel/AppleVTD this is what makes device writes work. On Apple Silicon the DART mapper
  already allowed writes with the old code, so the change should be a no-op there, but nobody has run the patched dext on an
  M-series Mac. The PR must say so and a maintainer with Apple Silicon has to run it before it ships in a signed release.
* The <=32-segment windowing in the dext has only run with `windows=1` (with an IOMMU every buffer is one segment). The
  multi-window path (no IOMMU, `dart=0`) compiles but is untested.
* `contiguous` is still not honoured for app-owned shm (documented in the dext log line).
* Sleep/wake with the GPU initialised, multi-hour sessions, and models larger than 1B are untested on this machine.

## 13. Test results on the RTX 3060 (2026-08-26 22:18-22:33, patched dext, default JIT)

| test | result | notes |
|---|---|---|
| `test/backend/test_ops.py` | 415 passed, 9 skipped, 126 subtests passed, 3 failed | the 3 failures are torch-2.2.2 reference artifacts (Intel Macs cannot get newer torch): `cummax/cummin` expect an `IndexError` old torch does not raise, `scaled_dot_product_attention_gqa` uses torch's `enable_gqa` kwarg which 2.2 lacks. No GPU miscomputation. |
| `test_jit.py` | 17 passed, 9 skipped | |
| `test_graph.py` | 10 passed, 1 skipped | first run had 4 failures from the TinyGPU server's `MAX_SYSMEM 128` cap (sysmem allocations are never freed for the life of the server); raised to 8192 in `server.c`, app rebuilt and swapped in without touching the dext. Worth upstreaming, not Intel specific. |
| `test_dtype.py` | 166 passed, 26 skipped, 26 failed | all failures from the torch 2.2.2 / numpy 1.26 reference environment (`torch.view(None)` in `test_bitcast`, unwrapped numpy 1.x targets in `test_uint_overflow`), the GPU values were right. |
| `test_nn.py` | 43 skipped | nothing applicable |
| `test_llama_kernels.py` | passed | |
| `tinygrad.llm --benchmark 200` (1B) | 200 tokens, 18.9 tok/s, 20.9 GB/s, no fault | |
| `tinygrad.llm --model llama3.2:3b` | correct answer (Rayleigh scattering), no fault | 2.6 GB weights |

Environment notes: `.venv` now has torch 2.2.2 + numpy 1.26.4 (needed for the reference tests, tinygrad itself is fine either way),
pytest, pytest-timeout, jinja2. Test scripts and logs: `~/tinygpu-logs/testsuite*.sh`, `suite-*.log`.
Python: `system.py _rpc` now raises a clear `RuntimeError` when the server refuses `MAP_SYSMEM_FD` instead of an `IndexError`.

## 14. Performance: BEAM search, and two more issues it exposed (2026-08-27)

Default kernels: 18.9 tok/s on Llama 3.2 1B (Q6_K). Microbenchmarks show the card is fine (fp16 matmul 15.9 TFLOPS, copy
265 GB/s, TinyGPU socket RPC 24 us/read 4 us/write). One token was 233 kernels and 42.7 ms of GPU time: the default kernel
shapes are poor GEMV kernels. Upstream's advice in `docs/tinygpu.md` is `JITBEAM=2`.

`JITBEAM=2` result: **81.6 tok/s** (12.3 ms/token, 85 GB/s), 4.3x. Search results are cached in `~/Library/Caches/tinygrad/cache.db`
(table `beam_search_*`), so later runs start fast. Run with:
```sh
PARALLEL=6 BEAM_TIMEOUT_SEC=60 JITBEAM=2 DEV=NV .venv/bin/python -m tinygrad.llm
```
Getting there needed three fixes:
1. BEAM's worker pool defaults to `cpu_count()` (32 here) and each worker starts its own docker compile-server container. 32
   containers in the 4 GB colima VM killed the docker daemon. Colima is now 8 CPU / 8 GB (`colima start --cpu 8 --memory 8`, saved
   in colima.yaml) and BEAM runs with `PARALLEL=6`.
2. `Compiler.compile_server` (device.py) read the reply with a single `read(n)` on an unbuffered pipe, which returns at most the
   pipe buffer (32 KB). Any kernel binary over ~32 KB came back truncated (exactly 32764 bytes), was cached as valid, failed to
   load (`ValueError: Buffer size too small (0 ...)` in `elf_loader`) and left the pipe out of sync for the next request. Fixed by
   reading until the full length arrives. The compile path also restarts its server after any failed exchange
   (`compiler_cuda.py`). Both worth upstreaming, they affect every macOS user whose kernels exceed 32 KB (BEAM hits it quickly).
3. `BEAM_TIMEOUT_SEC` raised from the 10 s default to 60 s: candidate compiles through docker can take longer under load.

Note: purging the poisoned cache entries wiped the whole `compile_nv_sm_86_22` table (the values are pickled, so an ELF-magic
check matched nothing). Harmless, kernels recompile on first use, the BEAM choices in `beam_search_22` were kept.

Q4_K_M variant (`--model llama3.2:1b-q4`) with `JITBEAM=2`: **105 tok/s** (9.5 ms/token, 87 GB/s). Bandwidth-bound decode
scales with weight bytes, so lower-bit quantization is the biggest native lever after BEAM.

Per-token profile of the BEAM'd Q6 decode (PROFILE=1, graph timestamps): the JIT splits one token into graphs of 32 + 64 + 128
kernels (the transformer layers) plus a 10-kernel lm-head graph, spans 1.24 + 2.57 + 5.55 + 2.87 = 12.2 ms with zero gaps, so
the GPU is busy the whole 12.3 ms/token. The time is in the weight-streaming reductions: the per-layer GEMV kernels
(`r_256_16_2_4_2_2_2_2_32` 171 us, `r_512_8_...` 96 us) move ~80-90 GB/s against 265 GB/s measured copy bandwidth, and the lm-head
kernel (`r_4008_16_...`, 2.4 ms for the 214 MB Q6 vocab matrix, ~89 GB/s) is a fifth of the token by itself. Tiny kernels are
negligible (64 kernels under 20 us total 0.18 ms). Remaining headroom is kernel quality for quantized GEMV (upstream codegen),
not launch overhead, CPU, or the TinyGPU path.
`JITBEAM=4` on the Q6 model: 81.4 tok/s, no gain over `JITBEAM=2` (81.6). The search is saturated at this kernel-generation
quality, use `JITBEAM=2`.

## 15. Upstream status (2026-08-27)

#17767 (everything in one PR) was closed by geohot after nimlgen asked for smaller logical parts. Resubmitted as:
* #17776 `tinygpu-rw-dma`: the read plus write mapping fix (dext + server), the actual fix for #17763.
* #17777 `tinygpu-sysmem-view`: `alloc_sysmem` returns a view of the mapped size, clear error when the server refuses an fd.
* #17778 `tinygpu-sysmem-cap`: `MAX_SYSMEM` 128 -> 8192.
* #17779 `tinygpu-dma-windows` (draft, stacked on #17776): map in windows of 32 segments instead of truncating.
Branches live in the `~/tinygrad-pr` worktree and on the fork `paulscalise1/tinygrad`. PR bodies: `~/tinygpu-logs/pr-split/`.
Still local only: the compile-server short-read fix and server restart (`device.py`, `compiler_cuda.py`), the amd64 docker image
and `CUDA_DOCKER_IMAGE`, and the GSP diagnostics in `nv/ip.py`.

Update, 2026-08-27 18:40: geohot closed all four split PRs within a minute. On #17776: "Intel Macs are not supported. I'd merge
an assert for that but that's it. Also, these PRs aren't close to the bar for tinygrad". On #17778 and #17779: "no ai"
(tinygrad does not accept AI-written contributions). Decision: no further upstream PRs. The fixes stay on the local branches
(`macpro-intel` working tree, `~/tinygrad-pr` worktree) and keep working here; keep the dev dext + SIP off. If a future signed
TinyGPU release changes the DMA mapping, re-test before switching back to it.

#!/bin/bash
# preflight.sh -- pass/fail checks before the first DEV=NV run on the 2019 Mac Pro (Intel) + RTX 3060 + TinyGPU.
# Safe to run any time: it never touches the GPU registers (no DEV=NV), only inspects the host, driver, docker and caches.
# Usage: ./preflight.sh            (from the repo root, no sudo needed)

# --- Colima decision (b): tinygrad temp files + the TinyGPU unix socket live under $HOME, which Colima shares with the VM.
export TMPDIR="$HOME/.tinygrad-tmp"; mkdir -p "$TMPDIR"
export PATH="$HOME/.local/bin:$PATH"
export CUDA_DOCKER_IMAGE="${CUDA_DOCKER_IMAGE:-cuda-amd64:v2.3}"

cd "$(dirname "$0")" || exit 1
[ -x .venv/bin/python ] && PY=.venv/bin/python || PY=python3
APP=/Applications/TinyGPU.app/Contents/MacOS/TinyGPU
DEXT=org.tinygrad.tinygpu.driver2
pass=0; fail=0; warn=0
ok()   { printf '\033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '\033[31mFAIL\033[0m  %s\n' "$1"; [ -n "$2" ] && printf '      -> %s\n' "$2"; fail=$((fail+1)); }
wrn()  { printf '\033[33mWARN\033[0m  %s\n' "$1"; [ -n "$2" ] && printf '      -> %s\n' "$2"; warn=$((warn+1)); }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

hdr "host"
echo "TMPDIR=$TMPDIR  python=$($PY --version 2>&1)  $(sw_vers -productVersion) $(uname -m)"
$PY -c "import tinygrad" 2>/dev/null && ok "tinygrad importable from $PY" || bad "tinygrad not importable" "cd $(pwd) && python3.12 -m venv .venv && .venv/bin/pip install -e ."
[ "$(uname -m)" = "x86_64" ] && ok "x86_64 host" || wrn "not x86_64 -- these scripts target the Intel Mac Pro"

hdr "GPU visible on PCIe (vendor 0x10de)"
PCI=$(system_profiler SPPCIDataType 2>/dev/null)
if echo "$PCI" | grep -qi "Vendor ID: 0x10de"; then
  ok "system_profiler shows an NVIDIA device:"
  echo "$PCI" | grep -B8 -i "Vendor ID: 0x10de" | grep -E "^\s{6}[^ ]|Type|Driver Installed|Slot|Link Width|Link Speed|Device ID|Vendor ID" | sed 's/^/      /'
else
  bad "no PCI device with vendor 0x10de (card not installed / not seated / slot unpowered)" "check Expansion Slot Utility + 8-pin aux power (3060 needs 1x8-pin, ~170W)"
fi
IOREG=$(ioreg -l -p IODeviceTree 2>/dev/null; ioreg -l 2>/dev/null)
echo "$IOREG" | grep -q '"vendor-id" = <de10' && ok "ioreg shows vendor-id 0x10de" || bad "ioreg has no vendor-id 0x10de node"

hdr "TinyGPU app + dext"
[ -x "$APP" ] && ok "TinyGPU.app installed ($APP)" || bad "TinyGPU.app missing" "ditto -xk ~/Library/Caches/tinygrad/downloads/TinyGPU_*.zip /Applications && $APP install"
if [ -x "$APP" ]; then
  lipo -info "$APP" 2>/dev/null | grep -q x86_64 && ok "TinyGPU app binary has x86_64 slice" || bad "TinyGPU app binary has no x86_64 slice"
  DEXTBIN="/Applications/TinyGPU.app/Contents/Library/SystemExtensions/$DEXT.dext/$DEXT"
  lipo -info "$DEXTBIN" 2>/dev/null | grep -q x86_64 && ok "dext binary has x86_64 slice" || bad "dext binary has no x86_64 slice"
fi
SEL=$(systemextensionsctl list 2>/dev/null | grep "$DEXT")
if echo "$SEL" | grep -q "activated enabled"; then ok "dext $DEXT [activated enabled]"
elif echo "$SEL" | grep -q "waiting for user"; then bad "dext is [activated waiting for user]" "System Settings > General > Login Items & Extensions > Driver Extensions > enable TinyGPU (also Privacy & Security), then re-run"
elif [ -n "$SEL" ]; then bad "dext state: $SEL"
else bad "dext not registered" "$APP install"; fi
if echo "$IOREG" | grep -q "org.tinygrad.tinygpu.driver2"; then
  ok "dext is bound to a device (ioreg has driver-child-bundle $DEXT)"
  echo "$IOREG" | grep -E "tinygpu|IOUserServerName" | head -3 | sed 's/^/      /'
else
  if echo "$PCI" | grep -qi "Vendor ID: 0x10de"; then bad "card present but dext NOT bound (ioreg has no tinygpu node)" "check '/usr/bin/log show --last 10m --predicate \"sender CONTAINS \\\"tinygpu\\\"\"' and IOPCIClassMatch 0x03000000 vs the card's class"
  else wrn "dext not bound (expected: no card installed yet)"; fi
fi

hdr "TinyGPU server launches"
if [ -x "$APP" ]; then
  S="$TMPDIR/preflight-tinygpu.sock"; rm -f "$S"
  "$APP" server "$S" >"$TMPDIR/preflight-tinygpu.log" 2>&1 & SP=$!
  for i in $(seq 1 40); do [ -S "$S" ] && break; sleep 0.1; done
  if [ -S "$S" ]; then ok "TinyGPU server created socket $S (pid $SP)"
    kill $SP 2>/dev/null; wait $SP 2>/dev/null
  else
    if kill -0 $SP 2>/dev/null; then wrn "server process alive but no socket after 4s (log: $TMPDIR/preflight-tinygpu.log)"; kill $SP 2>/dev/null
    else bad "TinyGPU server exited immediately" "$(head -c 300 "$TMPDIR/preflight-tinygpu.log")"; fi
  fi
  rm -f "$S"
fi

hdr "colima / docker"
if colima status >/dev/null 2>&1; then ok "colima running ($(colima status 2>&1 | grep -o 'arch: [a-z0-9_]*'))"; else bad "colima not running" "colima start"; fi
if docker info >/dev/null 2>&1; then ok "docker CLI connected (context: $(docker context show 2>/dev/null), server arch: $(docker info --format '{{.Architecture}}' 2>/dev/null))"
else bad "docker CLI cannot reach daemon" "docker context use colima"; fi
if docker run --rm -v "$TMPDIR":"$TMPDIR" alpine sh -c "touch $TMPDIR/.preflight_t && ls $TMPDIR/.preflight_t" >/dev/null 2>&1 && [ -f "$TMPDIR/.preflight_t" ]; then
  ok "TMPDIR ($TMPDIR) is writable from inside a container and visible on the host"; rm -f "$TMPDIR/.preflight_t"
else bad "TMPDIR bind-mount test failed" "colima must share \$HOME (default). Check: colima ssh -- ls $TMPDIR"; fi

hdr "nvcc shim (DEV=NV:NVCC path)"
docker image inspect cuda-nvcc:12.8 >/dev/null 2>&1 && ok "image cuda-nvcc:12.8 present ($(docker image inspect cuda-nvcc:12.8 --format '{{.Architecture}}'))" || bad "image cuda-nvcc:12.8 missing" "sh extra/setup_nvcc_osx_intel.sh"
[ -x "$HOME/.local/bin/nvcc" ] && ok "~/.local/bin/nvcc shim installed" || bad "~/.local/bin/nvcc missing" "sh extra/setup_nvcc_osx_intel.sh"
if V=$(nvcc --version 2>&1) && echo "$V" | grep -q "release"; then ok "nvcc --version through shim: $(echo "$V" | grep release | sed 's/^ *//')"; else bad "nvcc shim failed" "$V"; fi
CU="$TMPDIR/preflight_$$.cu"; printf 'extern "C" __global__ void k(float* a){a[threadIdx.x]=1.f;}\n' > "$CU"
if nvcc -arch=sm_86 -cubin -o "$CU.cubin" "$CU" >/dev/null 2>&1 && [ -s "$CU.cubin" ]; then ok "nvcc compiled a sm_86 (GA106) kernel from TMPDIR end-to-end"; else bad "nvcc could not compile a file from TMPDIR" "shim mounts \$HOME; TMPDIR must be under \$HOME"; fi
rm -f "$CU" "$CU.cubin"

hdr "NVRTC compile server image (default DEV=NV path)"
if docker image inspect "$CUDA_DOCKER_IMAGE" >/dev/null 2>&1; then ok "CUDA_DOCKER_IMAGE=$CUDA_DOCKER_IMAGE present ($(docker image inspect "$CUDA_DOCKER_IMAGE" --format '{{.Architecture}}'))"
else wrn "CUDA_DOCKER_IMAGE=$CUDA_DOCKER_IMAGE not built; default falls back to arm64 image under qemu (slow)" "docker build --platform=linux/amd64 -t cuda-amd64:v2.3 extra/cuda_docker_amd64"; fi
grep -q "CUDA_DOCKER_IMAGE" tinygrad/runtime/support/compiler_cuda.py && ok "compiler_cuda.py honors CUDA_DOCKER_IMAGE (local patch, branch macpro-intel)" || wrn "compiler_cuda.py lacks the CUDA_DOCKER_IMAGE patch (upstream arm64 image will be used under qemu)"
if OUT=$($PY -c "
import subprocess,struct,os,sys
from tinygrad.runtime.support.compiler_cuda import osx_docker_cmd
import tinygrad, pathlib
argv=osx_docker_cmd.split()+[str(pathlib.Path(tinygrad.__file__).parent/'runtime/support/compileserver.py'),'tinygrad.runtime.support.compiler_cuda:NVRTCCompiler','sm_86','False']
p=subprocess.Popen(argv,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
src=b'extern \"C\" __global__ void k(float* a){a[threadIdx.x]=1.f;}'
out,err=p.communicate(struct.pack('I',len(src))+src,timeout=300)
n=struct.unpack('I',out[:4])[0] if len(out)>=4 else 0
print('cubin',n,'bytes'); sys.exit(0 if n>0 else 1)
print(err.decode()[-300:], file=sys.stderr)
" 2>&1); then ok "NVRTC compile server round-trip in docker: $OUT"; else bad "NVRTC compile server failed" "$(echo "$OUT" | tail -3)"; fi

hdr "GSP firmware cache (570.144, ga102 bundle -> GA106)"
FWOK=$($PY - <<'PY'
import hashlib, pathlib
from tinygrad.helpers import cache_dir
fws={"booter_load-570.144.bin":"4497e3eff7e95c774b8a569d17b27c08c9650158d10b229d2be81cdcad9a085b",
     "gsp-570.144.bin":"a8c3ebeed280323aedb51c061f321e73379cce7a9ae643a33dd03915df027f7f",
     "bootloader-570.144.bin":"82428f532240727e95bb3083fbaaba9b2cc7b937314323f2d546ce7245f27fad"}
base="https://gitlab.com/kernel-firmware/linux-firmware/-/raw/1e2c15348485939baf1b6d1f5a7a3b799d80703d/nvidia/ga102/gsp/"
d=pathlib.Path(cache_dir)/"downloads"/"fw"; ok=0
for n,s in fws.items():
  p=d/hashlib.md5((base+n).encode()).hexdigest()
  good=p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest()==s
  print(("ok  " if good else "MISS")+f" {n} -> {p.name}"); ok+=good
print("ALL" if ok==3 else "PARTIAL")
PY
)
echo "$FWOK" | grep -v -E "^(ALL|PARTIAL)$" | sed 's/^/      /'
echo "$FWOK" | grep -q "^ALL$" && ok "all 3 GSP firmware files cached in $HOME/Library/Caches/tinygrad/downloads/fw" || bad "firmware cache incomplete" "run: .venv/bin/python -c 'from tinygrad.helpers import fetch_fw' + the fetch loop in RUNBOOK.md"

hdr "summary"
printf '%d pass, %d fail, %d warn\n' $pass $fail $warn
[ $fail -eq 0 ] && echo "READY: cold-boot the machine, then ./first_test.sh" || echo "NOT READY: fix FAILs above before ./first_test.sh"
exit $fail

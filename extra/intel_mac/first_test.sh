#!/bin/bash
# first_test.sh -- the FIRST real DEV=NV run on the 2019 Mac Pro (Intel) + RTX 3060 via TinyGPU.
# This touches GPU registers and boots GSP firmware. Prior Intel-Mac attempts (tinygrad #16097, #16534) KERNEL PANICKED
# here, so: save your work, close everything else, and read RUNBOOK.md first.

# --- Colima decision (b): tmp under $HOME so the docker nvcc shim / compile server can see tinygrad's temp files.
export TMPDIR="$HOME/.tinygrad-tmp"; mkdir -p "$TMPDIR"
export PATH="$HOME/.local/bin:$PATH"
export CUDA_DOCKER_IMAGE="${CUDA_DOCKER_IMAGE:-cuda-amd64:v2.3}"

cd "$(dirname "$0")" || exit 1
[ -x .venv/bin/python ] && PY=.venv/bin/python || PY=python3
LOGDIR="$HOME/tinygpu-logs"; mkdir -p "$LOGDIR"
STAMP=$(date +%Y%m%d-%H%M%S)
KLOG="$LOGDIR/tinygpu-$STAMP.log"; TLOG="$LOGDIR/test_tiny-$STAMP.log"; LLOG="$LOGDIR/llm-$STAMP.log"

cat <<BANNER
==================================================================================================
  FIRST DEV=NV TEST -- read before continuing
  * Run this from a COLD BOOT (full shutdown, wait 10 s, power on -- not a restart, not sleep/wake).
    The driver only issues a risky *full PCI reset* of the GPU if it finds the GPU warm (WPR2 already set,
    i.e. GSP was booted earlier this power cycle). Cold GPU => no reset path => fewer ways to panic.
  * If macOS kernel panics / reboots, the report lands in /Library/Logs/DiagnosticReports/ (panic-full-*.ips;
    on T2 Macs also .../DiagnosticReports/ProxiedDevice-Bridge/). Kernel log for the dext is streamed to:
        $KLOG
  * Uptime now: $(uptime | sed 's/.*up \([^,]*\),.*/\1/')  (should be minutes, not hours/days)
==================================================================================================
BANNER
if [ "${FORCE:-0}" != "1" ]; then
  read -r -p "Continue with DEV=NV on the GPU? [y/N] " a; case "$a" in y|Y) ;; *) echo "aborted"; exit 1;; esac
fi

# quick gate: same checks as preflight but only the ones that matter right before touching the card
if ! system_profiler SPPCIDataType 2>/dev/null | grep -qi "Vendor ID: 0x10de"; then echo "FATAL: no NVIDIA PCI device visible. Run ./preflight.sh"; exit 1; fi
if ! systemextensionsctl list 2>/dev/null | grep org.tinygrad.tinygpu.driver2 | grep -q "activated enabled"; then echo "FATAL: dext not [activated enabled]. Run ./preflight.sh"; exit 1; fi
if ! ioreg -l 2>/dev/null | grep -q org.tinygrad.tinygpu.driver2; then echo "WARN: dext does not appear bound to a device in ioreg (continuing; TinyGPU server will tell)"; fi
docker info >/dev/null 2>&1 || { echo "FATAL: docker not reachable (colima start)"; exit 1; }

# background kernel/unified log capture for the dext + app
/usr/bin/log stream --style compact --predicate 'sender CONTAINS "tinygpu" OR process CONTAINS "TinyGPU" OR eventMessage CONTAINS "tinygpu"' > "$KLOG" 2>&1 &
LOGPID=$!
trap 'kill $LOGPID 2>/dev/null' EXIT
sleep 1
echo "log stream -> $KLOG (pid $LOGPID)"

# NOTE (#16097): auto-launch of the TinyGPU server via Popen was flaky on an Intel Mac; start it explicitly so its
# stdout/stderr are captured, tinygrad will connect to the same socket path (temp('tinygpu.sock') under TMPDIR).
SOCK="$TMPDIR/tinygpu.sock"
if ! pgrep -f "TinyGPU server" >/dev/null; then
  rm -f "$SOCK"
  /Applications/TinyGPU.app/Contents/MacOS/TinyGPU server "$SOCK" > "$LOGDIR/tinygpu-server-$STAMP.log" 2>&1 &
  echo "TinyGPU server pid $! -> $LOGDIR/tinygpu-server-$STAMP.log"
  for i in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
  [ -S "$SOCK" ] || { echo "FATAL: TinyGPU server did not create $SOCK"; cat "$LOGDIR/tinygpu-server-$STAMP.log"; exit 1; }
fi

echo; echo ">>> DEBUG=2 DEV=NV $PY test/test_tiny.py TestTiny.test_plus   (log: $TLOG)"; echo
set -o pipefail
DEBUG=2 DEV=NV $PY test/test_tiny.py TestTiny.test_plus 2>&1 | tee "$TLOG"
rc=$?
if [ $rc -ne 0 ]; then
  echo; echo "!!! test_plus FAILED (rc=$rc). Logs: $TLOG  $KLOG"
  echo "    Next: RUNBOOK.md 'Debugging init_hw' -- rerun with NV_DEBUG=4 ./first_test.sh (from another cold boot) for register traces."
  exit $rc
fi

echo; echo ">>> test_plus PASSED. Running the LLM:  DEV=NV $PY -m tinygrad.llm   (log: $LLOG)"; echo
DEV=NV $PY -m tinygrad.llm "$@" 2>&1 | tee "$LLOG"
echo; echo "done. logs in $LOGDIR"

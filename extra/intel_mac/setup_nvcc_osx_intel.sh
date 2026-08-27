#!/bin/sh
# Intel (x86_64) macOS variant of setup_nvcc_osx.sh.
# Differences: --platform=linux/amd64, CUDA apt repo ubuntu2204/x86_64, and the shim mounts $TMPDIR (if set) in
# addition to /var/folders and $HOME -- on Colima /var/folders is not shared with the VM, so tinygrad's temp
# files must live under $HOME (export TMPDIR="$HOME/.tinygrad-tmp", see RUNBOOK.md).
set -eu
install_loc="$HOME/.local/bin"
docker build --platform=linux/amd64 -t cuda-nvcc:12.8 - <<'DOCKERFILE'
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates && \
  wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb && \
  dpkg -i cuda-keyring_1.1-1_all.deb && \
  apt-get update && apt-get install -y --no-install-recommends cuda-nvcc-12-8 cuda-nvdisasm-12-8 cuda-cuobjdump-12-8 && rm -rf /var/lib/apt/lists/*
ENV PATH=/usr/local/cuda/bin:$PATH
DOCKERFILE

mkdir -p "$install_loc"
tee "$install_loc/nvccshim" >/dev/null <<'SHIM'
#!/bin/sh
set -eu
cname="cuda-nvcc-persistent"
# mount macOS temp dir + $HOME + $TMPDIR (if set and not already under $HOME) so absolute paths passed to nvcc resolve in the container
extra_mount=""
if [ -n "${TMPDIR:-}" ]; then
  case "${TMPDIR%/}/" in "$HOME"/*) ;; *) extra_mount="-v ${TMPDIR%/}:${TMPDIR%/}";; esac
fi
if ! docker inspect --format='{{.State.Running}}' "$cname" 2>/dev/null | grep -q true; then
  docker rm -f "$cname" 2>/dev/null || true
  # shellcheck disable=SC2086
  docker run -d --platform=linux/amd64 --name "$cname" \
    -v /var/folders:/var/folders -v "$HOME":"$HOME" $extra_mount \
    cuda-nvcc:12.8 sleep 300 >/dev/null
fi
exec docker exec "$cname" "$(basename "$0")" "$@"
SHIM
chmod +x "$install_loc/nvccshim"
for t in nvcc nvdisasm; do
  ln -sf "$install_loc/nvccshim" "$install_loc/$t"
done
echo "installed: $install_loc/nvcc $install_loc/nvdisasm (via $install_loc/nvccshim)"

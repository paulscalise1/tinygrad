#!/bin/bash
# Rebase the intel-mac branch onto the latest upstream tinygrad, then rebuild the dev TinyGPU app and dext.
# Usage: extra/intel_mac/update.sh [--no-build]
set -e
cd "$(git rev-parse --show-toplevel)"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/tinygrad/tinygrad.git
git fetch -q upstream master
cur=$(git rev-parse --abbrev-ref HEAD)
[ "$cur" = "intel-mac" ] || { echo "switch to the intel-mac branch first (git checkout intel-mac)"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean, commit or stash first"; exit 1; }
git checkout -q master && git merge -q --ff-only upstream/master && git checkout -q intel-mac
echo "rebasing intel-mac onto upstream/master ($(git rev-parse --short upstream/master))"
if ! git rebase master; then
  echo "rebase stopped on a conflict: fix the files, 'git add' them, 'git rebase --continue', then rerun with --no-build to rebuild"; exit 1
fi
git log --oneline master..intel-mac
[ "$1" = "--no-build" ] && exit 0
echo "rebuilding the TinyGPU app and dext (ad-hoc signed, needs SIP off)"
(cd extra/usbgpu/tbgpu/installer && ./install_nosip.sh --build)
echo "built: extra/usbgpu/tbgpu/installer/build/Debug/TinyGPU.app"
echo "to install: cd extra/usbgpu/tbgpu/installer && ./install_nosip.sh   (then approve the extension and reboot)"
echo "then: extra/intel_mac/preflight.sh && DEV=NV python -m tinygrad.llm"

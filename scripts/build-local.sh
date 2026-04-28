#!/usr/bin/env bash
# build-local.sh — pi-gen Docker build wrapper for ara-kiosk-image.
#
# Clones pi-gen into .pi-gen-work/ (gitignored), symlinks our config
# and stage directories into it, and runs build-docker.sh. Output
# .img.xz lands under .pi-gen-work/deploy/ and is copied to ./deploy/
# at the end for convenience.
#
# Requires: Linux (or WSL2), Docker, ~25 GB free disk. Allow ~30–45 min
# for the first build; subsequent builds are faster thanks to pi-gen's
# stage caching.
#
# Usage:
#   ./scripts/build-local.sh                # full build
#   PI_GEN_REF=master ./scripts/build-local.sh   # pin a different pi-gen branch

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${REPO_ROOT}/.pi-gen-work"
PI_GEN_REF="${PI_GEN_REF:-arm64}"

# Sanity: pi-gen needs Linux. Refuse to even try on macOS.
case "$(uname -s)" in
    Linux) ;;
    *)
        echo "build-local.sh: pi-gen requires Linux kernel features and can't" >&2
        echo "build on $(uname -s). Use a Linux box or WSL2." >&2
        exit 2
        ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    echo "build-local.sh: docker CLI not found. Install Docker first." >&2
    exit 2
fi

# Clone pi-gen on first run.
if [ ! -d "${WORK_DIR}/.git" ]; then
    echo "==> Cloning pi-gen ${PI_GEN_REF} into ${WORK_DIR}"
    git clone --depth 1 --branch "${PI_GEN_REF}" \
        https://github.com/RPi-Distro/pi-gen.git "${WORK_DIR}"
fi

cd "${WORK_DIR}"

# Symlink our top-level config and each repo-local stage in.
echo "==> Linking ara-kiosk config + stages into pi-gen working dir"
ln -sfn "${REPO_ROOT}/config" ./config

for stage in \
    01-stage-picompose \
    02-stage-audiodriver-xvf3800 \
    03-stage-linux-voice-assistant \
    04-stage-kiosk \
    05-stage-finish; do
    ln -sfn "${REPO_ROOT}/${stage}" "./${stage}"
done

# Mark upstream pi-gen's downstream image stages so they're skipped —
# we only want stage0/1/2 from pi-gen itself.
for s in stage3 stage4 stage5; do
    [ -d "${s}" ] || continue
    touch "${s}/SKIP" "${s}/SKIP_IMAGES" 2>/dev/null || true
done

echo "==> Starting pi-gen Docker build (this is the slow part)"
sudo PRESERVE_CONTAINER=1 ./build-docker.sh

echo
echo "==> pi-gen output:"
ls -lh "${WORK_DIR}/deploy/" || true

# Mirror artifacts into the repo's own deploy/ for easier discovery.
mkdir -p "${REPO_ROOT}/deploy"
shopt -s nullglob
artifacts=( "${WORK_DIR}/deploy/"*.img.xz "${WORK_DIR}/deploy/"*.img.zip )
if [ "${#artifacts[@]}" -gt 0 ]; then
    cp -v "${artifacts[@]}" "${REPO_ROOT}/deploy/"
    echo
    echo "==> Mirrored to ${REPO_ROOT}/deploy/"
else
    echo "==> No image artifacts found in ${WORK_DIR}/deploy/ — check the build log"
    exit 1
fi

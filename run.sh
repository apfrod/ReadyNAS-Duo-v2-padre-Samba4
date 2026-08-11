#!/usr/bin/env bash
# ============================================================================
# run.sh — host-side wrapper around `docker run` that does the right thing on
# macOS. Usage:  ./run.sh [build.sh args]      e.g.  ./run.sh all
#
# WHY a named volume: crosstool-NG (and safe Samba installs) require a
# CASE-SENSITIVE filesystem, but a bind-mounted macOS directory (APFS default)
# is case-INSENSITIVE. So the heavy build/scratch trees live on a Docker named
# volume (ext4 in the Linux VM = case-sensitive). The repo stays bind-mounted
# at /work for scripts + config, and the final tarball is written back to
# ./dist so it lands on the host automatically.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-readynas-samba4}"
VOL="${VOL:-readynas-samba4-state}"

# Build the image if missing.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> building image $IMAGE"
  docker build -t "$IMAGE" "$HERE"
fi

# Create the state volume once (the entrypoint chowns it to our uid at start).
if ! docker volume inspect "$VOL" >/dev/null 2>&1; then
  echo "==> creating case-sensitive state volume $VOL"
  docker volume create "$VOL" >/dev/null
fi

# Register a SPARC binfmt_misc handler in the Docker VM so Samba's build can
# transparently run the target-built code generators (asn1_compile, compile_et)
# under qemu-sparc-static. This is a one-off, VM-global, privileged step; it's
# idempotent and harmless if already present. The build container itself stays
# unprivileged. Only needed for the 'samba'/'all' phases, but cheap to ensure.
echo "==> ensuring SPARC binfmt handler (privileged, one-off) …"
docker run --privileged --entrypoint sh --rm "$IMAGE" -c '
  modprobe binfmt_misc 2>/dev/null || true
  [ -e /proc/sys/fs/binfmt_misc/register ] || \
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
  [ -e /proc/sys/fs/binfmt_misc/qemu-sparc ] && exit 0
  spec=/usr/share/binfmts/qemu-sparc
  magic=$(awk "/^magic/{print \$2}" "$spec")
  mask=$(awk "/^mask/{print \$2}" "$spec")
  printf ":qemu-sparc:M:0:%s:%s:/usr/bin/qemu-sparc-static:OC" "$magic" "$mask" \
    > /proc/sys/fs/binfmt_misc/register
' || echo "   (warning: SPARC binfmt registration failed — the Samba phase may" \
        "fail at asn1_compile with 'Exec format error')"

# Interactive only when attached to a TTY (so CI / background runs still work).
TTY=""; [ -t 0 ] && [ -t 1 ] && TTY="-it"

# NOTE: no --user here on purpose. The container starts as root and the
# entrypoint drops to HOST_UID:HOST_GID (with a real passwd entry) before
# building — so files stay host-owned and `id -un` works inside the build.
exec docker run --rm $TTY \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -v "$HERE":/work \
  -v "$VOL":/state \
  -e DL=/state/dl \
  -e SRC=/state/src \
  -e BUILD=/state/build \
  -e XTOOLS=/state/x-tools \
  -e STAGE=/state/stage \
  -e STAMP=/state/.stamp \
  ${SAMBA_VERSION:+-e SAMBA_VERSION="$SAMBA_VERSION"} \
  "$IMAGE" ./build.sh "${@:-all}"

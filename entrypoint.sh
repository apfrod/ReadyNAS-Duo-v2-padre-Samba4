#!/bin/sh
# ============================================================================
# Container entrypoint. Runs as ROOT, then drops to the caller's host UID/GID.
#
# WHY: crosstool-NG (and other tools) call `id -un` / need $HOME. If we run the
# container with `--user <hostuid>` and that UID has no /etc/passwd entry,
# `id -un` fails and the build aborts. So instead we start as root, synthesize
# a passwd entry for HOST_UID:HOST_GID, fix volume ownership, and exec the build
# as that user — files on both /work (bind mount) and /state (volume) end up
# owned by the host user, and username lookups work.
# ============================================================================
set -e

: "${HOST_UID:=1000}"
: "${HOST_GID:=1000}"

# Create group + user for the host identity (idempotent).
groupadd -g "$HOST_GID" hostgrp 2>/dev/null || true
if ! getent passwd "$HOST_UID" >/dev/null 2>&1; then
  useradd -u "$HOST_UID" -g "$HOST_GID" -M -d /home/builder -s /bin/sh builder 2>/dev/null \
    || echo "builder:x:$HOST_UID:$HOST_GID::/home/builder:/bin/sh" >> /etc/passwd
fi

mkdir -p /home/builder
chown "$HOST_UID:$HOST_GID" /home/builder

# The state volume mounts root-owned on first use; hand it to the build user.
[ -d /state ] && chown "$HOST_UID:$HOST_GID" /state 2>/dev/null || true

export HOME=/home/builder

# Drop privileges and run the requested command as the host user.
exec setpriv --reuid "$HOST_UID" --regid "$HOST_GID" --clear-groups "$@"

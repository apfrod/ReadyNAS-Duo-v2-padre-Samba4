#!/usr/bin/env bash
# ============================================================================
# install-on-device.sh — copy the package to the ReadyNAS and install it,
# SAFELY and REVERSIBLY.
#
# Run this on your WORKSTATION (needs ssh/scp to the NAS). It:
#   1. scp's the tarball to the NAS
#   2. BACKS UP anything it is about to change (see below), writing a manifest
#   3. stops the stock SMB1 Samba (frees ports 139/445)
#   4. extracts our tree onto the DATA VOLUME and symlinks /opt/samba
#   5. installs + starts our init script
#   6. drops a self-contained restore.sh next to the backup
#
# What it can change (and therefore backs up / records, first install only):
#   * running state of the stock Samba      -> restore restarts it
#   * a pre-existing /opt/samba (dir/link)   -> moved to the backup dir
#   * a pre-existing /etc/init.d/S91samba    -> copied to the backup dir
#   * files it creates (our tree, symlink, init script) -> recorded for removal
#
# Backup + restore live at:  <NAS_DATA_DIR>/samba4-backup/
# To revert everything to stock:  ./install/uninstall-on-device.sh
#   (or, on the NAS directly:  sh <NAS_DATA_DIR>/samba4-backup/restore.sh)
#
# Usage:
#   NAS_HOST=192.168.1.50 NAS_USER=root NAS_DATA_DIR=/c/opt \
#     ./install/install-on-device.sh dist/samba4-4.13.17-sparc-opt.tar.gz
#
# NOTE: needs root SSH on the ReadyNAS (RAIDiator's "Enable SSH" / root-ssh
# add-on). This tool never enters passwords for you — you authenticate ssh.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../config.env"

TARBALL="${1:-}"
[ -n "$TARBALL" ] && [ -f "$TARBALL" ] || {
  echo "usage: $0 <path-to-samba4-*-sparc-opt.tar.gz>" >&2; exit 1; }

REMOTE_TMP="/tmp/$(basename "$TARBALL")"
REMOTE_TREE="${NAS_DATA_DIR}/samba"          # real files on the data volume
BACKUP_DIR="${NAS_DATA_DIR}/samba4-backup"   # backup + manifest + restore.sh

echo "==> Target: ${NAS_USER}@${NAS_HOST}   data dir: ${NAS_DATA_DIR}"
echo "==> Uploading $(basename "$TARBALL") …"
scp "$TARBALL" "${NAS_USER}@${NAS_HOST}:${REMOTE_TMP}"

echo "==> Installing on device (with backup) …"
# Everything below runs ON the NAS. Values are passed via the env prefix so the
# quoted heredoc body stays literal.
ssh "${NAS_USER}@${NAS_HOST}" \
  "PREFIX='$PREFIX' DATA='$NAS_DATA_DIR' TARBALL='$REMOTE_TMP' \
   TREE='$REMOTE_TREE' BACKUP_DIR='$BACKUP_DIR' sh -s" <<'REMOTE'
set -e
MANIFEST="$BACKUP_DIR/manifest.env"

# ---- 1. Back up (FIRST install only; a manifest means we already did) -------
if [ ! -f "$MANIFEST" ]; then
  echo "  - first install: recording backup in $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"

  # Was the stock Samba running? (ours isn't up yet, so any smbd/nmbd is stock.)
  if ps 2>/dev/null | grep -E '[s]mbd|[n]mbd' >/dev/null 2>&1; then
    STOCK_RUNNING=1; else STOCK_RUNNING=0; fi

  # Preserve a pre-existing /opt/samba rather than destroying it.
  PREFIX_BACKUP=none
  if [ -L "$PREFIX" ]; then
    # existing symlink: record its target, then drop the link
    PREFIX_BACKUP="symlink:$(readlink "$PREFIX" 2>/dev/null || echo '?')"
    rm -f "$PREFIX"
  elif [ -e "$PREFIX" ]; then
    mv "$PREFIX" "$BACKUP_DIR/opt-samba.orig"
    PREFIX_BACKUP=moved
  fi

  # Preserve a pre-existing init script (unlikely, but be safe).
  INIT_BACKUP=none
  if [ -e /etc/init.d/S91samba ]; then
    cp -p /etc/init.d/S91samba "$BACKUP_DIR/S91samba.orig"
    INIT_BACKUP=saved
  fi

  # Manifest: everything restore needs to know.
  {
    echo "# ReadyNAS Samba4 install manifest — used by restore.sh"
    echo "PREFIX='$PREFIX'"
    echo "TREE='$TREE'"
    echo "DATA='$DATA'"
    echo "BACKUP_DIR='$BACKUP_DIR'"
    echo "STOCK_RUNNING=$STOCK_RUNNING"
    echo "PREFIX_BACKUP='$PREFIX_BACKUP'"
    echo "INIT_BACKUP='$INIT_BACKUP'"
  } > "$MANIFEST"
else
  echo "  - manifest exists ($MANIFEST): reinstall over our own files, keeping original backup"
fi

# ---- 1b. (Re)write the self-contained on-device restore script --------------
cat > "$BACKUP_DIR/restore.sh" <<'RESTORE'
#!/bin/sh
# Revert the ReadyNAS to its stock Samba setup. Safe to re-run.
set -e
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/manifest.env"
echo "Restoring stock Samba setup from $D …"

# 1. Stop and kill our Samba (matched strictly by our $PREFIX path).
[ -x /etc/init.d/S91samba ] && /etc/init.d/S91samba stop 2>/dev/null || true
for p in smbd nmbd; do
  for pid in $(ps 2>/dev/null | grep "$PREFIX/sbin/$p" | grep -v grep | awk '{print $1}'); do
    kill "$pid" 2>/dev/null || true
  done
done

# 2. Restore or remove our init script.
if [ "${INIT_BACKUP:-none}" = saved ] && [ -f "$D/S91samba.orig" ]; then
  cp -p "$D/S91samba.orig" /etc/init.d/S91samba
else
  rm -f /etc/init.d/S91samba
fi

# 3. Remove our symlink and restore a pre-existing /opt/samba if we moved one.
[ -L "$PREFIX" ] && rm -f "$PREFIX"
if [ "${PREFIX_BACKUP:-none}" = moved ] && [ -e "$D/opt-samba.orig" ]; then
  mkdir -p "$(dirname "$PREFIX")"
  mv "$D/opt-samba.orig" "$PREFIX"
fi

# 4. Remove our installed tree (guarded: must be a non-empty path).
if [ -n "${TREE:-}" ] && [ -d "$TREE" ]; then rm -rf "$TREE"; fi

# 5. Restart the stock Samba if it had been running.
if [ "${STOCK_RUNNING:-0}" = 1 ] && [ -x /etc/init.d/samba ]; then
  /etc/init.d/samba start 2>/dev/null || true
fi

echo "Done. Stock Samba restored."
echo "You may now delete the backup dir:  rm -rf $D"
RESTORE
chmod +x "$BACKUP_DIR/restore.sh"

# ---- 2. Stop the stock Samba (frees ports 139/445) --------------------------
echo "  - stopping stock Samba (SMB1)"
[ -x /etc/init.d/samba ] && /etc/init.d/samba stop 2>/dev/null || true
for p in smbd nmbd; do
  for pid in $(ps 2>/dev/null | grep "/usr/.*/$p" | grep -v grep | awk '{print $1}'); do
    kill "$pid" 2>/dev/null || true
  done
done

# ---- 3. Extract our tree onto the data volume -------------------------------
echo "  - extracting to data volume: $DATA"
mkdir -p "$DATA"
tmpx="$DATA/.samba-unpack.$$"
mkdir -p "$tmpx"
tar xzf "$TARBALL" -C "$tmpx"
[ -d "$TREE" ] && rm -rf "$TREE" || true    # only ever our own previous tree
mv "$tmpx/opt/samba" "$TREE"
rm -rf "$tmpx" "$TARBALL"

# ---- 4. Point /opt/samba at our tree ----------------------------------------
echo "  - linking $PREFIX -> $TREE"
mkdir -p "$(dirname "$PREFIX")"
[ -L "$PREFIX" ] && rm -f "$PREFIX" || true
ln -s "$TREE" "$PREFIX"

# ---- 5. Install + start our init script -------------------------------------
echo "  - installing init script"
cp "$PREFIX/etc/init.d/S91samba" /etc/init.d/S91samba 2>/dev/null || true
chmod +x /etc/init.d/S91samba 2>/dev/null || true

echo "  - starting Samba4"
"$PREFIX/etc/init.d/S91samba" start || true
sleep 2
echo "  - listening sockets:"
netstat -ltn 2>/dev/null | grep -E ':(139|445)\b' || echo "    (445/139 not yet visible — check log.%m)"
echo "  - version:"
"$PREFIX/bin/smbd" --version 2>&1 | head -1 || echo "    (smbd --version failed; see troubleshooting)"
echo "  - backup + restore script at: $BACKUP_DIR"
REMOTE

echo "==> Done."
echo "   Test:    smbclient -L //${NAS_HOST} -m SMB3 -U <user>"
echo "            (create users first: ${PREFIX}/sbin/smbpasswd -a <user>)"
echo "   Revert:  ./install/uninstall-on-device.sh    (restores stock Samba)"

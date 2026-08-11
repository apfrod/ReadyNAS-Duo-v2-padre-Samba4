#!/usr/bin/env bash
# ============================================================================
# uninstall-on-device.sh — revert the ReadyNAS to its stock Samba setup.
#
# Runs the restore.sh that install-on-device.sh dropped on the NAS, which:
#   * stops & removes our Samba (smbd/nmbd, /etc/init.d/S91samba)
#   * removes our /opt/samba symlink and restores any pre-existing /opt/samba
#   * removes our installed tree on the data volume
#   * restarts the stock Samba if it had been running at install time
#
# Idempotent and safe to re-run. Uses the manifest recorded at install time.
#
# Usage:
#   NAS_HOST=192.168.1.50 NAS_USER=root NAS_DATA_DIR=/c/opt \
#     ./install/uninstall-on-device.sh
#
# Add --purge to also delete the backup dir afterwards (removes the ability to
# restore a pre-existing /opt/samba, so only use it once you're satisfied).
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../config.env"

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

BACKUP_DIR="${NAS_DATA_DIR}/samba4-backup"

echo "==> Target: ${NAS_USER}@${NAS_HOST}   backup dir: ${BACKUP_DIR}"

ssh "${NAS_USER}@${NAS_HOST}" "BACKUP_DIR='$BACKUP_DIR' PURGE='$PURGE' sh -s" <<'REMOTE'
set -e
if [ ! -f "$BACKUP_DIR/restore.sh" ]; then
  echo "  !! No restore.sh at $BACKUP_DIR — was this NAS ever installed to?" >&2
  echo "     Nothing to revert. If you installed manually, remove /opt/samba," >&2
  echo "     /etc/init.d/S91samba and your data-volume tree by hand." >&2
  exit 1
fi
sh "$BACKUP_DIR/restore.sh"
if [ "$PURGE" = 1 ]; then
  echo "  - purging backup dir $BACKUP_DIR"
  rm -rf "$BACKUP_DIR"
fi
REMOTE

echo "==> Reverted to stock Samba."
[ "$PURGE" = 1 ] && echo "   (backup dir purged)" || \
  echo "   Backup kept at ${BACKUP_DIR}; re-run with --purge to delete it."

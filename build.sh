#!/usr/bin/env bash
# ============================================================================
# build.sh — top-level orchestrator. Resumable via stamp files under $STAMP.
#
#   ./build.sh all          # env-check + toolchain + deps + samba + package
#   ./build.sh toolchain    # just one phase (also: deps | samba | package)
#   ./build.sh clean-samba  # unstamp + rebuild only Samba (keeps toolchain/deps)
#   ./build.sh status       # show which phases are done
#
# Intended to run INSIDE the Docker image (see Dockerfile), but works on any
# Debian-ish x86-64 host that has the same packages installed.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.env
. "$HERE/config.env"
# shellcheck source=common.sh
. "$HERE/common.sh"

phase_env() {
  log "Phase 0: environment check"
  local miss=0
  for t in gcc g++ make bison flex curl python3 perl qemu-sparc-static; do
    if command -v "$t" >/dev/null 2>&1; then :; else warn "missing tool: $t"; miss=1; fi
  done
  [ "$miss" -eq 0 ] || die "install missing tools (or use the Docker image)."
  # qemu-sparc-static must be 32-bit BIG-ENDIAN sparc, not sparc64.
  log "qemu user emulator: $(command -v qemu-sparc-static)"
  mkdir -p "$DL" "$SRC" "$BUILD" "$XTOOLS" "$STAGE" "$DIST" "$STAMP"
  log "target=$TARGET cpu=$TARGET_CPU samba=$SAMBA_VERSION glibc=$GLIBC_VERSION kver=$KERNEL_HEADERS"
}

phase_toolchain() {
  if stamped 01-toolchain; then log "toolchain: already built (skip)"; return; fi
  "$HERE/toolchain/01-build-toolchain.sh"
  stamp 01-toolchain
}

phase_deps() {
  if stamped 02-deps; then log "deps: already built (skip)"; return; fi
  require_toolchain
  "$HERE/deps/02-build-deps.sh"
  stamp 02-deps
}

phase_samba() {
  if stamped 03-samba; then log "samba: already built (skip)"; return; fi
  require_toolchain
  "$HERE/samba/03-build-samba.sh"
  stamp 03-samba
}

phase_package() {
  # packaging is cheap; always re-run so config/wrapper tweaks take effect
  require_toolchain
  "$HERE/package/04-make-package.sh"
  stamp 04-package
}

status() {
  for p in 01-toolchain 02-deps 03-samba 04-package; do
    if stamped "$p"; then printf '  [x] %s\n' "$p"; else printf '  [ ] %s\n' "$p"; fi
  done
}

case "${1:-all}" in
  all)        phase_env; phase_toolchain; phase_deps; phase_samba; phase_package
              log "DONE. Artifact(s) in $DIST" ;;
  env)        phase_env ;;
  toolchain)  phase_env; phase_toolchain ;;
  deps)       phase_env; phase_deps ;;
  samba)      phase_env; phase_samba ;;
  package)    phase_env; phase_package ;;
  clean-samba) unstamp 03-samba; rm -rf "$BUILD/samba-$SAMBA_VERSION"; log "samba build reset" ;;
  clean-all)  rm -rf "$STAMP" "$BUILD" "$STAGE" "$DIST"; log "reset (kept downloads + toolchain)" ;;
  status)     status ;;
  *) die "usage: $0 {all|env|toolchain|deps|samba|package|clean-samba|clean-all|status}" ;;
esac

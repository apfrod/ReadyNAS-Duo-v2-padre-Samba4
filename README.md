# Samba 4 (SMB2/SMB3) for the Infrant SPARC ReadyNAS

Cross-compile a modern-enough **Samba 4** file server for a ReadyNAS running
`Linux 2.6.17.14ReadyNAS`, so it can serve **SMB2/SMB3** to current Windows and
macOS clients. The stock RAIDiator firmware ships **Samba 3.0.x, which only
speaks SMB1** — and SMB1 is disabled by default in modern clients.

## ⚠️ Read this first — honest expectations

- **"SMBv4" is not a protocol.** SMB versions are SMB1 / SMB2 / SMB3. This
  builds the **Samba 4 software**, whose payoff here is SMB2/SMB3 support.
- **Your device is 32-bit BIG-ENDIAN SPARC** (Infrant IT3107 "Padre", ~280 MHz,
  little RAM), on **glibc 2.3.2 (2003)**. That combination is why this is hard.
- **This is a multi-hour to multi-day build** (the cross-toolchain alone takes a
  while) and success on the *newest* Samba is **not guaranteed** — 2.6.17-era
  syscall gaps and SPARC-specific issues can surface. The scripts automate the
  known-good path and make reruns cheap; if a release won't build/run, drop
  `SAMBA_VERSION` (4.13 → 4.9; 4.0 is the floor for SMB3).
- **Performance is modest by design.** Prefer plain SMB2; SMB3 *encryption* will
  be slow on this CPU. Keep `smb.conf` lean.
- We **never touch the device's system glibc or stock Samba binaries.**
  Everything lands in a self-contained `/opt/samba` with its own bundled loader
  and libraries. Removing it = delete `/opt/samba` and restart the firmware.

## Validation status

**Confirmed working on real ReadyNAS Duo v1 (Infrant IT3107) hardware:**
`/opt/samba/sbin/smbd --version` → `Version 4.13.17` (no segfault).

The build is **fully static, non-PIC**. This matters — see "Why static" below.

- **Toolchain**: `sparc-unknown-linux-gnu-gcc` 7.5.0, glibc 2.19, binutils 2.38.
- **Deps**: zlib, popt, gmp, nettle, libtasn1, libunistring, **GnuTLS 3.6.16**
  cross-built **static + non-PIC** into the sysroot.
- **Samba 4.13.17**: cross-compiled via waf (qemu cross-execute for configure;
  SPARC binfmt for the in-build code generators), linked **fully static**
  (`smbd`/`nmbd`/`smbpasswd`, `ET_EXEC`, no interpreter).
- **Package**: `dist/samba4-4.13.17-sparc-opt.tar.gz` (~17 MB) — three static
  binaries + `smb.conf` + init script. No bundled libs, no loader, no wrapper.

### Why static (the core finding)

The device runs a **patched (NETGEAR) glibc 2.3.2** whose dynamic loader works,
but that glibc is far too old to host Samba 4.13. A **bundled modern glibc
(2.19) dynamic loader *crashes*** on the Infrant CPU (confirmed: a trivial
dynamic "hello" segfaults; a static one runs). So we link **everything static**
and avoid `ld.so` entirely. Getting Samba's build to do that required:

1. **`--without-pie --without-relro`** — the 2.6.17 kernel also mishandles PIE.
2. **Patch waf's `SHLIB_MARKER` → `-Wl,-Bstatic`** (`samba/03-build-samba.sh`) —
   waf otherwise wraps external libs in `-Wl,-Bdynamic`, defeating `-static`.
3. **Fold GnuTLS's static chain into `gnutls.pc` `Libs:`** (`deps/…`) so the
   static link resolves libtasn1/nettle/hogweed/gmp/unistring in order.
4. **Non-PIC everything** (`-fno-pic`, and nettle `make CCPIC=`) — 32-bit SPARC
   PIC uses a 13-bit GOT offset (`R_SPARC_GOT13`) that overflows in a binary
   this large; non-PIC uses absolute addressing (no GOT). nettle force-appends
   `-fpic`, so its build gets `CCPIC=` to override it.
5. **`--nonshared-binary=smbd/smbd,nmbd,smbpasswd`** + a manual static install —
   only these three link static; the shared tool binaries can't.

## Key design decisions

| Constraint | Decision |
|---|---|
| SPARC v8 variant lacks some v8 ops | Compile **everything** with `-mcpu=v7` (`TARGET_CFLAGS`) |
| Device glibc 2.3.2 too old for modern Samba | Bundle our own glibc **2.19** + loader under `/opt/samba/lib`; launch via wrapper |
| waf configure runs target binaries | Emulate with `qemu-sparc-static` (`--cross-execute`), cache in `cross-answers.txt` |
| Tiny root partition | Install onto the **data volume**, symlink `/opt/samba` to it |
| SMB3 crypto needs GnuTLS | Cross-build the full GnuTLS chain (nettle/gmp/tasn1/…) into the sysroot |

## Prerequisites

- **Docker** (only hard requirement on the host — macOS included).
- **Docker disk allowance ≥ 20 GB.** The build (toolchain + sources + build
  trees + Samba) needs real space on Docker's *own* virtual disk. On Docker
  Desktop this is **Settings → Resources → Virtual disk limit** — a small
  default (e.g. 8 GB) fills up mid-build and the link step dies with
  `No space left on device`. Also keep ~20 GB free on the host.
- Root **SSH** access to the ReadyNAS (RAIDiator "Enable SSH" / root-ssh add-on)
  for the install step.

## Quick start

Use the `run.sh` wrapper — it builds the image, provisions a **case-sensitive
state volume** (required by crosstool-NG; a bind-mounted macOS dir is
case-insensitive and will fail), and runs the pipeline:

```bash
./run.sh all
```

Produces `dist/samba4-<version>-sparc-opt.tar.gz` (written back to the repo).

Phases are **resumable** (stamp files on the state volume):

```bash
./run.sh status       # what's done
./run.sh toolchain    # phase 1 only
./run.sh deps         # phase 2 only
./run.sh samba        # phase 3 only
./run.sh package      # phase 4 only (always re-runnable; picks up conf tweaks)
./run.sh clean-samba  # rebuild just Samba, keep toolchain + deps
```

`run.sh` mounts the repo at `/work` and puts all heavy build trees
(`toolchain`, sources, staging) on a Docker named volume mounted at `/state`,
so nothing depends on the host filesystem's case behavior. To wipe everything
and start clean: `docker volume rm readynas-samba4-state`.

**Build scratch is auto-reclaimed** after each phase *succeeds* — the
crosstool-NG `.build` tree, each dependency's build dir, and the Samba build
tree are deleted once their durable output (toolchain / sysroot libs / staged
install) is in place. This keeps peak disk far lower than the total of all
intermediate trees. The cleanup is guarded (it only ever touches paths inside
the scratch roots) and can be turned off for debugging:

```bash
KEEP_SCRATCH=1 ./run.sh all   # leave all intermediate build trees in place
```

### Try a different Samba version

```bash
SAMBA_VERSION=4.9.18 ./run.sh clean-samba
SAMBA_VERSION=4.9.18 ./run.sh samba package
```

## Install on the NAS

Run on your workstation (needs ssh/scp to the NAS):

```bash
NAS_HOST=192.168.1.50 NAS_USER=root NAS_DATA_DIR=/c/opt \
  ./install/install-on-device.sh dist/samba4-4.13.17-sparc-opt.tar.gz
```

This uploads the tarball, extracts it to the data volume, symlinks `/opt/samba`,
**stops the stock SMB1 Samba** (to free ports 139/445), installs the init
script, and starts our daemons.

Then, on the NAS, create a user and point a share at real data:

```bash
/opt/samba/sbin/smbpasswd -a youruser      # add an SMB user
# edit /opt/samba/etc/smb.conf: set [data] path = /c/<your-share-dir>
/opt/samba/etc/init.d/S91samba restart
```

> The init script lives on the data volume; a **reboot or firmware update
> reverts to stock Samba** unless you re-run it (or hook it into a persistent
> RAIDiator boot mechanism).

### Backup & revert to stock

Install is **safe and reversible**. On first install it records a manifest and
backs up anything it changes into `<NAS_DATA_DIR>/samba4-backup/`:

- whether the stock Samba was running (so revert restarts it),
- any pre-existing `/opt/samba` (moved aside, never destroyed),
- any pre-existing `/etc/init.d/S91samba`,

and it drops a self-contained `restore.sh` there. To roll everything back:

```bash
NAS_HOST=192.168.1.50 ./install/uninstall-on-device.sh          # revert to stock
NAS_HOST=192.168.1.50 ./install/uninstall-on-device.sh --purge  # revert + delete backup
```

`uninstall` stops/removes our Samba, restores the original `/opt/samba`, removes
our data-volume tree, and restarts the stock Samba if it had been running. It's
idempotent. You can also run it directly on the NAS:
`sh <NAS_DATA_DIR>/samba4-backup/restore.sh`.

## Verify

**Host-side (fast, no hardware)** — `build.sh package` already runs this, but manually:

```bash
file  stage/opt/samba/sbin/smbd.real      # => ELF 32-bit MSB executable, SPARC
qemu-sparc-static -L x-tools/.../sysroot \
  stage/opt/samba/lib/ld-linux.so.2 --library-path stage/opt/samba/lib \
  stage/opt/samba/sbin/smbd.real --version
```

**On the device:**

```bash
/opt/samba/sbin/smbd -i -s /opt/samba/etc/smb.conf   # foreground; watch for errors
/opt/samba/bin/smbstatus
netstat -ltn | grep 445
```

**From a client:**

```bash
smbclient -L //<nas> -m SMB3 -U youruser             # list shares over SMB3
# macOS:   open smb://<nas>/data
# Windows: Get-SmbConnection   (shows negotiated dialect)
```

## Layout

```
config.env                 all tunables (versions, paths, device settings)
common.sh                  shared logging / fetch / cross-env helpers
Dockerfile                 Debian x86-64 build env + qemu-sparc-static
build.sh                   resumable orchestrator (env→toolchain→deps→samba→package)
toolchain/
  crosstool-ng.defconfig   ct-ng config: sparc v7, glibc 2.19, kernel 2.6.17.14
  01-build-toolchain.sh
deps/02-build-deps.sh      zlib, popt, gcrypt, gnutls chain → sysroot
samba/
  03-build-samba.sh        waf cross build via qemu cross-execute
  cross-answers.txt        cached/seeded waf answers
package/
  04-make-package.sh       self-contained /opt/samba tree → dist/*.tar.gz
  files/{launcher.template,smb.conf.template,S91samba}
install/
  install-on-device.sh     backup + install onto the NAS (safe, reversible)
  uninstall-on-device.sh   revert everything to the stock Samba setup
```

## Troubleshooting

- **`ct-ng defconfig` warns about unknown symbols** — crosstool-NG renamed a
  config symbol in your version. Run `ct-ng menuconfig` in `build/ctng-work`
  and set: arch sparc / 32-bit / big-endian / CPU `v7`, glibc 2.19 with
  `--enable-kernel=2.6.17`, custom kernel 2.6.17.14, gcc 7.5.0, binutils 2.32.
- **`smbd` is not SPARC / not MSB** (build script warns) — the host `cc` leaked
  in. Ensure you ran inside the container and `CC=$TARGET-gcc` is exported.
- **`Your file system … is *not* case-sensitive!`** — you ran the build with
  its scratch dirs on a bind-mounted macOS path. Use `./run.sh` (it puts the
  build on a case-sensitive Docker volume). This is why the wrapper exists.
- **UID mismatch on `/work`** — `run.sh` already passes `--user "$(id -u):$(id -g)"`
  and chowns the state volume; if you invoke `docker run` by hand, do the same.
- **Missing-symbol / GLIBC errors when starting `smbd` on the NAS** — the
  bundled loader isn't being used. Confirm `/opt/samba/sbin/smbd` is the wrapper
  (a shell script) and `/opt/samba/lib/ld-linux.so.2` exists.
- **`smbd` segfaults immediately on the device** (even `smbd --version`) — the
  binaries are PIE (`ET_DYN`) and the old kernel can't load them. The build
  already passes `--without-pie --without-relro`; verify with
  `readelf -h /opt/samba/sbin/smbd.real` (must say `EXEC`, not
  `DYN`/`Position-Independent`). Note it runs fine under qemu regardless, so
  this only shows up on real hardware.
- **`No space left on device` during the toolchain build** — Docker's virtual
  disk is too small. Raise it (Docker Desktop → Settings → Resources → Virtual
  disk limit → ≥ 20 GB), then `docker volume rm readynas-samba4-state` and rerun.
- **Toolchain built the wrong glibc/gcc (e.g. glibc 2.35)** — the defconfig
  version *choice* symbols didn't apply. They must be `CT_GLIBC_V_2_19=y` /
  `CT_GCC_V_7=y` style (not `CT_..._VERSION="..."` strings). glibc must stay
  ≤ 2.19 or it won't run on the 2.6.17 kernel.
- **Newer Samba won't configure/build** — lower `SAMBA_VERSION` and
  `./build.sh clean-samba && ./build.sh samba package`.
- **Ports 139/445 already in use** — stock Samba is still running; re-run the
  installer or `/etc/init.d/samba stop` on the NAS.
```

# Samba 4 (SMB2/SMB3) for the Infrant SPARC ReadyNAS

Cross-compile a modern **Samba 4** file server for a ReadyNAS running
`Linux 2.6.17.14ReadyNAS`, so it can serve **SMB2/SMB3** to current Windows and
macOS clients. The stock RAIDiator firmware ships **Samba 3.0.x, which only
speaks SMB1** — and SMB1 is disabled by default in modern clients.

## ✅ Status: working on real hardware

Confirmed on a **ReadyNAS Duo v1 (Infrant IT3107)**: `smbd` starts, resolves
users, and **serves SMB2/SMB3 directory listings and file read/write** to a
macOS `smbclient` / Finder. `Version 4.13.17`.

Getting there meant solving a stack of ancient-kernel + static-libc problems.
The short version: **the device kernel (2.6.17) and its glibc (2.3.2) are so old
that a modern dynamically-linked Samba can't run at all**, so everything is
linked **fully static, non-PIC**, and several things glibc normally does with
`dlopen` at runtime (NSS, the `*at` syscalls, iconv charset modules) had to be
worked around. See [How it actually runs](#how-it-actually-runs-the-real-fixes).

## ⚠️ Honest expectations

- **"SMBv4" is not a protocol.** SMB versions are SMB1 / SMB2 / SMB3. This builds
  the **Samba 4 software**, whose payoff here is SMB2/SMB3 support.
- **Your device is 32-bit BIG-ENDIAN SPARC** (Infrant IT3107 "Padre", ~280 MHz,
  little RAM), kernel **2.6.17**, on **glibc 2.3.2 (2003)**. That combination is
  why this is hard.
- **This is a multi-hour build** (the cross-toolchain alone takes a while). If a
  newer Samba won't build/run, drop `SAMBA_VERSION` (4.13 → 4.9; 4.0 is the SMB3
  floor).
- **Performance is modest by design.** Prefer plain SMB2; SMB3 *encryption* is
  slow on this CPU. Keep `smb.conf` lean.
- We **never touch the device's system glibc or stock Samba binaries.**
  Everything lands under `/opt/samba` (on the data volume). Reverting = run the
  uninstaller, or delete the tree.

## Why static, non-PIC (the core finding)

The device's patched (NETGEAR) glibc 2.3.2 is far too old to host Samba 4.13, and
a **bundled modern glibc (2.19) dynamic loader *crashes*** on the Infrant CPU
(confirmed: a trivial dynamic "hello" segfaults; a static one runs). So we link
**everything static** and avoid `ld.so` entirely. Making Samba's build do that:

1. **Non-PIC everything** (`-fno-pic -fno-PIE`, and nettle `make CCPIC=`) —
   32-bit SPARC PIC uses a 13-bit GOT offset (`R_SPARC_GOT13`) that overflows in
   a binary this large; non-PIC uses absolute addressing (no GOT). nettle
   force-appends `-fpic`, so its build gets `CCPIC=` to override it.
2. **Patch waf's `SHLIB_MARKER` → `-Wl,-Bstatic`** (`samba/03-build-samba.sh`) —
   waf otherwise wraps external libs in `-Wl,-Bdynamic`, defeating `-static`.
3. **Fold GnuTLS's static chain into `gnutls.pc` `Libs:`** (`deps/…`) so the
   static link resolves libtasn1/nettle/hogweed/gmp/unistring in order.
4. **`--nonshared-binary=smbd/smbd,nmbd,smbpasswd`** + a manual static install —
   only these three link static.
5. **`--without-pie --without-relro`** — belt-and-suspenders; the old kernel also
   mishandles PIE (`ET_DYN`).

Result: `smbd`/`nmbd`/`smbpasswd` are `ELF 32-bit MSB EXEC, statically linked,
no interpreter`. The package ships **no `.so`, no loader, no wrapper.**

## How it actually runs (the real fixes)

A static binary on a 2.6.17 kernel breaks several things glibc/Samba assume.
Each of these is a real crash-or-hang that was diagnosed on the device and fixed
in the build. They're the reason it works — don't remove them.

| Symptom on device | Root cause | Fix (where) |
|---|---|---|
| `smbd` panics: *failed to setup SIGTERM handler* (`eventfd` ENOSYS) | waf configure ran under qemu, which reports the **host** kernel, so it enabled syscalls 2.6.17 lacks (`eventfd`, `signalfd`, `pipe2`, `accept4`, `timerfd`, splice…) | Undefine the too-new `HAVE_*` in every generated `config.h` (`samba/03-build-samba.sh`) |
| *Unable to locate guest account [nobody]* — every `getpwnam` fails | static glibc can't `dlopen` `libnss_*`; device `nsswitch.conf` uses `compat` | Build glibc `--enable-static-nss` **and** a constructor `__nss_configure_lookup("passwd","files")` (`samba/nssfix.c`) linked into each binary |
| *Loading shared DCE/RPC modules failed [Function not implemented]* → *cannot setup ep pipe* | `load_modules()` `opendir()`s an absent module dir; the kernel returns **ENOSYS** (not ENOENT), which Samba treats as fatal | Patch `lib/util/modules.c` to treat an `opendir` failure as "no modules" (source patch in `samba/03-build-samba.sh`) |
| Client gets `NT_STATUS_NOT_SUPPORTED` listing any dir | The Infrant kernel **doesn't implement the `openat` syscall family**; Samba 4.x's VFS is built on it (`openat`/`fstatat`/`unlinkat`/…) | `samba/atshim.c` — strong overrides that fall back to the classic calls via `/proc/self/fd/<dirfd>` |
| Connection drops mid-listing, `SIGILL`, no panic | glibc `iconv` `dlopen`s a gconv charset module (`/usr/lib/gconv/UTF-16.so`); in a static binary it loads the device's ABI-incompatible stock module and jumps into garbage. Triggered reading a file's stored DOS-attributes | Pin charsets to Samba **built-in** converters — `dos charset = ISO-8859-1`, `unix charset = UTF-8` (never CP850/CP437) — so smbd never calls glibc `iconv` (`smb.conf` template) |

There is also a **cross-compile syscall hazard** worth remembering: qemu-user
runs configure probes against the *host* kernel and doesn't enforce SPARC memory
alignment, so a whole class of "works under emulation, fails on hardware" bugs
only appear on the device. The `samba/*.c` probes below exist to test on real
hardware cheaply.

## Key design decisions

| Constraint | Decision |
|---|---|
| SPARC v8 variant lacks some v8 ops | Compile **everything** with `-mcpu=v7` (`TARGET_CFLAGS`) |
| Device glibc 2.3.2 too old; 2.19 loader crashes | **Fully static, non-PIC**; no bundled loader, no wrapper |
| waf configure runs target binaries | Emulate with `qemu-sparc-static` (`--cross-execute`), cache in `cross-answers.txt`; SPARC `binfmt_misc` for in-build code generators |
| Tiny root partition | Install onto the **data volume**, symlink `/opt/samba` to it |
| SMB3 crypto needs GnuTLS | Cross-build the full GnuTLS chain (nettle/gmp/tasn1/…) static into the sysroot |

## Prerequisites

- **Docker** (only hard requirement on the host — macOS included).
- **Docker disk allowance ≥ 20 GB** (Docker Desktop → Settings → Resources →
  Virtual disk limit). A small default fills up mid-build and the link step dies
  with `No space left on device`. Keep ~20 GB free on the host too.
- Root **SSH** to the ReadyNAS (RAIDiator "Enable SSH" / root-ssh add-on) for the
  install step.

## Quick start

`run.sh` builds the image, provisions a **case-sensitive state volume** (required
by crosstool-NG; a bind-mounted macOS dir is case-insensitive and fails),
registers SPARC `binfmt_misc`, and runs the pipeline:

```bash
./run.sh all          # -> dist/samba4-<version>-sparc-opt.tar.gz
```

Phases are **resumable** (stamp files on the state volume):

```bash
./run.sh status       # what's done
./run.sh toolchain    # phase 1 (crosstool-NG: gcc 7.5, glibc 2.19, binutils 2.38)
./run.sh deps         # phase 2 (zlib, popt, gmp, nettle, tasn1, unistring, gnutls)
./run.sh samba        # phase 3 (waf cross-build)
./run.sh package      # phase 4 (always re-runnable; picks up smb.conf/init tweaks)
./run.sh clean-samba  # rebuild just Samba, keep toolchain + deps
```

Heavy build trees live on a Docker named volume at `/state`; the repo is at
`/work`. Wipe everything: `docker volume rm readynas-samba4-state`.

Build scratch is auto-reclaimed after each phase succeeds. To keep it (or the
sources, for incremental Samba relinks) for debugging:

```bash
KEEP_SCRATCH=1 ./run.sh all      # leave intermediate build trees in place
RECLAIM=0 already the default    # sources/caches are kept unless RECLAIM=1
```

### Try a different Samba version

```bash
SAMBA_VERSION=4.9.18 ./run.sh clean-samba samba package
```

## Install on the NAS

Run on your workstation (needs ssh/scp to the NAS):

```bash
NAS_HOST=192.168.1.50 NAS_USER=root NAS_DATA_DIR=/c/opt \
  ./install/install-on-device.sh dist/samba4-4.13.17-sparc-opt.tar.gz
```

This uploads the tarball, extracts to the data volume, symlinks `/opt/samba`,
**stops any running smbd/nmbd** (stock SMB1 *and* a previous install), installs
the init script, **enables it at boot**, and starts the daemons. It preserves an
existing `smb.conf` across reinstalls (the shipped template is saved as
`smb.conf.default`).

**Boot ordering (RAIDiator-specific).** The device boots to the runlevel in
`/etc/inittab`'s `initdefault` (observed **3**, not the Debian default 2), and
its master boot script **`S99rc3`** assembles the LVM array and mounts the data
volume **late** — after ordinary `S##` scripts. Since `/opt/samba` lives on that
volume, a normal `S91samba` link runs *too early* and silently starts nothing.
The installer therefore links the service as **`/etc/rc<default>.d/S99zsamba`**
(sorts *after* `S99rc3`, so the volume is mounted first), and `start()` also
waits up to 90 s for `smbd` to appear as a safety net.

Then create a user and point a share at real data:

```bash
/opt/samba/bin/smbpasswd -a youruser        # user must already exist in /etc/passwd
# edit /opt/samba/etc/smb.conf: [data] path = /c/<your-share-dir>, valid users = youruser
/opt/samba/etc/init.d/S91samba restart
/opt/samba/etc/init.d/S91samba status       # shows pids + listening ports
```

> **Boot persistence caveat:** some ReadyNAS firmwares rebuild `/` at boot, which
> would wipe the `rc*.d` symlinks. Reboot once and check `ls -l /etc/rc3.d/S99zsamba`
> and `S91samba status`. (On the confirmed unit `/etc` persists and it comes up on
> its own.) If the link is gone, the root is volatile — add a persistent RAIDiator
> boot hook that runs `/opt/samba/etc/init.d/S91samba start`.

> **FrontView:** if the firmware's service monitor relaunches the stock Samba and
> fights for ports 139/445, disable the stock `samba` service too.

### Backup & revert to stock

Install is **safe and reversible**. On first install it records a manifest and
backs up anything it changes into `<NAS_DATA_DIR>/samba4-backup/` (whether stock
Samba was running, any pre-existing `/opt/samba` or init script) and drops a
self-contained `restore.sh`. To roll back:

```bash
NAS_HOST=192.168.1.50 ./install/uninstall-on-device.sh          # revert to stock
NAS_HOST=192.168.1.50 ./install/uninstall-on-device.sh --purge  # revert + delete backup
```

`uninstall` stops our Samba, removes the boot symlinks + init script, restores
any original `/opt/samba`, removes our data-volume tree, and restarts the stock
Samba if it had been running. Idempotent. You can also run it on the NAS
directly: `sh <NAS_DATA_DIR>/samba4-backup/restore.sh`.

## Verify

**Host-side (fast, no hardware)** — `run.sh package` already does this:

```bash
docker run --rm -v readynas-samba4-state:/state --entrypoint sh readynas-samba4 -c '
  readelf -h /state/stage/opt/samba/sbin/smbd | grep -E "Type|Machine"   # EXEC, SPARC
  qemu-sparc-static /state/stage/opt/samba/sbin/smbd --version'
```

**On the device:**

```bash
/opt/samba/etc/init.d/S91samba status                 # pids + 139/445 listening
/opt/samba/sbin/smbd -i -s /opt/samba/etc/smb.conf    # foreground; watch for errors
```

(There's no `smbstatus` in this minimal package — `status` reports from
`/proc` + `netstat` instead.)

**From a client (macOS):**

```bash
smbclient //<nas>/data -m SMB3 -U youruser -c 'ls'
# round-trip write+read:
echo hi > /tmp/t && smbclient //<nas>/data -m SMB3 -U youruser \
  -c 'put /tmp/t t.txt; get t.txt /tmp/back; del t.txt' && cat /tmp/back
# Finder: open smb://<nas>/data
```

Note: `smbclient -L` (share *enumeration*) uses the srvsvc RPC; connecting
directly to a share (`//nas/share`) is the more reliable smoke test. `blackbox`-
style NetBIOS name resolution can be flaky — use the IP if a name won't connect.

## On-device diagnostic tools

These live in `samba/` and are built ad-hoc with the cross toolchain when needed.
They exist because qemu can't reproduce the device's kernel/alignment behaviour —
each proves one thing on **real hardware**:

- **`dirprobe.c`** — which directory-read syscall works (`open`/`openat`/
  `getdents`/`fdopendir`). This is how we found `openat` returns ENOSYS.
- **`atshim.c`** — the `*at`-family emulation shim itself (also linked into smbd).
- **`attest.c` / `attest2.c`** — replay smbd's per-entry VFS ops through `atshim`
  to prove listing + `fstatat` work before rebuilding smbd.
- **`iconvtest.c`** — reproduces the `iconv`/gconv `SIGILL` in isolation and
  confirms which charsets are glibc-builtin vs. `dlopen`ed.
- **`nssfix.c`** — the "force files NSS" constructor (linked into each binary).

Build one, e.g.:

```bash
docker run --rm -v readynas-samba4-state:/state -v "$PWD":/work --entrypoint sh \
  readynas-samba4 -c '/state/x-tools/sparc-unknown-linux-gnu/bin/sparc-unknown-linux-gnu-gcc \
  -mcpu=v7 -O2 -static -fno-pic /work/samba/dirprobe.c -o /work/dist/dirprobe'
# scp dist/dirprobe root@<nas>:/tmp/ && ssh root@<nas> /tmp/dirprobe /c/media
```

### Debugging a device crash (core dump)

The device `gdb` is too old to read gcc-7 DWARF, and `gdb-multiarch` mis-parses
its SPARC register notes. The reliable path:

1. On device: `echo 2 > /proc/sys/fs/suid_dumpable; echo /tmp/core.%e.%p > /proc/sys/kernel/core_pattern; ulimit -c unlimited`, run smbd, reproduce.
2. Pull the core to the host and parse `NT_PRSTATUS` by hand — the sparc32 gregset
   is `[g0-7][o0-7][l0-7][i0-7][psr][pc][npc][y]`, so `%sp`=reg[14], `%fp`=reg[30],
   `%i7`=reg[31]. Walk the `%fp` chain (saved `%i7` at `fp+60`) for return addresses.
3. Resolve them with the cross `addr2line -e dist/smbd.debug` (build smbd unstripped
   from `bin/default/source3/smbd/smbd`). This is how the `iconv` crash was found.

## Layout

```
config.env                 all tunables (versions, paths, device settings)
common.sh                  shared logging / fetch / cross-env helpers
run.sh                     host wrapper: image + state volume + binfmt + build
Dockerfile                 Debian build env + qemu-sparc-static
build.sh                   resumable orchestrator (env→toolchain→deps→samba→package)
toolchain/
  crosstool-ng.defconfig   ct-ng config: sparc v7, glibc 2.19, binutils 2.38, gcc 7.5
  01-build-toolchain.sh
deps/02-build-deps.sh      zlib, popt, gmp, nettle, tasn1, unistring, gnutls → sysroot (static)
samba/
  03-build-samba.sh        waf cross build; config.h syscall undefs; source + c4che patches
  cross-answers.txt        cached/seeded waf answers
  nssfix.c                 force files NSS  (linked into binaries)
  atshim.c                 *at() syscall emulation via /proc/self/fd (linked in)
  dirprobe.c attest.c attest2.c iconvtest.c   on-device diagnostics
package/
  04-make-package.sh       assemble /opt/samba tree → dist/*.tar.gz (static path; dynamic legacy fallback)
  files/{smb.conf.template,S91samba,launcher.template}
install/
  install-on-device.sh     backup + install + enable-at-boot onto the NAS (safe, reversible)
  uninstall-on-device.sh   revert everything to the stock Samba setup
```

## Troubleshooting

- **Client: `NT_STATUS_NOT_SUPPORTED` listing a directory** — the `atshim`
  `openat` emulation isn't linked in. Confirm `nm dist/smbd.debug | grep ' openat'`
  shows a `T` (defined) symbol; rebuild with `./run.sh clean-samba samba package`.
- **Connection drops mid-listing, `SIGILL`, no Samba panic** — a charset went to
  glibc `iconv`. Ensure `smb.conf` has `dos charset = ISO-8859-1` and
  `unix charset = UTF-8` (both Samba built-ins); `CP850`/`CP437`/`UTF8`-as-dos
  will crash.
- **`Unable to locate guest account [nobody]` / user lookups fail** — `nssfix.o`
  isn't linked, or glibc wasn't built `--enable-static-nss`. Check the c4che
  `LINKFLAGS` includes `nssfix.o`.
- **`cannot setup ep pipe` at startup** — the `lib/util/modules.c` opendir patch
  didn't apply; re-run `./run.sh clean-samba samba`.
- **`open_socket_in: Address family not supported`** at startup — harmless: the
  2.6.17 kernel has no IPv6; smbd binds IPv4 and keeps running.
- **Old smbd/nmbd pile up / ports 139-445 stuck** — never rely on bare `ps` over
  ssh (no tty → prints nothing). The stop paths scan `/proc` and use
  `start-stop-daemon --name`; kill leftovers with
  `for p in smbd nmbd; do start-stop-daemon --stop --oknodo --name $p; done`.
- **`smbd` segfaults immediately even for `--version`** — binaries came out PIE
  (`ET_DYN`); the build passes `--without-pie --without-relro`, verify with
  `readelf -h` → `Type: EXEC`. Runs fine under qemu regardless, so this only
  shows on real hardware.
- **`Your file system … is *not* case-sensitive!`** — build scratch landed on a
  bind-mounted macOS path. Use `./run.sh` (case-sensitive Docker volume).
- **`No space left on device` during toolchain build** — raise Docker's virtual
  disk to ≥ 20 GB, then `docker volume rm readynas-samba4-state` and rerun.
- **Toolchain built the wrong glibc/gcc (e.g. glibc 2.35)** — the defconfig
  version *choice* symbols didn't apply. They must be `CT_GLIBC_V_2_19=y` /
  `CT_GCC_V_7=y` style (not `CT_..._VERSION="..."` strings). glibc must stay
  ≤ 2.19 or it won't run on the 2.6.17 kernel.
```

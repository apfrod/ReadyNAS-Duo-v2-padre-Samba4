/* readynas-samba4: emulate the *at() family on the Infrant 2.6.17 kernel.
 *
 * The device kernel does NOT implement openat/fstatat/unlinkat/... (the whole
 * *at syscall family, added to SPARC after 2.6.17). Samba 4.13's VFS is built
 * entirely on these calls, so every file/dir open ENOSYSes -> the client sees
 * NT_STATUS_NOT_SUPPORTED. Confirmed on hardware with dirprobe:
 *     SYS_openat(...) -> Function not implemented
 *     open()/getdents/fdopendir/readdir -> OK
 *
 * These strong definitions OVERRIDE glibc's *at functions at static-link time
 * (an explicit .o beats the weak alias inside libc.a). Each one first tries the
 * real syscall (so the same binary still works on a modern kernel / under qemu)
 * and, on ENOSYS, falls back to the classic non-*at syscall applied to a path
 * resolved through /proc/self/fd/<dirfd> — which the device mounts and which
 * pins the directory by its open fd, so relative resolution stays correct.
 *
 * Linked into smbd/nmbd via LINKFLAGS in samba/03-build-samba.sh, alongside
 * nssfix.o. Local-fileserver scope: the /proc/self/fd re-resolution slightly
 * weakens openat's symlink-race guarantees vs. a native kernel, which is an
 * acceptable trade to run at all on this hardware.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/syscall.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif
#ifndef O_LARGEFILE
#define O_LARGEFILE 0
#endif

/* glibc's versioned stat entry points (they use the old *stat64 syscalls that
 * DO exist on 2.6.17); we build the *at variants on top of them. */
extern int __xstat(int, const char *, struct stat *);
extern int __lxstat(int, const char *, struct stat *);
extern int __fxstat(int, int, struct stat *);
extern int __xstat64(int, const char *, struct stat64 *);
extern int __lxstat64(int, const char *, struct stat64 *);
extern int __fxstat64(int, int, struct stat64 *);
extern int __xmknod(int, const char *, mode_t, dev_t *);

/* Build "plain path" for a (dirfd, path) pair:
 *   - AT_FDCWD or absolute path  -> path as-is
 *   - relative to a real dirfd   -> /proc/self/fd/<dirfd>/<path>
 *   - empty path (AT_EMPTY_PATH) -> /proc/self/fd/<dirfd>
 * Returns 0 on success, -1 (errno set) on overflow. */
static int at_path(char *out, size_t n, int dirfd, const char *path)
{
	if (dirfd == AT_FDCWD || (path && path[0] == '/')) {
		if (!path || strlen(path) >= n) { errno = ENAMETOOLONG; return -1; }
		strcpy(out, path);
		return 0;
	}
	if (path && path[0])
		(void)snprintf(out, n, "/proc/self/fd/%d/%s", dirfd, path);
	else
		(void)snprintf(out, n, "/proc/self/fd/%d", dirfd);
	return 0;
}

/* --- openat / openat64 -----------------------------------------------------
 * Samba is built _FILE_OFFSET_BITS=64, so its openat() calls resolve to
 * openat64(). O_LARGEFILE is mandatory: this is a 32-bit host and media files
 * routinely exceed 2GB — without it the fallback open() returns EOVERFLOW. */
int openat(int dirfd, const char *path, int flags, ...)
{
	mode_t mode = 0;
	long r;
	char buf[PATH_MAX];

	if (flags & O_CREAT) {
		va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap);
	}
	r = syscall(SYS_openat, dirfd, path, flags | O_LARGEFILE, mode);
	if (r >= 0 || errno != ENOSYS) return (int)r;

	if (at_path(buf, sizeof buf, dirfd, path) < 0) return -1;
	return open(buf, flags | O_LARGEFILE, mode);
}
int openat64(int, const char *, int, ...) __attribute__((alias("openat")));

/* --- fstatat, via glibc's versioned __fxstatat entry points ----------------
 * fstatat() redirects to __fxstatat (non-LFS) / __fxstatat64 (LFS, what Samba
 * uses). Emulate on the plain *stat64 syscalls, which the device DOES have. */
int __fxstatat(int ver, int dirfd, const char *path, struct stat *st, int flags)
{
	char buf[PATH_MAX];
	if ((flags & AT_EMPTY_PATH) && (!path || !path[0]))
		return __fxstat(ver, dirfd, st);
	if (at_path(buf, sizeof buf, dirfd, path) < 0) return -1;
	return (flags & AT_SYMLINK_NOFOLLOW) ? __lxstat(ver, buf, st)
	                                     : __xstat(ver, buf, st);
}
int __fxstatat64(int ver, int dirfd, const char *path, struct stat64 *st, int flags)
{
	char buf[PATH_MAX];
	if ((flags & AT_EMPTY_PATH) && (!path || !path[0]))
		return __fxstat64(ver, dirfd, st);
	if (at_path(buf, sizeof buf, dirfd, path) < 0) return -1;
	return (flags & AT_SYMLINK_NOFOLLOW) ? __lxstat64(ver, buf, st)
	                                     : __xstat64(ver, buf, st);
}

/* --- directory / name ops -------------------------------------------------- */
int mkdirat(int dirfd, const char *path, mode_t mode)
{
	long r = syscall(SYS_mkdirat, dirfd, path, mode);
	char buf[PATH_MAX];
	if (r >= 0 || errno != ENOSYS) return (int)r;
	if (at_path(buf, sizeof buf, dirfd, path) < 0) return -1;
	return mkdir(buf, mode);
}

int unlinkat(int dirfd, const char *path, int flags)
{
	long r = syscall(SYS_unlinkat, dirfd, path, flags);
	char buf[PATH_MAX];
	if (r >= 0 || errno != ENOSYS) return (int)r;
	if (at_path(buf, sizeof buf, dirfd, path) < 0) return -1;
	return (flags & AT_REMOVEDIR) ? rmdir(buf) : unlink(buf);
}

int renameat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath)
{
	long r = syscall(SYS_renameat, olddirfd, oldpath, newdirfd, newpath);
	char ob[PATH_MAX], nb[PATH_MAX];
	if (r >= 0 || errno != ENOSYS) return (int)r;
	if (at_path(ob, sizeof ob, olddirfd, oldpath) < 0) return -1;
	if (at_path(nb, sizeof nb, newdirfd, newpath) < 0) return -1;
	return rename(ob, nb);
}

int linkat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, int flags)
{
	long r = syscall(SYS_linkat, olddirfd, oldpath, newdirfd, newpath, flags);
	char ob[PATH_MAX], nb[PATH_MAX];
	if (r >= 0 || errno != ENOSYS) return (int)r;
	if (at_path(ob, sizeof ob, olddirfd, oldpath) < 0) return -1;
	if (at_path(nb, sizeof nb, newdirfd, newpath) < 0) return -1;
	return link(ob, nb);
}

int symlinkat(const char *target, int newdirfd, const char *linkpath)
{
	long r = syscall(SYS_symlinkat, target, newdirfd, linkpath);
	char nb[PATH_MAX];
	if (r >= 0 || errno != ENOSYS) return (int)r;
	if (at_path(nb, sizeof nb, newdirfd, linkpath) < 0) return -1;
	return symlink(target, nb);
}

ssize_t readlinkat(int dirfd, const char *path, char *buf, size_t bufsiz)
{
	long r = syscall(SYS_readlinkat, dirfd, path, buf, bufsiz);
	char pb[PATH_MAX];
	if (r >= 0 || errno != ENOSYS) return (ssize_t)r;
	if (at_path(pb, sizeof pb, dirfd, path) < 0) return -1;
	return readlink(pb, buf, bufsiz);
}

int fchownat(int dirfd, const char *path, uid_t owner, gid_t group, int flags)
{
	long r = syscall(SYS_fchownat, dirfd, path, owner, group, flags);
	char buf[PATH_MAX];
	if (r >= 0 || errno != ENOSYS) return (int)r;
	if (at_path(buf, sizeof buf, dirfd, path) < 0) return -1;
	return (flags & AT_SYMLINK_NOFOLLOW) ? lchown(buf, owner, group)
	                                     : chown(buf, owner, group);
}

int fchmodat(int dirfd, const char *path, mode_t mode, int flags)
{
	long r = syscall(SYS_fchmodat, dirfd, path, mode, flags);
	char buf[PATH_MAX];
	if (r >= 0 || errno != ENOSYS) return (int)r;
	if (at_path(buf, sizeof buf, dirfd, path) < 0) return -1;
	/* No lchmod on Linux; AT_SYMLINK_NOFOLLOW on a symlink isn't supported,
	 * but Samba only chmods real files here. */
	return chmod(buf, mode);
}

int faccessat(int dirfd, const char *path, int mode, int flags)
{
	long r = syscall(SYS_faccessat, dirfd, path, mode, flags);
	char buf[PATH_MAX];
	if (r >= 0 || errno != ENOSYS) return (int)r;
	if (at_path(buf, sizeof buf, dirfd, path) < 0) return -1;
	return access(buf, mode);
}

/* mknodat() redirects to __xmknodat(_MKNOD_VER, ..., &dev) in glibc. */
int __xmknodat(int ver, int dirfd, const char *path, mode_t mode, dev_t *dev)
{
	long r = syscall(SYS_mknodat, dirfd, path, mode, dev ? *dev : 0);
	char buf[PATH_MAX];
	if (r >= 0 || errno != ENOSYS) return (int)r;
	if (at_path(buf, sizeof buf, dirfd, path) < 0) return -1;
	return __xmknod(ver, buf, mode, dev);
}

/* utimensat: nanosecond times relative to a dirfd. The device also lacks the
 * utimensat syscall (2.6.22), so fall back to utimes() (microsecond). Handle
 * UTIME_NOW (pass NULL -> "now") and UTIME_OMIT (read current value first). */
int utimensat(int dirfd, const char *path, const struct timespec times[2], int flags)
{
	long r = syscall(SYS_utimensat, dirfd, path, times, flags);
	char buf[PATH_MAX];
	struct timeval tv[2];
	if (r >= 0 || errno != ENOSYS) return (int)r;
	if (at_path(buf, sizeof buf, dirfd, path) < 0) return -1;

	if (times == NULL) return utimes(buf, NULL);

	if (times[0].tv_nsec == UTIME_OMIT || times[1].tv_nsec == UTIME_OMIT ||
	    times[0].tv_nsec == UTIME_NOW  || times[1].tv_nsec == UTIME_NOW) {
		struct stat st;
		struct timeval now;
		gettimeofday(&now, NULL);
		if ((flags & AT_SYMLINK_NOFOLLOW ? lstat(buf, &st) : stat(buf, &st)) < 0) {
			/* if the file doesn't exist yet, best-effort "now" */
			st.st_atime = now.tv_sec; st.st_mtime = now.tv_sec;
		}
		/* atime */
		if (times[0].tv_nsec == UTIME_NOW)      { tv[0].tv_sec = now.tv_sec; tv[0].tv_usec = now.tv_usec; }
		else if (times[0].tv_nsec == UTIME_OMIT){ tv[0].tv_sec = st.st_atime; tv[0].tv_usec = 0; }
		else                                    { tv[0].tv_sec = times[0].tv_sec; tv[0].tv_usec = times[0].tv_nsec / 1000; }
		/* mtime */
		if (times[1].tv_nsec == UTIME_NOW)      { tv[1].tv_sec = now.tv_sec; tv[1].tv_usec = now.tv_usec; }
		else if (times[1].tv_nsec == UTIME_OMIT){ tv[1].tv_sec = st.st_mtime; tv[1].tv_usec = 0; }
		else                                    { tv[1].tv_sec = times[1].tv_sec; tv[1].tv_usec = times[1].tv_nsec / 1000; }
	} else {
		tv[0].tv_sec = times[0].tv_sec; tv[0].tv_usec = times[0].tv_nsec / 1000;
		tv[1].tv_sec = times[1].tv_sec; tv[1].tv_usec = times[1].tv_nsec / 1000;
	}
	return utimes(buf, tv);
}

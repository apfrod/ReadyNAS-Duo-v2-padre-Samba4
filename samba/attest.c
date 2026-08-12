/* Validate atshim.c on the device: exercise openat/fstatat via the shim the
 * same way smbd's VFS does, and confirm we can list + stat /c/media. */
#define _GNU_SOURCE
#include <stdio.h>
#include <dirent.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <libgen.h>
#include <string.h>

static void list_via_fd(int dfd, const char *label)
{
	DIR *d; struct dirent *e; int n = 0;
	printf("[%s] fdopendir(fd=%d)...\n", label, dfd);
	d = fdopendir(dfd);
	if (!d) { printf("  fdopendir FAIL: %s\n", strerror(errno)); return; }
	while ((e = readdir(d))) { if (n < 6) printf("   [%s]\n", e->d_name); n++; }
	printf("  entries=%d\n", n);
	closedir(d);
}

int main(int argc, char **argv)
{
	const char *p = argc > 1 ? argv[1] : "/c/media";
	int fd;
	struct stat st;

	/* 1. openat(AT_FDCWD, absolute) -> shim should open the dir */
	printf("== openat(AT_FDCWD, %s, O_DIRECTORY) via shim ==\n", p);
	fd = openat(AT_FDCWD, p, O_RDONLY | O_DIRECTORY);
	if (fd < 0) { printf("  FAIL: %s\n", strerror(errno)); }
	else { list_via_fd(fd, "abs"); /* fd consumed by closedir */ }

	/* 2. openat(parent_fd, "basename") -> exercises /proc/self/fd emulation */
	{
		char pdup[4096], bdup[4096];
		strncpy(pdup, p, sizeof pdup - 1); pdup[sizeof pdup - 1] = 0;
		strncpy(bdup, p, sizeof bdup - 1); bdup[sizeof bdup - 1] = 0;
		char *parent = dirname(pdup);
		char *base   = basename(bdup);
		printf("== openat(open(%s), \"%s\") via /proc/self/fd emulation ==\n", parent, base);
		int pfd = open(parent, O_RDONLY | O_DIRECTORY);
		if (pfd < 0) { printf("  open(parent) FAIL: %s\n", strerror(errno)); }
		else {
			int cfd = openat(pfd, base, O_RDONLY | O_DIRECTORY);
			if (cfd < 0) { printf("  openat(rel) FAIL: %s\n", strerror(errno)); }
			else { list_via_fd(cfd, "rel"); }
			close(pfd);
		}
	}

	/* 3. fstatat via shim: AT_EMPTY_PATH on a dirfd, and a named entry */
	printf("== fstatat via shim ==\n");
	fd = open(p, O_RDONLY | O_DIRECTORY);
	if (fd >= 0) {
		if (fstatat(fd, "", &st, AT_EMPTY_PATH) == 0)
			printf("  fstatat(fd,\"\",AT_EMPTY_PATH): OK mode=%o\n", (unsigned)st.st_mode);
		else
			printf("  fstatat(AT_EMPTY_PATH) FAIL: %s\n", strerror(errno));
		if (fstatat(fd, ".", &st, 0) == 0)
			printf("  fstatat(fd,\".\"): OK ino=%lu\n", (unsigned long)st.st_ino);
		else
			printf("  fstatat(\".\") FAIL: %s\n", strerror(errno));
		close(fd);
	}
	printf("== done ==\n");
	return 0;
}

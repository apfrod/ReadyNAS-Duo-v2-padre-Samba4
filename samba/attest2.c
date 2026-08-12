/* Replay smbd's per-directory-entry VFS ops on /c/media through atshim.o, one
 * op at a time with unbuffered logging, so the LAST line printed before a crash
 * names the exact operation + entry that killed smbd. Mirrors: openat(dir) +
 * fdopendir + readdir, then per entry fstatat(AT_SYMLINK_NOFOLLOW), a full-path
 * lstat, readlinkat for symlinks, and getxattr("user.DOSATTRIB"). */
#define _GNU_SOURCE
#include <stdio.h>
#include <dirent.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/xattr.h>

#define SAY(...) do { fprintf(stderr, __VA_ARGS__); fflush(stderr); } while (0)

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : "/c/media";
	int dfd, n = 0;
	DIR *d;
	struct dirent *e;

	setvbuf(stderr, NULL, _IONBF, 0);

	SAY("open(%s, O_DIRECTORY)...\n", dir);
	dfd = openat(AT_FDCWD, dir, O_RDONLY | O_DIRECTORY);
	if (dfd < 0) { SAY("  FAIL %s\n", strerror(errno)); return 1; }

	SAY("fdopendir...\n");
	d = fdopendir(dfd);
	if (!d) { SAY("  FAIL %s\n", strerror(errno)); return 1; }

	while ((e = readdir(d))) {
		char full[8192];
		struct stat st;
		char xb[256], lb[4096];
		int r;
		ssize_t sr;
		const char *name = e->d_name;

		n++;
		SAY("[%02d] name=[%s]\n", n, name);

		SAY("     fstatat(dfd,name,NOFOLLOW)... ");
		r = fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW);
		SAY("r=%d%s mode=%o\n", r, r ? strerror(errno) : "", r ? 0 : (unsigned)st.st_mode);

		snprintf(full, sizeof full, "%s/%s", dir, name);

		SAY("     lstat(%s)... ", full);
		r = lstat(full, &st);
		SAY("r=%d%s\n", r, r ? strerror(errno) : "");

		if (r == 0 && S_ISLNK(st.st_mode)) {
			SAY("     readlinkat(dfd,name)... ");
			sr = readlinkat(dfd, name, lb, sizeof lb - 1);
			SAY("sr=%ld%s\n", (long)sr, sr < 0 ? strerror(errno) : "");
		}

		SAY("     getxattr(user.DOSATTRIB)... ");
		sr = getxattr(full, "user.DOSATTRIB", xb, sizeof xb);
		SAY("sr=%ld errno=%s\n", (long)sr, sr < 0 ? strerror(errno) : "ok");
	}
	SAY("DONE: %d entries, no crash\n", n);
	closedir(d);
	return 0;
}

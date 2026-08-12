/* readynas-samba4 dirprobe: find out which directory-read syscall ENOSYSes on
 * the Infrant 2.6.17 kernel. smbd lists dirs via open()/openat() + fdopendir()
 * + readdir(); one of those returns ENOSYS -> NT_STATUS_NOT_SUPPORTED.
 * Build: static, non-PIC, same toolchain as smbd.  Run: ./dirprobe /c/media   */
#define _GNU_SOURCE
#include <stdio.h>
#include <dirent.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/stat.h>

static void hr(const char *s){ printf("---- %s ----\n", s); }

int main(int argc, char **argv)
{
    const char *p = argc > 1 ? argv[1] : "/c/media";
    int fd;
    long r;

    printf("probing directory reads on: %s\n", p);

    hr("plain open() syscall");
    errno = 0;
    fd = open(p, O_RDONLY);
    printf("open(%s, O_RDONLY): fd=%d  %s\n", p, fd, fd < 0 ? strerror(errno) : "OK");
    if (fd >= 0) close(fd);

    hr("open() with O_DIRECTORY");
    errno = 0;
    fd = open(p, O_RDONLY | O_DIRECTORY);
    printf("open(%s, O_DIRECTORY): fd=%d  %s\n", p, fd, fd < 0 ? strerror(errno) : "OK");

    hr("raw SYS_openat");
    errno = 0;
    r = syscall(SYS_openat, AT_FDCWD, p, O_RDONLY);
    printf("SYS_openat(AT_FDCWD,%s): ret=%ld  %s\n", p, r, r < 0 ? strerror(errno) : "OK");
    if (r >= 0) close((int)r);

#ifdef SYS_getdents64
    if (fd >= 0) {
        char buf[4096];
        hr("raw SYS_getdents64 on the O_DIRECTORY fd");
        errno = 0;
        r = syscall(SYS_getdents64, fd, buf, sizeof buf);
        printf("SYS_getdents64(fd): ret=%ld  %s\n", r, r < 0 ? strerror(errno) : "OK");
        lseek(fd, 0, SEEK_SET);
    }
#endif
#ifdef SYS_getdents
    if (fd >= 0) {
        char buf[4096];
        hr("raw SYS_getdents (legacy) on the O_DIRECTORY fd");
        errno = 0;
        r = syscall(SYS_getdents, fd, buf, sizeof buf);
        printf("SYS_getdents(fd): ret=%ld  %s\n", r, r < 0 ? strerror(errno) : "OK");
        lseek(fd, 0, SEEK_SET);
    }
#endif

    hr("fdopendir() + readdir()  (exactly what smbd does)");
    if (fd >= 0) {
        DIR *d;
        errno = 0;
        d = fdopendir(fd);
        if (!d) {
            printf("fdopendir(fd): FAIL  %s\n", strerror(errno));
        } else {
            struct dirent *e; int n = 0;
            errno = 0;
            while ((e = readdir(d))) { if (n < 8) printf("   [%s]\n", e->d_name); n++; }
            printf("fdopendir+readdir: entries=%d  end-errno=%s\n",
                   n, errno ? strerror(errno) : "OK");
            closedir(d);
            fd = -1; /* closedir closed it */
        }
    }
    if (fd >= 0) close(fd);

    hr("plain opendir() + readdir()");
    {
        DIR *d;
        errno = 0;
        d = opendir(p);
        if (!d) {
            printf("opendir(%s): FAIL  %s\n", p, strerror(errno));
        } else {
            struct dirent *e; int n = 0;
            errno = 0;
            while ((e = readdir(d))) n++;
            printf("opendir+readdir: entries=%d  end-errno=%s\n",
                   n, errno ? strerror(errno) : "OK");
            closedir(d);
        }
    }
    return 0;
}

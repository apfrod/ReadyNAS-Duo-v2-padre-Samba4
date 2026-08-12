/* Reproduce + validate the fix for the iconv/gconv crash. smbd converts a
 * UTF-16 string (from a user.DOSATTRIB xattr) via glibc iconv, which dlopen's
 * /usr/lib/gconv/UTF-16.so — the device's stock glibc-2.3.2 module — into our
 * static glibc-2.19 binary => ABI mismatch => SIGILL. With GCONV_PATH pointed
 * at a directory that has no gconv-modules, glibc uses only its BUILTIN
 * converters (UTF-16/UTF-8/UCS-2/ASCII/...), no dlopen. This tests whether the
 * conversions smbd needs are covered by the builtins. */
#define _GNU_SOURCE
#include <iconv.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

static int try(const char *to, const char *from)
{
	char in[] = "Hello";
	char out[64];
	char *ip = in, *op = out;
	size_t il = strlen(in), ol = sizeof out;
	iconv_t cd;

	printf("iconv_open(to=%s, from=%s)... ", to, from);
	fflush(stdout);
	cd = iconv_open(to, from);
	if (cd == (iconv_t)-1) { printf("OPEN FAILED: %s\n", strerror(errno)); return 1; }
	size_t r = iconv(cd, &ip, &il, &op, &ol);
	printf("OK (open) ; iconv r=%ld out=%d bytes\n", (long)r, (int)(sizeof out - ol));
	iconv_close(cd);
	return 0;
}

int main(void)
{
	printf("GCONV_PATH=%s\n", getenv("GCONV_PATH") ? getenv("GCONV_PATH") : "(unset)");
	/* The pairs smbd uses around NDR/DOS-attr + normal SMB charset work. */
	try("UTF-16LE", "UTF-8");
	try("UTF-8", "UTF-16LE");
	try("UTF-16LE", "UTF-8//");
	try("UCS-2LE", "UTF-8");
	try("UTF-8", "UCS-2LE");
	printf("done\n");
	return 0;
}

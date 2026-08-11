/* readynas-samba4: force glibc NSS to the compiled-in 'files' service.
 *
 * The ReadyNAS /etc/nsswitch.conf uses `passwd: compat` (Debian-sarge default).
 * `compat` is a SHARED NSS module (libnss_compat.so) — a fully static binary
 * can't dlopen it, so every getpwnam/getgrnam fails ("Unable to locate guest
 * account [nobody]"). Our glibc is built --enable-static-nss, which compiles in
 * ONLY 'files' + 'dns'. This constructor runs before main() and overrides the
 * service list to 'files' for the databases Samba needs, so lookups read
 * /etc/passwd / /etc/group directly regardless of the system's nsswitch.conf.
 *
 * Linked into smbd/nmbd/smbpasswd via LINKFLAGS in samba/03-build-samba.sh.
 */
extern int __nss_configure_lookup(const char *db, const char *service);

__attribute__((constructor))
static void readynas_force_files_nss(void)
{
    __nss_configure_lookup("passwd", "files");
    __nss_configure_lookup("group",  "files");
    __nss_configure_lookup("shadow", "files");
}

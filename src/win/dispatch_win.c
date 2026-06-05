/* Multicall dispatch for the embedded single-binary perl.exe (mingw win32).
 *
 * perl has no native argv[0] dispatch, so we intercept main itself. mingw's
 * CRT (__tmainCRTStartup) calls main() by symbol, so `-Wl,--wrap=main` routes
 * that reference to __wrap_main while __real_main stays perl's own generated
 * main (proven: the CRT lands in __wrap_main). When the binary is invoked under
 * an applet name (argv[0] basename, with any "/" or "\" stripped and a trailing
 * ".exe" removed, matches the curated list) we rewrite argv to
 *     [argv[0], "/zip/bin/<applet>", original args...]
 * and hand off to perl. The /zip/bin/<applet> script is served from the blob by
 * the @INC VFS, exactly like a module -- no script on disk. Invoked as plain
 * "perl"/"perl.exe" (or any non-applet name) we pass argv straight through.
 *
 * Same curated 16 as the Linux/darwin backends: pure-Perl end-user utilities
 * that run cleanly in a single static binary. XS-codegen/dev tools, mail/config
 * helpers, perlivp, ptardiff, and the .pod-dependent perldoc/splain are excluded.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static const char *const applets[] = {
    "cpan", "corelist", "encguess", "json_pp", "piconv",
    "pod2html", "pod2man", "pod2text", "pod2usage", "podchecker",
    "prove", "ptar", "ptargrep", "shasum",
    "streamzip", "zipdetails", NULL
};

/* basename of a Windows path: drop everything up to the last / or \, then a
 * trailing ".exe" (case-insensitive) so "C:\dir\cpan.exe" -> "cpan". */
static void win_base(const char *a0, char *out, size_t n) {
    const char *b = a0;
    for (const char *p = a0; *p; p++)
        if (*p == '/' || *p == '\\') b = p + 1;
    size_t len = strlen(b);
    if (len >= 4) {
        const char *suf = b + len - 4;
        if ((suf[0]=='.') && (suf[1]=='e'||suf[1]=='E') &&
            (suf[2]=='x'||suf[2]=='X') && (suf[3]=='e'||suf[3]=='E'))
            len -= 4;
    }
    if (len >= n) len = n - 1;
    memcpy(out, b, len);
    out[len] = '\0';
}

extern int __real_main(int argc, char **argv, char **envp);

int __wrap_main(int argc, char **argv, char **envp) {
    const char *a0 = (argc > 0 && argv[0]) ? argv[0] : "";
    char base[64];
    win_base(a0, base, sizeof base);
    for (const char *const *p = applets; *p; p++) {
        if (strcmp(base, *p) != 0) continue;
        char path[64];
        snprintf(path, sizeof path, "/zip/bin/%s", *p);
        char **nv = malloc((size_t)(argc + 2) * sizeof *nv);
        if (!nv) break;            /* OOM: fall back to plain perl */
        nv[0] = argv[0];
        nv[1] = path;
        for (int i = 1; i < argc; i++) nv[i + 1] = argv[i];
        nv[argc + 1] = NULL;
        return __real_main(argc + 1, nv, envp);
    }
    return __real_main(argc, argv, envp);
}

/* Multicall dispatch for the embedded single-binary perl.
 *
 * perl has no native argv[0] dispatch, so we intercept main itself. When the
 * binary is invoked under an applet name (e.g. argv[0] basename == "json_pp"),
 * we rewrite argv to
 *     [argv[0], "/zip/bin/<applet>", original args...]
 * and hand off to perl. The /zip/bin/<applet> script is served from the blob by
 * the @INC VFS, exactly like a module -- no script on disk. Invoked as plain
 * "perl" (or any non-applet name) we pass argv straight through.
 *
 *   Engine (Linux + macOS, -DUNPIN_DISPATCH_NOWRAP): under the unpin-llvm engine
 *                  every object is LLVM bitcode, so neither `ld --wrap` (dropped
 *                  by the mega fold) nor `objcopy --redefine-sym` (can't edit a
 *                  bitcode symtab) can bind the entry. perlmain's `@main` is
 *                  renamed to `@real_main` in the IR instead, and this object
 *                  supplies plain `main`. One path for both platforms.
 *   Off-engine Windows (mingw): -Wl,--wrap=main routes the crt's main() to
 *                  __wrap_main; __real_main is perl's own generated main.
 *
 * Curated list (16): the pure-Perl end-user utilities that run cleanly in a
 * single static -Uusedl binary. XS-codegen/dev tools (xsubpp, h2xs, enc2xs,
 * h2ph, pl2pm, instmodsh), mail/config helpers (perlbug, perlthanks, libnetcfg),
 * the install-layout probe (perlivp), Text::Diff-dependent ptardiff, and the
 * tools that need a .pod we drop from the blob (perldoc, splain -> perldiag.pod)
 * are intentionally excluded.
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

static int unpin_dispatch(int argc, char **argv, char **envp,
                          int (*real)(int, char **, char **)) {
    const char *a0 = (argc > 0 && argv[0]) ? argv[0] : "";
    const char *base = strrchr(a0, '/');
    base = base ? base + 1 : a0;
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
        return real(argc + 1, nv, envp);
    }
    return real(argc, argv, envp);
}

#ifdef UNPIN_DISPATCH_NOWRAP
/* Engine (linux + darwin): perlmain's main() is IR-renamed to real_main; we
 * supply the crt entry. Only the FINAL perl link pulls this object in -- never
 * miniperl, whose own main is left untouched. */
extern int real_main(int argc, char **argv, char **envp);
int main(int argc, char **argv, char **envp) {
    return unpin_dispatch(argc, argv, envp, real_main);
}
#else
/* Off-engine Windows (mingw): -Wl,--wrap=main. */
extern int __real_main(int argc, char **argv, char **envp);
int __wrap_main(int argc, char **argv, char **envp) {
    return unpin_dispatch(argc, argv, envp, __real_main);
}
#endif

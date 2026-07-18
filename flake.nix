{
  description = "perl (interpreter + entire stdlib embedded) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # perl as ONE self-contained binary: the interpreter plus its entire @INC
  # (`share/perl5`) embedded inside the executable, with no companion data
  # archive on disk. The standard perl ships a binary that reads its modules
  # from a separate `share/perl5` tree; here that tree is packed into the binary
  # and served at runtime by a linker-level VFS — perl loads `File::Spec`,
  # `Data::Dumper`, `CPAN`, … straight from the embedded ZIP.
  #
  # How the VFS works (no patch to perl's source):
  #   - @INC is pinned to the virtual root `/zip/share/perl5` (config.over sets
  #     the runtime *exp vars; the install dirs stay real so `make install` still
  #     lands a harvestable tree).
  #   - The interpreter's open/stat/lstat/access are intercepted and, for any
  #     `/zip/...` path, served from the binary's single embedded metadata/
  #     runtime ZIP — appended at the executable's EOF by the nix build
  #     (withUnpinEmbed) and read back by the shared unpin-vfs core in self-EOF
  #     mode (-DUNPIN_VFS_SELF); entries are zstd (ZIP method 93, shared dict).
  #     A matched open returns an in-memory fd; everything downstream —
  #     read/lseek/fstat — works unchanged. `/zip` is a reserved virtual mount
  #     (hijack model, like Cosmopolitan's zipos): a miss is ENOENT, never the
  #     host FS. Under the unpin-llvm engine every object is LLVM bitcode, so the
  #     interception can use neither `ld --wrap` nor `objcopy --redefine-sym`;
  #     instead perl's open/stat/lstat/access references are rewritten in the IR
  #     (opt -S | sed | opt) to the unpinvfs_* shims (the tcc approach). One path
  #     for Linux and darwin.
  #
  # Multicall: the 16 pure-Perl utilities that run cleanly in a static, no-XS
  # binary (cpan, json_pp, shasum, prove, pod2*, ptar*, …) are embedded as
  # `/zip/bin/<name>` scripts and dispatched by argv[0] — `main` is intercepted
  # (perlmain's `main` is IR-renamed to `real_main`; dispatch.o supplies `main`)
  # so invoking the binary as `json_pp` runs the embedded script. `withAliases` harvests the names so
  # `unpin install perl` creates the command links. Excluded: XS-codegen/dev
  # tools (xsubpp/h2xs/enc2xs/…), perlbug/libnetcfg, perlivp, and the tools that
  # need a `.pod` we drop for size (perldoc, splain).
  #
  # This is a single-static binary: it is `-Uusedl` (no DynaLoader), so XS
  # modules cannot be loaded. Pure-Perl modules install fine — `sitecustomize.pl`
  # points module installs and @INC at a per-user cache dir at runtime, so `cpan`
  # works without touching the read-only binary.
  #
  # STATUS: Linux (native + the cross arches), darwin and Windows (mingw-native,
  # see windows.nix) are all wired through this same embedded-@INC design.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # The 16 curated multicall applets. Kept in sync with src/dispatch.c.
      applets = [
        "cpan" "corelist" "encguess" "json_pp" "piconv"
        "pod2html" "pod2man" "pod2text" "pod2usage" "podchecker"
        "prove" "ptar" "ptargrep" "shasum"
        "streamzip" "zipdetails"
      ];
      appletsCsv = builtins.concatStringsSep "," applets;

      # The whole embedded-perl pipeline for one target's static package set:
      #   A (treePerl) installs share/perl5 with @INC pinned to /zip      →
      #   B (vfsPerl)  is the same perl relinked with the VFS (self-EOF), with
      #                share/perl5 dropped from disk                      →
      #   withUnpinEmbed stages that tree + the applet scripts and packs the
      #                binary's single EOF ZIP (aliases + man in the same pack).
      mk = pkgs:
        let
          sp = pkgs.pkgsStatic;            # static set the binary is built from
          host = sp.stdenv.hostPlatform;
          isDarwin = host.isDarwin or false;
          # When the build host can't run target binaries, nixpkgs builds perl
          # with perl-cross, whose own ./configure ignores config.over (the native
          # @INC/install pin). Those targets get the equivalent fixup applied to
          # config.sh in postConfigure instead. Mirrors interpreter.nix's own
          # `crossCompiling`.
          crossCompiling = !(sp.stdenv.buildPlatform.canExecute host);
          prefix = sp.stdenv.cc.targetPrefix;

          perlPatches = [ ./patches/ext-re-static-aux.patch ];

          # A real musl (of the same 1.2.x ABI the engine ships) whose header dir
          # gives perl's native Configure something real to scan — the engine's own
          # musl headers live inside the clang binary's VFS, invisible to Configure's
          # `test -f` probes. Same package nixpkgs' perl expr resolves via
          # stdenv.cc.libc (null under the engine). A fresh non-engine nixpkgs import
          # (like tcc's linuxPkgs) so the swap doesn't drag it onto the engine.
          # Linux native only: darwin detects against its SDK, crosses use perl-cross.
          # Use the HOST platform's musl, not the build host's — under the engine an
          # i686 target counts as native (x86_64 canExecute i686), so buildPlatform
          # (x86_64) headers would give the 32-bit compile the wrong struct layouts
          # and segfault miniperl. hostPlatform.system ("i686-linux") is x86_64-
          # runnable, so its real 32-bit musl builds here; for x86_64 host==build.
          engineIncFix =
            if crossCompiling || isDarwin then [ ]
            else
              let musl = (import pkgs.path { inherit (sp.stdenv.hostPlatform) system; })
                .pkgsStatic.stdenv.cc.libc;
              in [ "-Dlocincpth=${sp.lib.getDev musl}/include" ];

          # Shared engine-perl plumbing (nix-lib): the `llvm` multitool
          # (referenced at eval time via unpinToolchain — one build-host toolchain
          # cross-emits every target, so buildPlatform not host), the bitcode-
          # lowering introspection helper perl-cross's readelf/objdump probes need,
          # and the VFS IR-rewrite shell fns (vfsSed & co). All of it lives in
          # nix-lib so the fix-prone vfsSed has ONE home shared with unpins/biber.
          ep = ulib.enginePerl {
            inherit pkgs;
            introspectName = "unpin-perl-cross-bc-introspect";
          };

          # darwin-x86_64 is the aarch64-darwin -> x86_64 cross. The engine's
          # whole-program LTO link codegen miscompiles perl's SV/magic engine in
          # THIS cross only (native x86_64 and the i686 cross run `use warnings`
          # fine): the shipped binary panics `magic_killbackrefs` the instant a
          # module pulls weak refs (any `use warnings`). -Accflags=-fno-strict-
          # aliasing doesn't cure it (kept anyway) -- it is the LTO LINK codegen.
          # We can't just drop -flto (the VFS binds by rewriting perl's IR, which
          # needs bitcode objects). So keep -flto for COMPILE (bitcode -> vfsSed
          # works), then codegen each rewritten object to native per-TU with
          # `clang -O2 -fno-lto` BEFORE the final link, so the link pulls ordinary
          # objects and does no whole-program LTO. Isolation: if this fixes the
          # panic it WAS the LTO link codegen; if it still panics it's the per-TU
          # cross backend. Gated to the darwin cross; native/linux untouched.
          delto = crossCompiling && isDarwin;
          delToFns = sp.lib.optionalString delto ''
            # bitcode object -> native, per-TU, engine clang, no whole-program LTO.
            codegen_native() {
              local t; t=$($MT opt -S "$1" -o - 2>/dev/null \
                | sed -n 's/^target triple = "\(.*\)"/\1/p' | head -1)
              [ -n "$t" ] || return 0
              $MT clang -target "$t" -O0 -fno-lto -x ir -c "$1" -o "$1.n" && mv "$1.n" "$1"
            }
          '';

          # runtime @INC (*exp) -> /zip/share/perl5 ; install dest -> share/perl5
          zipConfigOver = ''

            cat >> config.over <<'EOF'
            for __v in privlibexp sitelibexp vendorlibexp archlibexp sitearchexp vendorarchexp; do
                eval "__cur=\$$__v"
                __suf=''${__cur#*/lib/perl5}
                eval "$__v=/zip/share/perl5$__suf"
            done
            for __v in privlib sitelib vendorlib archlib sitearch vendorarch \
                       installprivlib installsitelib installvendorlib \
                       installarchlib installsitearch installvendorarch; do
                eval "__cur=\$$__v"
                __cur=$(echo "$__cur" | sed 's|lib/perl5|share/perl5|g')
                eval "$__v=\$__cur"
            done
            unset __v __cur __suf
            EOF
          '';

          # perl-cross equivalent of zipConfigOver: config.over is ignored by
          # perl-cross, so apply the same @INC (*exp -> /zip) and install-tree
          # (lib/perl5 -> share/perl5) transforms directly to the generated
          # config.sh, then regenerate config.h + Makefile.config from it.
          zipConfigCross = ''
            ${pkgs.buildPackages.perl}/bin/perl ${./src/cross_config.pl} config.sh
            # perl-cross skips staging static-XS .pm (List::Util/File::Spec/...);
            # patch the Makefile's static rule to also run pm_to_blib.
            ${pkgs.buildPackages.perl}/bin/perl ${./src/cross_static_pm.pl} Makefile
            rm -f config.h
            CONFIG_H=config.h CONFIG_SH=config.sh ./config_h.SH >/dev/null 2>&1
            make Makefile.config >/dev/null 2>&1
          '';

          remapPostInstall = postInstall:
            let r = builtins.replaceStrings [ "lib/perl5" ] [ "share/perl5" ] postInstall;
            in builtins.replaceStrings
              [ ''rm "$out"/share/perl5/*/*/.packlist'' ]
              [ ''find "$out"/share/perl5 -name .packlist -delete'' ] r;

          # Strip every /nix/store path out of Config_heavy.pl/Config.pm (the
          # only files that leak them; the binary is already clean). Runs in
          # build A so the embedded payload carries zero nix references.
          scrubNix = ''
            find "$out"/share/perl5 -name 'Config_heavy.pl' -o -name 'Config.pm' | while read -r f; do
              sed -i -E "s#/nix/store/[a-z0-9]{32}-[^ '\":]*#/unpin#g" "$f"
            done
          '';

          # Runs at every startup (perl built -Dusesitecustomize does
          # `do "$sitelibexp/sitecustomize.pl"`, $sitelibexp=/zip -> served by the
          # VFS). Prepends a per-user cache dir to @INC and points module installs
          # there, all runtime-computed so no path is baked. Pure-Perl only.
          siteCustomizePl = pkgs.writeText "sitecustomize.pl" ''
            {
                my $c = $ENV{XDG_CACHE_HOME};
                $c ||= "$ENV{HOME}/.cache" if $ENV{HOME};
                if ($c) {
                    my $base = "$c/unpin/perl5";
                    unshift @INC, "$base/lib/perl5";
                    $ENV{PERL_MM_OPT} = "INSTALL_BASE=$base" unless defined $ENV{PERL_MM_OPT};
                    $ENV{PERL_MB_OPT} = "--install_base $base" unless defined $ENV{PERL_MB_OPT};
                }
            }
            1;
          '';

          installSiteCustomize = ''
            __ver=$(ls "$out"/share/perl5 | grep -E '^[0-9]' | head -1)
            mkdir -p "$out/share/perl5/site_perl/$__ver"
            cp ${siteCustomizePl} "$out/share/perl5/site_perl/$__ver/sitecustomize.pl"
          '';

          mkPerl = { nixLdflags ? null, buildPhase ? null, extraPostInstall ? "" }:
            sp.perl.overrideAttrs (old:
            let
              # nixpkgs' interpreter.nix bakes an absolute `${coreutils}/bin/pwd`
              # into Cwd.pm on EVERY cross (its crossCompiling postPatch branch);
              # the native branch uses `$(type -P pwd)` and pulls nothing. The
              # interpolated store path is an eval-time string-context edge, so it
              # makes coreutils — and thus gmp — a BUILD INPUT of perl on every
              # cross. On the darwin (aarch64->x86_64) cross that gmp is built by the
              # engine, whose ld64.lld rejects gmp's x86_64 hand-asm ("BRANCH
              # relocation has width 1 bytes, must be 4"), failing the build.
              # Rewrite the base postPatch to the native `$(type -P pwd)` form
              # (resolved at build time). replaceStrings drops the text but NOT the
              # string context, so the coreutils input edge would survive; coreutils
              # is verified to be the SOLE context element of the cross postPatch
              # (native postPatch has none), so discard the now-spurious context to
              # actually cut the edge. The postPatch additions concatenated after
              # this keep their own context intact. Native path unchanged -> byte-id.
              crossBasePostPatch =
                let b = old.postPatch or ""; in
                if crossCompiling
                then builtins.unsafeDiscardStringContext (builtins.replaceStrings
                  [ "'${sp.coreutils}/bin/pwd'" ] [ ''"$(type -P pwd)"'' ] b)
                else b;
            in
            {
              # On a case-insensitive FS (macOS) perl-cross's `configure` clobbers
              # perl's `Configure` during the cross overlay, so nixpkgs'
              # no-sys-dirs.patch (which patches Configure) can't apply. The cross
              # build uses perl-cross's own configure, so that patch is moot there
              # -- drop it for the darwin cross. Linux crosses keep it (it applies
              # and is harmless).
              patches = (
                let base = old.patches or [ ];
                in if crossCompiling && isDarwin
                then builtins.filter
                  (p: !(sp.lib.hasInfix "no-sys-dirs" (toString p))) base
                else base
              ) ++ perlPatches;
              configureFlags = (old.configureFlags or [ ]) ++ [ "-Dusesitecustomize" ]
                # perl's native Configure scans $libpth for the libc archive to
                # nm-extract symbols from; nixpkgs derives that dir from
                # stdenv.cc.libc, which is null under the unpin-llvm engine (musl
                # is served from clang's own on-demand sysroot, not a store
                # libpth), so the scan finds nothing and Configure loops forever on
                # "Where is your C library?". -Dusenm=false sets runnm=false, which
                # skips that whole block (Configure detects libc symbols by
                # compile-test instead — the documented fallback when nm can't be
                # used, and correct here since the cc-wrapper links libc fine). The
                # cross builds use perl-cross, which never runs this scan.
                ++ sp.lib.optional (!crossCompiling) "-Dusenm=false"
                # Same root cause, broader symptom: Configure builds its header
                # search path (incpth) from the dirs the compiler reports for
                # `#include <>`, then probes header PRESENCE with `test -f`. The
                # engine cc reports its musl headers under the virtual clang-VFS
                # sysroot /__unpin_ziglib__/libc/include, which are not real files,
                # so EVERY musl header comes back absent (<pthread.h>, <dirent.h>,
                # …) and perl is mis-configured or dies ("unknown type name
                # 'perl_mutex'", unknown directory-entry type). The engine's musl
                # headers can't be pointed at (they live inside the clang binary),
                # so hand Configure a real musl of the same 1.2.x ABI to detect
                # against — exactly what nixpkgs' own perl expr does via
                # stdenv.cc.libc (null under the engine). Linux native only; darwin
                # detects against its SDK, the cross builds use perl-cross.
                ++ engineIncFix
                # perl leans hard on type-punning through its SV/magic unions, so it
                # MUST compile with -fno-strict-aliasing (and -fwrapv for its signed-
                # overflow assumptions). On Linux perl's Configure injects these from
                # gccversion; under the engine on darwin that detection misfires and
                # the darwin hints force a bare -O3, so miniperl miscompiles and dies
                # `panic: magic_killbackrefs` the moment it loads a module with weak
                # refs (warnings.pm). Append them explicitly for the darwin engine.
                ++ sp.lib.optionals isDarwin [
                  "-Dranlib=${prefix}ranlib"
                  "-Accflags=-fno-strict-aliasing"
                  "-Accflags=-fwrapv"
                ];
              # macOS: installperl gates install_name_tool on `&& useshrplib`, but
              # the value is the string 'false' (truthy in perl) so it runs on the
              # static build and dies (EACCES on the read-only binary; there is no
              # libperl.dylib regardless). Require eq 'true' so it's skipped.
              postPatch = crossBasePostPatch + (if isDarwin then ''
                substituteInPlace installperl \
                  --replace-fail '&& $Config{useshrplib}' '&& $Config{useshrplib} eq "true"'
              '' else "")
              # perl-cross assumes an ELF build host (readelf/objdump); on a
              # darwin build host (the darwin<->darwin cross) those tools are
              # absent and useless on Mach-O, so rewrite the two probes that
              # need them to compile-only, cross-safe equivalents.
              + sp.lib.optionalString (crossCompiling && isDarwin) ''
                ${pkgs.buildPackages.perl}/bin/perl ${./src/cross_darwin.pl}
              ''
              # The engine's clang preprocessor emits musl headers under the
              # virtual clang-VFS sysroot /__unpin_ziglib__/… (not real files).
              # perl's makedepend would record those as Makefile prerequisites and
              # make then dies ("No rule to make target /__unpin_ziglib__/.../
              # alloca.h"). Drop them in the same makedepend_file sed that already
              # filters the <built-in>/<command-line> line markers — dependency
              # tracking is irrelevant to a one-shot build. Engine analogue of the
              # binutils --disable-dependency-tracking fix. Native only (the cross
              # builds use perl-cross, which doesn't run makedepend_file).
              + sp.lib.optionalString (!crossCompiling) ''
                substituteInPlace makedepend_file.SH --replace-fail \
                  ${sp.lib.escapeShellArg "-e '/^#.*<built-in>/d' \\"} \
                  ${sp.lib.escapeShellArg "-e '/^#.*<built-in>/d' -e '\\#/__unpin_ziglib__#d' \\"}
              ''
              # Errno.pm's generator scans the target's errno.h AS A FILE (via
              # $sysroot/usr/include + locincpth) to harvest the E* macro NAMES,
              # then reads their VALUES by preprocessing `#include <errno.h>`. Under
              # the engine the musl headers are virtual (inside clang), so the file
              # scan finds nothing → "No error definitions found". The value step
              # already works (the engine cc resolves <errno.h>), so only the name
              # harvest needs fixing: short-circuit get_files to a stub TU the engine
              # cc expands (`clang -E -dM` over `#include <errno.h>` lists every E*).
              # Cross only; the native build finds errno.h via engineIncFix's locincpth.
              + sp.lib.optionalString (crossCompiling && !isDarwin) ''
                substituteInPlace ext/Errno/Errno_pm.PL --replace-fail \
                  'sub get_files {' \
                  'sub get_files { if (open(my $s, ">", "unpin_errno.c")) { print $s "#include <errno.h>\n"; close $s; return ("unpin_errno.c"); }'
              '';
              # perl-cross's configure probes the ELF build host for readelf/objdump,
              # but the engine toolchain ships only the `llvm` multitool (no prefixed
              # readelf/objdump), so the probe dies ("Cannot find readelf"). Point
              # perl-cross's READELF/OBJDUMP env knobs at `llvm readelf`/`llvm objdump`
              # (GNU-compatible), locating the multitool the same way build-B does.
              # Linux cross only (the darwin cross rewrites these probes via
              # cross_darwin.pl above; native/i686 use perl's own Configure).
              preConfigure = (old.preConfigure or "")
                + sp.lib.optionalString (crossCompiling && !isDarwin) ''
                  export READELF="${ep.bcIntrospect} readelf"
                  export OBJDUMP="${ep.bcIntrospect} objdump"
                ''
                # The -Accflags=-fno-strict-aliasing above reaches only the TARGET
                # perl's ccflags. perl-cross builds the build-time miniperl in a
                # separate `configure --mode=buildmini` respawn that inherits neither
                # -Accflags nor CFLAGS -- it takes its ccflags from $HOSTCFLAGS
                # (empty by default). So on the darwin cross the miniperl compiles
                # under the engine clang WITHOUT -fno-strict-aliasing: the same
                # SV/magic strict-aliasing miscompile that -Accflags cures for the
                # target hits miniperl instead, and it segfaults intermittently once
                # it loads a module (make_patchnum.pl -> git_version.h). Native
                # dodges this because there miniperl and target share one compiler,
                # so -Accflags covers both; the Linux crosses dodge it because the
                # miscompile is darwin-specific. Feed the same flags via HOSTCFLAGS.
                + sp.lib.optionalString (crossCompiling && isDarwin) ''
                  export HOSTCFLAGS="-fno-strict-aliasing -fwrapv"
                ''
                + zipConfigOver;
              postConfigure = (old.postConfigure or "")
                + sp.lib.optionalString crossCompiling zipConfigCross;
              postInstall = remapPostInstall (old.postInstall or "")
                + scrubNix + installSiteCustomize + extraPostInstall;
            }
            // sp.lib.optionalAttrs (nixLdflags != null) {
              NIX_LDFLAGS = nixLdflags;
              # Keep the embedded VFS dormant for all build-time perls (miniperl,
              # Configure probes, installperl); only the installed binary runs live.
              UNPIN_VFS_OFF = "1";
            }
            // sp.lib.optionalAttrs (buildPhase != null) { inherit buildPhase; });

          # ---- A: harvest build (no wrap, no VFS) ----
          treePerl = mkPerl { };

          dispatchSrc = ./src/dispatch.c;

          # Runtime stage for withUnpinEmbed: the harvested @INC tree
          # (share/perl5, incl. the runtime sitecustomize.pl) + the applet
          # scripts (bin/<name>, shebang scrubbed to /zip/bin/perl so no /nix
          # path leaks), minus the dev/compile + perldoc files (.a/.h/.ld/.pod,
          # CORE/). The nix-lib embed packs it into the binary's single EOF ZIP
          # (runtime entries zstd method 93 against the shared ".unpin/zdict"
          # dict it trains). The VFS strips the "/zip/" mount prefix on lookup,
          # so ZIP keys are "share/perl5/..." and "bin/<name>", read back by the
          # shared unpin-vfs core in self-EOF mode (-DUNPIN_VFS_SELF).
          incStage = ''
            mkdir -p "$__unpin_stage/share" "$__unpin_stage/bin"
            cp -rL ${treePerl}/share/perl5 "$__unpin_stage/share/perl5"
            chmod -R u+w "$__unpin_stage"
            find "$__unpin_stage" -type f \( -name '*.a' -o -name '*.h' -o -name '*.ld' \
              -o -name '*.pod' -o -path '*/CORE/*' \) -delete
            for __a in ${sp.lib.escapeShellArgs applets}; do
              sed '1s|^#!.*|#!/zip/bin/perl|' "${treePerl}/bin/$__a" > "$__unpin_stage/bin/$__a"
            done
            # Scrub any residual /nix store path out of every staged text file
            # (treePerl already scrubs Config): the STORED shared dict is trained
            # on this payload and would otherwise bake store-path hashes verbatim,
            # making nix retain them as spurious references. No-op when clean.
            grep -rlI '/nix/store/' "$__unpin_stage" 2>/dev/null | while read -r f; do
              sed -i -E "s#/nix/store/[a-z0-9]{32}-[^ '\":]*#/unpin#g" "$f"
            done
          '';

          # Compile the helper objects from basename sources (copied into the
          # build cwd, `-I.`), NOT from `-c ${./src/x.c}` absolute store paths.
          # clang records the compiled source path in the object's debug/STABS
          # info; with a `/nix/store/…-x.c` arg that bakes a store hash into the
          # object, which the final binary then retains as a spurious reference.
          # On Linux the binary is stripped (ref gone), but on darwin the embed
          # appends the runtime ZIP past `__LINKEDIT`, so `strip` refuses to run
          # post-embed and the debug source path — hence the store ref — survives
          # (miniz.c leaked this way). A bare basename records just `miniz.c`, no
          # store path, so both OSes stay at zero external refs.
          vfsObj = sp.stdenv.mkDerivation {
            name = "perl-vfs-o";
            dontUnpack = true;
            buildPhase = ''
              cp ${./src}/*.c ${./src}/*.h .
              # -DUNPIN_VFS_NOWRAP: define the shims as unpinvfs_open/stat/lstat/
              # access (not __wrap_*). Under the engine every object is bitcode, so
              # the VFS is bound by IR-renaming perl's open/stat/... references to
              # these names (see the build-B buildPhase), not by `ld --wrap`. The
              # 32-bit-musl _REDIR_TIME64 stat/lstat rename is handled by that same
              # IR sed, so no -DUNPIN_WRAP_TIME64 here.
              $CC -O2 -DMINIZ_USE_ZSTD -DUNPIN_VFS_SELF -DUNPIN_VFS_NOWRAP -I. -c vfs.c -o vfs.o
              $CC -O2 -DMINIZ_USE_ZSTD -I. -c miniz.c -o miniz.o
              $CC -O2 -DMINIZ_USE_ZSTD -DUNPIN_ZSTD_VENDORED -I. -c unpin_zstd.c -o unpin_zstd.o
            '';
            installPhase = ''mkdir -p $out; cp vfs.o miniz.o unpin_zstd.o $out/'';
          };

          dispatchObj = sp.stdenv.mkDerivation {
            name = "perl-dispatch-o";
            dontUnpack = true;
            buildPhase = ''
              cp ${dispatchSrc} dispatch.c
              # -DUNPIN_DISPATCH_NOWRAP: supply plain main() (calls real_main).
              # The engine renames perlmain's main -> real_main in the IR.
              $CC -O2 -DUNPIN_DISPATCH_NOWRAP -c dispatch.c -o dispatch.o
            '';
            installPhase = ''mkdir -p $out; cp dispatch.o $out/'';
          };

          # ---- B: embedded build (unpin-llvm engine, bitcode) ----
          # The engine compiles every object to LLVM bitcode and LTO-links the
          # shipped binary — that IS the whole-program size/opt win, uniformly with
          # binutils/curl/nmap/tcc and with no per-package -flto. Because everything
          # is bitcode, neither `ld --wrap` (a mega fold can't carry a per-package
          # wrap) nor `objcopy --redefine-sym` (can't edit a bitcode symtab) can
          # bind the VFS. So we bind it the tcc way: rewrite perl's open/stat/lstat/
          # access references and perlmain's main IN THE IR (opt -S | sed | opt) to
          # the unpinvfs_* shims / real_main, then LTO-link with vfs.o (which
          # DEFINES unpinvfs_* under -DUNPIN_VFS_NOWRAP) and dispatch.o (which
          # supplies main). ONE path for Linux and darwin, replacing the old
          # --wrap (Linux) + --redefine-sym-on-consolidated-object (darwin) split.
          #
          # vfs.o/miniz.o/unpin_zstd.o ride NIX_LDFLAGS (harmless for the build-time
          # perls: the VFS is dormant under UNPIN_VFS_OFF and unpinvfs_* passes real
          # paths straight through to libc). The IR rewrite touches only the FINAL
          # libperl.a + perlmain.o, so miniperl — run during the build to read real
          # files — is unaffected.
          enginePerl = mkPerl {
            nixLdflags = "${vfsObj}/vfs.o ${vfsObj}/miniz.o ${vfsObj}/unpin_zstd.o";
            buildPhase = ''
              runHook preBuild
              J=-j$NIX_BUILD_CORES

              # The engine LLVM multitool (`llvm opt`, `llvm ar`), referenced at
              # eval time (nix-lib unpinToolchain) so it resolves identically on the
              # native and the cross builds.
              MT=${ep.multitool}

              # isbc + vfsSed + bcrewrite (the IR VFS-rewrite core, incl. the
              # arch-specific darwin stat/lstat rules) — shared from nix-lib.
              ${ep.vfsShellFns}
              ${delToFns}

              make $J libperl.a
              # Rewrite every bitcode member of libperl.a (any native member passes
              # through untouched), then repack with the bitcode-aware llvm ar so
              # the LTO link resolves the members from the archive index.
              rm -rf .vfsm && mkdir .vfsm
              ( cd .vfsm && $MT ar x ../libperl.a )
              for o in .vfsm/*; do
                [ -f "$o" ] || continue
                isbc "$o" && bcrewrite "$o"
                ${sp.lib.optionalString delto ''isbc "$o" && codegen_native "$o"''}
              done
              rm -f libperl.a && $MT ar rcs libperl.a .vfsm/*

              # Full build first (perl links with its own main), so extensions like
              # Time::HiRes compile exactly as upstream -- splitting the build with
              # `make perlmain.o` mid-way breaks HiRes's clockid_t probe.
              make $J
              # Rename perlmain's main -> real_main in the IR, then relink just perl
              # with dispatch.o (which supplies main). dispatch.o is pulled only by
              # this FINAL link, never by miniperl (which keeps its own main).
              if isbc perlmain.o; then
                $MT opt -S perlmain.o -o perlmain.ll
                sed -i -e 's/@main\b/@real_main/g' perlmain.ll
                $MT opt perlmain.ll -o perlmain.o
                rm -f perlmain.ll
              fi
              ${sp.lib.optionalString delto ''isbc perlmain.o && codegen_native perlmain.o''}
              export NIX_LDFLAGS="$NIX_LDFLAGS ${dispatchObj}/dispatch.o"
              make $J perl
              runHook postBuild
            '';
            extraPostInstall = dropAndAlias + sp.lib.optionalString isDarwin ''
              # diag(split): stash the generated config so the cross (arm64-host
              # perl-cross) output can be diffed against the x86_64-native Configure
              # output (isolates a config/table host-taint from a pure codegen bug).
              # Dumped on BOTH darwin builds so the native run gives the baseline.
              # Remove with the diag branch.
              mkdir -p "$out/share/perl-diag"
              cp config.sh config.h "$out/share/perl-diag/" 2>/dev/null || true
            '';
          };

          # The @INC tree + applet scripts are embedded; ship none on disk. Drop
          # the /nix-shebanged standalone scripts and expose the applets as
          # symlinks to perl (dispatch.o keys on argv[0]); withAliases harvests
          # them into UNPIN_META.
          dropAndAlias = ''
            rm -rf "$out/share/perl5"
            find "$out/bin" -maxdepth 1 -type f ! -name 'perl' ! -name 'perl5.*' -delete
            for __a in ${sp.lib.escapeShellArgs applets}; do
              ln -sf perl "$out/bin/$__a"
            done
          '';

          vfsPerl = enginePerl.overrideAttrs (_: {
            pname = "perl";
            meta = (sp.perl.meta or { }) // { mainProgram = "perl"; };
          });
        in
        # The PRISTINE VFS perl base (no embed) + the @INC runtime stage. The
        # embed runs once, post-build, via mkStandaloneFlake's runtimeEmbed →
        # unpinEmbedWrap (the single embed path): the @INC runtime tree
        # (self-EOF VFS), the applet alias harvest (auto from the bin/ symlinks
        # dropAndAlias leaves), and the man pages (man = true harvests the base's
        # own share/man).
        { base = vfsPerl; inherit incStage; };
      winMod = import ./windows.nix { inherit ulib applets appletsCsv; };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "perl";
      # Build via the unpin-llvm engine: pkgsStatic is swapped to the engine
      # stdenv, so every object (perl + its whole link closure) compiles to LLVM
      # bitcode and the shipped binary is LTO-linked — whole-program optimisation
      # for the single interpreter, the same toolchain binutils/curl/nmap/tcc use.
      # The /zip @INC embed is unchanged (runtimeEmbed self-EOF); the VFS is bound
      # by IR symbol rewriting in `mk`'s build-B (bitcode has no `--wrap`). No
      # `multicall` — perl does its own argv[0] dispatch (src/dispatch.c) and is
      # too large to fold into the unpinbox mega, so it needs no bitcode module.
      engine = "unpin-llvm";
      embedMan = true;
      # `-Mstrict` forces `require strict` -> a /zip @INC module load through the
      # VFS stat/open shims, the exact path that leaked to libc on arm64-darwin
      # (vfsSed's missing plain `_stat`/`_lstat`). `--version` never loads a
      # module, so it left that bug latent; keep the module load in the smoke.
      smoke = [ "-Mstrict" "-e" "print q{perl VFS smoke ok}" ];
      smokePattern = "perl VFS smoke ok";
      build = pkgs: (mk pkgs).base;
      # Windows is mingw-NATIVE (not cosmo): nixpkgs' perl-cross cross only goes
      # part-way, so windows.nix runs winfix.sh (postConfigure) to make it a real
      # win32 target, then relinks with the four win32_* wraps + main wrap (self-EOF VFS).
      windowsBuild = pkgs: (winMod pkgs).base;
      runtimeEmbed = {
        native = pkgs: base: { man = true; runtimeStage = (mk pkgs).incStage; };
        windows = pkgs: base: (winMod pkgs).embed;
      };
    };
}

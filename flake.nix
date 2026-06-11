{
  description = "Standalone build of perl";

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
  #     host FS. Linux does this with `-Wl,--wrap`; macOS, which has no `--wrap`,
  #     reaches the same effect by renaming the symbols in libperl.a with
  #     `llvm-objcopy --redefine-sym`.
  #
  # Multicall: the 16 pure-Perl utilities that run cleanly in a static, no-XS
  # binary (cpan, json_pp, shasum, prove, pod2*, ptar*, …) are embedded as
  # `/zip/bin/<name>` scripts and dispatched by argv[0] — `main` is intercepted
  # (ELF `--wrap=main`; Mach-O `--redefine-sym _main`) so invoking the binary as
  # `json_pp` runs the embedded script. `withAliases` harvests the names so
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
          # 32-bit musl is _REDIR_TIME64: stat/lstat are renamed to
          # __stat_time64/__lstat_time64 in the headers, so the VFS must wrap those
          # symbols too (see src/vfs.c). Linux-only; darwin targets are 64-bit.
          wrap32 = (host.parsed.cpu.bits or 64) == 32;
          prefix = sp.stdenv.cc.targetPrefix;

          perlPatches = [ ./patches/ext-re-static-aux.patch ];
          libxcryptPatch = ./patches/libxcrypt-symbols-static-lto.patch;

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
            sp.perl.overrideAttrs (old: {
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
                ++ (if isDarwin then [ "-Dranlib=${prefix}ranlib" ] else [ ]);
              # macOS: installperl gates install_name_tool on `&& useshrplib`, but
              # the value is the string 'false' (truthy in perl) so it runs on the
              # static build and dies (EACCES on the read-only binary; there is no
              # libperl.dylib regardless). Require eq 'true' so it's skipped.
              postPatch = (old.postPatch or "") + (if isDarwin then ''
                substituteInPlace installperl \
                  --replace-fail '&& $Config{useshrplib}' '&& $Config{useshrplib} eq "true"'
              '' else "")
              # perl-cross assumes an ELF build host (readelf/objdump); on a
              # darwin build host (the darwin<->darwin cross) those tools are
              # absent and useless on Mach-O, so rewrite the two probes that
              # need them to compile-only, cross-safe equivalents.
              + sp.lib.optionalString (crossCompiling && isDarwin) ''
                ${pkgs.buildPackages.perl}/bin/perl ${./src/cross_darwin.pl}
              '';
              preConfigure = (old.preConfigure or "") + zipConfigOver;
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
            // sp.lib.optionalAttrs (buildPhase != null) { inherit buildPhase; }
            // sp.lib.optionalAttrs (!isDarwin) {
              # libxcrypt needs a static-LTO symbol patch on Linux; darwin's crypt
              # comes from libSystem.
              propagatedBuildInputs = map
                (dep:
                  if (dep.pname or "") == "libxcrypt"
                  then dep.overrideAttrs (oa: { patches = (oa.patches or [ ]) ++ [ libxcryptPatch ]; })
                  else dep)
                (old.propagatedBuildInputs or [ ]);
            });

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

          vfsObj = sp.stdenv.mkDerivation {
            name = "perl-vfs-o";
            dontUnpack = true;
            buildPhase = ''
              $CC -O2 -DMINIZ_USE_ZSTD -DUNPIN_VFS_SELF ${sp.lib.optionalString wrap32 "-DUNPIN_WRAP_TIME64"} -I${./src} -c ${./src/vfs.c} -o vfs.o
              $CC -O2 -DMINIZ_USE_ZSTD -I${./src} -c ${./src/miniz.c} -o miniz.o
              $CC -O2 -DMINIZ_USE_ZSTD -DUNPIN_ZSTD_VENDORED -I${./src} -c ${./src/unpin_zstd.c} -o unpin_zstd.o
            '';
            installPhase = ''mkdir -p $out; cp vfs.o miniz.o unpin_zstd.o $out/'';
          };

          dispatchObj = sp.stdenv.mkDerivation {
            name = "perl-dispatch-o";
            dontUnpack = true;
            buildPhase = ''$CC -O2 -c ${dispatchSrc} -o dispatch.o'';
            installPhase = ''mkdir -p $out; cp dispatch.o $out/'';
          };

          objcopy = "${pkgs.buildPackages.llvm}/bin/llvm-objcopy";
          # x86_64-darwin carries the $INODE64 ABI suffix on stat/lstat (single-
          # quoted so bash doesn't eat the $); aarch64-darwin uses plain
          # _stat/_lstat. This list is therefore arch-specific.
          redefArgs = builtins.concatStringsSep " " [
            "--redefine-sym _open=_unpinvfs_open"
            "--redefine-sym '_stat$INODE64=_unpinvfs_stat'"
            "--redefine-sym '_lstat$INODE64=_unpinvfs_lstat'"
            "--redefine-sym _access=_unpinvfs_access"
          ];

          # ---- B: embedded build ----
          # Linux: -Wl,--wrap routes open/stat/… and main through our objects, all
          # passed via NIX_LDFLAGS on every link (harmless for build-time perls;
          # the env gate keeps the VFS dormant there). No blob object: the @INC
          # ZIP is appended to the installed binary's EOF by withUnpinEmbed and
          # read back by the VFS's self-EOF mode.
          linuxVfs = mkPerl {
            nixLdflags = "--wrap=open --wrap=stat --wrap=lstat --wrap=access --wrap=main "
              + sp.lib.optionalString wrap32 "--wrap=__stat_time64 --wrap=__lstat_time64 "
              + "${vfsObj}/vfs.o ${vfsObj}/miniz.o ${vfsObj}/unpin_zstd.o ${dispatchObj}/dispatch.o";
            extraPostInstall = dropAndAlias;
          };
          # macOS: no --wrap. Rewrite libperl.a's open/stat symbols by hand, and
          # for the multicall rename perlmain.o's _main -> _real_main so dispatch.o
          # (linked only into the FINAL perl, never miniperl) supplies _main.
          darwinVfs = mkPerl {
            nixLdflags = "${vfsObj}/vfs.o ${vfsObj}/miniz.o ${vfsObj}/unpin_zstd.o";
            buildPhase = ''
              runHook preBuild
              make -j$NIX_BUILD_CORES libperl.a
              ${objcopy} ${redefArgs} libperl.a
              # Full build first (perl links with its own _main), so extensions
              # like Time::HiRes compile exactly as upstream -- splitting the
              # build with `make perlmain.o` mid-way breaks HiRes's clockid_t
              # probe. Then rename perlmain.o's _main and relink just perl with
              # dispatch.o supplying _main.
              make -j$NIX_BUILD_CORES
              ${objcopy} --redefine-sym _main=_real_main perlmain.o
              export NIX_LDFLAGS="$NIX_LDFLAGS ${dispatchObj}/dispatch.o"
              make -j$NIX_BUILD_CORES perl
              runHook postBuild
            '';
            extraPostInstall = dropAndAlias;
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

          vfsPerl = (if isDarwin then darwinVfs else linuxVfs).overrideAttrs (_: {
            pname = "perl";
            meta = (sp.perl.meta or { }) // { mainProgram = "perl"; };
          });
        in
        # ONE withUnpinEmbed call builds the whole embedded container in a
        # single pack: the @INC runtime tree (self-EOF VFS), the applet alias
        # harvest, and the man pages (man = true harvests the drv's own
        # share/man — exactly what mkStandaloneFlake's embedMan did; the
        # passthru flag makes it skip its own withMan pass).
        ulib.withUnpinEmbed pkgs {
          primary = "perl";
          aliasesFromSymlinksIn = "bin";
          man = true;
          runtimeStage = incStage;
        } vfsPerl;
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "perl";
      embedMan = true;
      smoke = [ "--version" ];
      smokePattern = "This is perl 5";
      build = pkgs: mk pkgs;
      # Windows is mingw-NATIVE (not cosmo): nixpkgs' perl-cross cross only goes
      # part-way, so windows.nix runs winfix.sh (postConfigure) to make it a real
      # win32 target, then relinks with the four win32_* wraps + main wrap (self-EOF VFS).
      windowsBuild = import ./windows.nix { inherit ulib applets appletsCsv; };
    };
}

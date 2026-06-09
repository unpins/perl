# Windows (mingw-NATIVE) standalone perl: the same single-binary embedded-@INC
# design as Linux/darwin, but cross-compiled to x86_64-w64-mingw32. Windows has
# no memfd, so the VFS materialises each /zip blob entry to a temp file and
# delegates to perl's real win32_{open,stat,lstat,access} (intercepted with mingw
# `ld --wrap`). The interpreter is a real win32-native perl: nixpkgs' perl-cross
# cross only goes part-way, so `winfix.sh` (postConfigure) overlays the win32
# OS/ABI config and wires the win32 host layer (win32/*.c) into libperl.
#
# Pipeline mirrors the native `mk`: A (treePerl) installs lib/perl5 with @INC
# pinned to /zip and Config scrubbed of /nix; the blob packs that tree + the
# applet scripts + sitecustomize.pl; B (vfsPerl) relinks the same perl with the
# four win32 wraps + main wrap + blob via NIX_LDFLAGS, dropping lib/perl5 on disk.
{ ulib, applets, appletsCsv }:
pkgs:
let
  lib = pkgs.lib;
  cross = pkgs.pkgsCross.mingwW64;
  prefix = cross.stdenv.cc.targetPrefix;          # x86_64-w64-mingw32-
  bperl = "${pkgs.buildPackages.perl}/bin/perl";  # native perl runs the wf_*.pl helpers
  winSrc = ./src/win;

  # static mcfgthreads (.a) — winfix points ldflags at this dir; the .exe folds
  # libmcfgthread instead of importing the DLL.
  mcfA = "${cross.windows.mcfgthreads}/lib";

  # ---- the win32-native perl base: drop the cross coreutils-mingw postPatch
  # (bakes a broken ${coreutils}/bin/pwd into Cwd.pm), apply the inc-macro VFS
  # patch, and run winfix after perl-cross configure.
  mkWinPerl = { buildPhase ? null, extraPostInstall ? "" }:
    cross.perl.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        ./patches/ext-re-static-aux.patch
        ./patches/perl-inc-macro-vfs-fixed-inc.patch
      ];
      # Replace the cross postPatch: keep the harmless cpp `-E -P`->`-E` fix, drop
      # the Cwd.pm /bin/pwd rewrite (Windows Cwd uses Win32 APIs; the rewrite only
      # dragged the failing coreutils-mingw build).
      postPatch = ''
        substituteInPlace cnf/configure_tool.sh --replace-fail "cc -E -P" "cc -E"
      '';
      postConfigure = (old.postConfigure or "") + ''
        echo "=== unpin winfix (win32-native + /zip @INC) ==="
        NPERL=${bperl} bash ${winSrc}/winfix.sh ${winSrc} ${mcfA}
        # nixpkgs' preConfigure rewrites this to use the dynamic system zlib
        # (-> a zlib1.dll import). Flip it back to the distribution default so
        # Compress::Raw::Zlib statically folds its bundled zlib-src instead,
        # keeping perl.exe a self-contained single binary (system DLLs only).
        sed -i -E 's#^BUILD_ZLIB.*#BUILD_ZLIB = True#; s#^(ZLIB_INCLUDE|ZLIB_LIB|INCLUDE|LIB)[[:space:]].*#\1 = ./zlib-src#' \
          ./cpan/Compress-Raw-Zlib/config.in
      '';
      postInstall = (old.postInstall or "") + scrubNix + extraPostInstall;
    } // lib.optionalAttrs (buildPhase != null) { inherit buildPhase; });

  # Strip /nix/store paths out of Config_heavy.pl/Config.pm before they reach the
  # blob (same regex as native). Runs in build A so the blob carries zero nix refs.
  scrubNix = ''
    find "$out"/lib/perl5 \( -name 'Config_heavy.pl' -o -name 'Config.pm' \) | while read -r f; do
      sed -i -E "s#/nix/store/[a-z0-9]{32}-[^ '\":]*#/unpin#g" "$f"
    done
  '';

  # ---- A: harvest build (installs lib/perl5; no blob, no wraps) ----
  treePerl = mkWinPerl { };

  # ---- blob: pack the @INC tree (<ver>/...) + applet scripts (bin/<x>, shebang
  # scrubbed to /zip/bin/perl so no /nix path leaks) + sitecustomize.pl
  # (<ver>/site_perl/...) into one `zip -9` archive. The VFS strips the "/zip/"
  # mount prefix on lookup, so archive keys are root-relative. Same proven ZIP
  # container as the Linux/darwin backends and the vim package. ----
  blobObj = cross.stdenv.mkDerivation {
    name = "perl-incblob-win";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.zip ];
    buildPhase = ''
      runHook preBuild
      # stage a writable copy of the @INC tree, the applet scripts, sitecustomize
      cp -r ${treePerl}/lib/perl5 stage
      chmod -R u+w stage
      __ver=$(ls stage | grep -E '^[0-9]' | head -1)
      mkdir -p stage/bin "stage/$__ver/site_perl"
      for a in ${lib.escapeShellArgs applets}; do
        sed '1s|^#!.*|#!/zip/bin/perl|' "${treePerl}/bin/$a" > "stage/bin/$a"
      done
      cp ${winSrc}/sitecustomize_win.pl "stage/$__ver/site_perl/sitecustomize.pl"
      find stage -type f \( -name '*.a' -o -name '*.h' -o -name '*.ld' \
        -o -name '*.pod' -o -path '*/CORE/*' \) -delete
      ( cd stage && zip -9 -X -r -q ../blob.bin . )
      [ -f blob.bin ] || mv blob.bin.zip blob.bin
      cp ${winSrc}/blob.S blob.S
      $CC -c blob.S -o incblob.o
      runHook postBuild
    '';
    installPhase = ''mkdir -p $out; cp incblob.o $out/'';
  };

  vfsObj = cross.stdenv.mkDerivation {
    name = "perl-vfs-win-o";
    dontUnpack = true;
    buildPhase = ''
      $CC -O2 -std=gnu17 -I${./src} -c ${./src/vfs.c} -o vfs.o
      $CC -O2 -std=gnu17 -I${./src} -c ${./src/miniz.c} -o miniz.o
    '';
    installPhase = ''mkdir -p $out; cp vfs.o miniz.o $out/'';
  };

  dispatchObj = cross.stdenv.mkDerivation {
    name = "perl-dispatch-win-o";
    dontUnpack = true;
    buildPhase = ''$CC -O2 -std=gnu17 -c ${winSrc}/dispatch_win.c -o dispatch.o'';
    installPhase = ''mkdir -p $out; cp dispatch.o $out/'';
  };

  # ---- B: embedded build. A normal `make` first (so XS link-lib probes and
  # ext.libs are generated cleanly — injecting our objects via NIX_LDFLAGS would
  # corrupt those probes and drop -lz/-lm). Then relink ONLY perl.exe with the
  # four win32 wraps + main wrap + our objects (vfs.o + miniz.o) + blob, reusing
  # the exact link the perl$x rule would run (captured with `make -n perl`, so
  # LDFLAGS/LIBS/static.list/ext.libs all match). __real_win32_* come from
  # libperl's win32 layer via --wrap. ----
  vfsPerl = (mkWinPerl {
    extraPostInstall = dropAndAlias;
    buildPhase = ''
      runHook preBuild
      make -j$NIX_BUILD_CORES
      echo "=== unpin VFS relink of perl.exe ==="
      rm -f perl perl.exe
      relink=$(make -n perl | grep -E -- '-o perl ' | tail -1)
      test -n "$relink" || { echo "could not capture perl link command"; exit 1; }
      WRAP="-Wl,--wrap=win32_open -Wl,--wrap=win32_stat -Wl,--wrap=win32_lstat -Wl,--wrap=win32_access -Wl,--wrap=main"
      OBJS="${vfsObj}/vfs.o ${vfsObj}/miniz.o ${dispatchObj}/dispatch.o ${blobObj}/incblob.o"
      relink="''${relink/-o perl /-o perl $WRAP $OBJS }"
      echo "RELINK: $relink"
      eval "$relink"
      test -f perl.exe || { echo "relink produced no perl.exe"; exit 1; }
      runHook postBuild
    '';
  }).overrideAttrs (_: {
    pname = "perl";
    meta = (cross.perl.meta or { }) // { mainProgram = "perl"; };
  });

  # The @INC tree + applet scripts are embedded; ship none on disk. Drop the
  # /nix-shebanged standalone bin scripts and expose the applets as transient
  # symlinks to perl.exe — withAliases harvests their names into UNPIN_META and
  # then deletes them (the unpin installer recreates the commands as .cmd wrappers
  # on the target). dispatch.o keys on argv[0], so each name runs its applet.
  dropAndAlias = ''
    rm -rf "$out/lib/perl5"
    find "$out/bin" -maxdepth 1 -type f ! -name 'perl.exe' ! -name 'perl5.*.exe' -delete
    for __a in ${lib.escapeShellArgs applets}; do
      ln -sf perl.exe "$out/bin/$__a"
    done
  '';
in
ulib.withAliases pkgs { primary = "perl"; aliasesFromSymlinksIn = "bin"; } vfsPerl

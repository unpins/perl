#!/usr/bin/env bash
# Turn a freshly-`configure`d perl-cross tree into a real win32-native target:
# overlay win32 OS/ABI capability vars, wire the win32 host layer (win32/*.c) into
# libperl, fix exe suffix / FILE accessors / Errno+HiRes osname, and pin @INC to
# /zip for the VFS. Run from the perl source root, after perl-cross configure.
#
# Usage: winfix.sh <wfdir> <mcfstatic-libdir>
#   $NPERL   native (build) perl to run the wf_*.pl helpers
#   <wfdir>  dir holding wf_overlay/stdio/flags/makefile/timehires/errno.pl
#   <mcfstatic-libdir>  dir with libmcfgthread.a (static mcfgthreads)
set -e
W="$(pwd)"
WFDIR="$1"
MCF="$2"
: "${NPERL:?NPERL (native perl) must be set}"
GCSRC="$W/win32/config.gc"

# 1) Overlay win32-canonical OS/ABI capability vars from config.gc onto config.sh.
"$NPERL" "$WFDIR/wf_overlay.pl" "$GCSRC" config.sh

# 2) Force win32 ABI int types (config_H.gc uses base C types, not stdint); set the
#    exe suffix (mingw auto-appends .exe to the suffix-less `perl$x` link target, so
#    installperl's `-x 'perl'.$exe_ext` and MakeMaker need '.exe'); enable
#    sitecustomize (perl `do`es $sitelibexp/sitecustomize.pl=/zip at startup -> the
#    VFS serves it, prepending a per-user cache dir to @INC for pure-Perl installs).
# Pass key/value through the environment and substitute via /e so slashes in the
# value (e.g. the /zip *exp paths) never collide with the s/// delimiter.
setv(){ local k="$1" v="$2"; if grep -q "^$k=" config.sh; then WF_K="$k" WF_V="$v" "$NPERL" -i -pe 's/^\Q$ENV{WF_K}\E=.*/"$ENV{WF_K}=$ENV{WF_V}"/e' config.sh; else echo "$k=$v" >> config.sh; fi; }
setv i32type long
setv u32type "'unsigned long'"
setv i16type short
setv u16type "'unsigned short'"
setv i8type char
setv u8type "'unsigned char'"
setv longdblsize 16
setv sizesize 8
setv _exe "'.exe'"
setv exe_ext "'.exe'"
setv usesitecustomize "'define'"

# 2b) Canonical win32 signal table from config.gc. perl-cross derives a SPARSE,
#     count-sized table for the mingw target (sig_size=7, sig_name='ZERO INT ILL
#     ABRT FPE SEGV TERM', sig_num='0 2 4 22 8 11 15'). But perl indexes
#     PL_psig_ptr by signal NUMBER while allocating it to SIG_SIZE slots, so a
#     read of $SIG{TERM} (15) or $SIG{ABRT} (22) runs off the 7-slot array into
#     heap garbage -> magic_getsig's sv_setsv hits a bogus SV ("Bizarre copy of
#     HASH/UNKNOWN", or an intermittent ~null deref crash, depending on what's in
#     the heap). Only INT(2)/ILL(4) stay in bounds, which is why it's flaky rather
#     than total. config.gc carries the DENSE, index-aligned table real Windows
#     perl ships (sig_size=27, covering ABRT=22/CONT=25), so copy it verbatim.
#     wf_overlay.pl skips sig_* on purpose (its allow-list is d_*/i_*/*format),
#     so set them explicitly here; config_h.SH (step 6) then bakes SIG_NAME/
#     SIG_NUM/SIG_SIZE into config.h and the build picks them up for Config too.
for k in sig_name sig_num sig_size sig_name_init sig_num_init; do
  v="$(sed -nE "s/^$k=(.*)\$/\1/p" "$GCSRC")"
  [ -n "$v" ] && setv "$k" "$v"
done

# 2a) Pin the runtime @INC (*exp) to the /zip VFS root. install* dirs stay real so
#     `make install` lands a harvestable tree (blob keys mirror /zip/<version>/...).
#     archname is the fixed win64 tag MSWin32-x64. Derive the version from config.sh.
PV=$("$NPERL" -ne 'print $1 if /^version=.(\d+\.\d+\.\d+).$/' config.sh)
: "${PV:?could not read perl version from config.sh}"
setv privlibexp     "'/zip/$PV'"
setv archlibexp     "'/zip/$PV/MSWin32-x64'"
setv sitelibexp     "'/zip/$PV/site_perl'"
setv sitearchexp    "'/zip/$PV/site_perl/MSWin32-x64'"

# 3) stdio FILE accessors -> safe PERLIO_FILE_* (matches official win32 config.h footer)
"$NPERL" "$WFDIR/wf_stdio.pl" config.sh

# 4) ccflags/ldflags/libs: win32 host-layer includes (absolute), static mcfgthread, win32 syslibs
"$NPERL" "$WFDIR/wf_flags.pl" config.sh "$W" "$MCF"

# 4a) VFS @INC fix: perl_inc_macro.h's `#if defined(WIN32)` ignores the literal
# PRIVLIB/SITELIB_EXP and calls PerlEnv_*_path (relocatable-to-exe); the patched
# header guards those on UNPIN_VFS_FIXED_INC so the literal /zip @INC is used.
# Appending the -D to ccflags (-> CFLAGS) makes `make` compile perl.o with it
# (only perl.c includes perl_inc_macro.h, so it's a no-op for every other object).
sed -i -E "s#^ccflags='([^']*)'#ccflags='\\1 -DUNPIN_VFS_FIXED_INC'#" config.sh

# 4b) perl-cross Makefile: add win32 host objs to TARGET libperl only (NOT src; that hits host miniperl)
"$NPERL" "$WFDIR/wf_makefile.pl" Makefile

# 4c) Time::HiRes: honor TARGET osname for the win32 (skip-probe) branch
"$NPERL" "$WFDIR/wf_timehires.pl" dist/Time-HiRes/Makefile.PL

# 4d) Errno: honor TARGET osname (use mingw errno.h, not host /usr/include)
"$NPERL" "$WFDIR/wf_errno.pl" ext/Errno/Errno_pm.PL

# 5) win32 host-layer: Win32iop.h case-insensitive symlink (Linux is case-sensitive)
ln -sf win32iop.h win32/Win32iop.h

# 6) regenerate config.h, xconfig.h, Makefile.config from fixed config.sh
rm -f config.h xconfig.h Makefile.config
CONFIG_H=config.h  CONFIG_SH=config.sh  ./config_h.SH  >/dev/null 2>&1
CONFIG_H=xconfig.h CONFIG_SH=xconfig.sh ./config_h.SH >/dev/null 2>&1
make Makefile.config >/dev/null 2>&1
echo "winfix applied. CFLAGS:"; grep '^CFLAGS' Makefile.config

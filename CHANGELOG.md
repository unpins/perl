# Changelog

## [Unreleased]

## [5.42.0-3] - 2026-09-26

### Changed

- The Windows binary is now built by the same compiler as the Linux and macOS
  ones. It is about 27% smaller (19.8 MB to 14.5 MB); `perl -v`, loading
  modules written in Perl and in C (JSON::PP, Digest::SHA, POSIX, Encode,
  Storable), reading and writing real files, the embedded library under `/zip`,
  and the bundled tools `json_pp`, `shasum`, `prove`, `corelist` and `ptar`
  were checked under Wine.

  It now uses the Universal C Runtime, which is part of Windows 10 and later.
  On Windows 7 or 8.1 that runtime has to be installed first — it comes through
  Windows Update. The previous binary did not need it.

### Fixed

- On 32-bit Linux (i686 and armv7l), perl used 32-bit integers, so integers
  past 2147483647 wrapped around: `printf "%d", 3000000000` printed
  -1294967296. Every released i686 and armv7l binary is affected. Those
  binaries now use 64-bit integers, like the other platforms.

- The Linux binaries for armv7l, riscv64 and ppc64le work again. Every build
  of them since the toolchain change crashed as soon as a module was loaded.
  No release shipped with this.

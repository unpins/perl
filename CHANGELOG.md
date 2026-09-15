# Changelog

## [Unreleased]

### Fixed

- On 32-bit Linux (i686 and armv7l), perl used 32-bit integers, so integers
  past 2147483647 wrapped around: `printf "%d", 3000000000` printed
  -1294967296. Every released i686 and armv7l binary is affected. Those
  binaries now use 64-bit integers, like the other platforms.

- The Linux binaries for armv7l, riscv64 and ppc64le work again. Every build
  of them since the toolchain change crashed as soon as a module was loaded.
  No release shipped with this.

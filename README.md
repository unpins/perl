# perl

Standalone build of [perl](https://www.perl.org/) — the interpreter and its entire standard library packaged as a single self-contained binary.

[![CI](https://github.com/unpins/perl/actions/workflows/perl.yml/badge.svg)](https://github.com/unpins/perl/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

A normal perl reads its modules from a separate `share/perl5` tree on disk. This build packs that whole tree *into the executable* — `File::Spec`, `Data::Dumper`, `CPAN`, the lot — and serves it from memory at runtime. One file, no companion data directory. It also bundles 16 of the utilities that ship with perl (`json_pp`, `shasum`, `prove`, `cpan`, `pod2man`, …), each reachable by name.

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Usage

```bash
perl -e 'print "hello\n"'              # the interpreter
perl script.pl                         # run a script
echo '{"b":2,"a":1}' | json_pp         # bundled utilities, by name
cpan Some::Module                      # installs into your user cache
```

To install it onto your PATH (creates `perl` plus the bundled command names):

```bash
unpin install perl
```

## Build locally

```bash
nix build github:unpins/perl
./result/bin/perl --version
```

Or run directly:

```bash
nix run github:unpins/perl -- -e 'print "hi\n"'
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/perl/releases) page has standalone binaries for manual download.

## Build notes

- **Single binary, no data archive.** `@INC` is pinned to a virtual root (`/zip`) and the module tree is packed into the binary as a ZIP. The interpreter's `open`/`stat` are intercepted at the linker level and served from that ZIP (miniz inflate) — no perl source patch. `/zip` is a reserved virtual mount: a miss is `ENOENT`, never the host filesystem. Linux and Windows use `-Wl,--wrap`; macOS, which has no `--wrap`, renames the symbols in `libperl.a` with `llvm-objcopy --redefine-sym`.
- **Bundled commands (16).** `cpan`, `corelist`, `encguess`, `json_pp`, `piconv`, `pod2html`, `pod2man`, `pod2text`, `pod2usage`, `podchecker`, `prove`, `ptar`, `ptargrep`, `shasum`, `streamzip`, `zipdetails` are embedded and dispatched by the invoked name. The XS-codegen/dev tools (`xsubpp`, `h2xs`, …) and the `.pod`-dependent `perldoc`/`splain` are left out.
- **No XS modules.** The binary is `-Uusedl` (no `DynaLoader`), inherent to a single static binary. Pure-Perl modules still install: `sitecustomize.pl` prepends a per-user cache dir to `@INC`, so `cpan` never touches the read-only binary.
- **Man pages embedded** for offline `unpin man perl` / `unpin man perlfunc` — the language reference plus the bundled tools.

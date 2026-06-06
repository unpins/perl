# perl

Standalone build of [perl](https://www.perl.org/) — the interpreter and its entire standard library in a single self-contained binary.

[![CI](https://github.com/unpins/perl/actions/workflows/perl.yml/badge.svg)](https://github.com/unpins/perl/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Usage

Run perl with [unpin](https://github.com/unpins/unpin):

```bash
unpin perl -e 'print "hello\n"'
unpin perl script.pl
```

Installing also adds the bundled utilities (`json_pp`, `shasum`, `prove`, `cpan`, `pod2man`, …) as their own commands:

```bash
unpin install perl
echo '{"b":2,"a":1}' | json_pp
cpan Some::Module
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

## Man pages

The language reference and the bundled tools are embedded — read them with `unpin man perl` or `unpin man perlfunc`.

## Build notes

- **Single binary, no data archive.** The whole module tree is packed into the executable as a ZIP and `@INC` is served from it: `open`/`stat` are intercepted at the linker level (Linux/Windows via `-Wl,--wrap`; macOS via `llvm-objcopy --redefine-sym`), so there is no perl source patch.
- **Bundled commands (16)** — `cpan`, `corelist`, `json_pp`, `pod2man`, `prove`, `shasum`, `zipdetails`, … — embedded and reachable by name. The XS-codegen/dev tools and `.pod`-dependent `perldoc`/`splain` are left out.
- **No XS modules** (`-Uusedl`, inherent to a static binary). Pure-Perl modules still install — `cpan` writes to a per-user cache prepended to `@INC`, never the read-only binary.

# perl

[perl](https://www.perl.org/) — the interpreter and its entire standard library in a single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/perl/actions/workflows/perl.yml/badge.svg)](https://github.com/unpins/perl/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install perl`.

## Usage

Run perl with [unpin](https://github.com/unpins/unpin):

```bash
unpin perl -e 'print "hello\n"'
unpin perl script.pl
```

`unpin install perl` also creates 16 bundled commands — `cpan`, `json_pp`, `shasum`, `prove`, `pod2man`, … (full list: `unpin info perl`):

```bash
unpin install perl
echo '{"b":2,"a":1}' | json_pp
cpan Some::Module
```

## Man pages

The language reference and the bundled tools are embedded — read them with `unpin man perl` or `unpin man perlfunc`.

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

- **One file.** The interpreter and the whole standard library, compiled modules
  such as `POSIX`, `Storable` and `Encode` included, live inside the binary, so
  perl needs no installation and no module directory.
- **Adding modules.** `cpan` and `make install` put modules in a per-user cache
  that perl searches first: `~/.cache/unpin/perl5` (or under `$XDG_CACHE_HOME`)
  on Linux and macOS, `%LOCALAPPDATA%\unpin\perl5` on Windows.
  This works for pure-Perl modules. Modules with C code cannot be added: the
  binary cannot load compiled extensions.

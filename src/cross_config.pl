#!/usr/bin/env perl
# perl-cross config.sh fixup for the unpins single-binary VFS build.
#
# Cross targets (when the build host can't execute the target) use perl-cross,
# whose own ./configure IGNORES perl's config.over -- the mechanism the native
# build uses to pin @INC and the install tree. So we apply the same two transforms
# straight to the generated config.sh; the caller then regenerates config.h +
# Makefile.config from it:
#   - runtime @INC (*exp vars)  -> /zip/share/perl5/...   (served by the VFS)
#   - install + lib dirs        -> $out/share/perl5/...   (harvestable tree;
#                                  perl-cross defaults install to lib/perl5)
# This mirrors `zipConfigOver` (the native config.over) exactly. usesitecustomize
# is already 'define' (a configure flag perl-cross honours), so it's left as-is.
use strict;
use warnings;
my $f = shift or die "usage: cross_config.pl <config.sh>\n";
open my $in, '<', $f or die "$f: $!";
my @out;
while (<$in>) {
    if (/^(?:privlibexp|archlibexp|sitelibexp|sitearchexp|vendorlibexp|vendorarchexp)=/) {
        # absolute runtime @INC root -> the /zip VFS mount (keep the suffix)
        s{='[^']*?/lib/perl5}{='/zip/share/perl5};
    } elsif (/^(?:install)?(?:priv|site|vendor|arch)\w*='/) {
        # install + lib dirs: land the harvestable tree under share/perl5
        s{/lib/perl5}{/share/perl5}g;
    }
    push @out, $_;
}
close $in;
open my $w, '>', $f or die "$f: $!";
print $w @out;
close $w;

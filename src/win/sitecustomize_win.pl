# Embedded at /zip/5.42.0/site_perl/sitecustomize.pl and served from the blob.
# perl built -Dusesitecustomize does `do "$sitelibexp/sitecustomize.pl"` at every
# startup ($sitelibexp=/zip/5.42.0/site_perl). The single binary is -Uusedl so XS
# can't load; this only enables pure-Perl module installs into a per-user cache
# dir that is prepended to @INC. Everything is runtime-computed -- no baked path.
#
# Cache root preference (Windows-first, then XDG/Unix for portability):
#   %LOCALAPPDATA%\unpin\perl5  >  $XDG_CACHE_HOME/unpin/perl5  >  $HOME/.cache/unpin/perl5
{
    my $c = $ENV{LOCALAPPDATA};
    $c ||= $ENV{XDG_CACHE_HOME};
    $c ||= "$ENV{HOME}/.cache" if $ENV{HOME};
    $c ||= "$ENV{USERPROFILE}/.cache" if $ENV{USERPROFILE};
    if ($c) {
        my $base = "$c/unpin/perl5";
        unshift @INC, "$base/lib/perl5";
        $ENV{PERL_MM_OPT} = "INSTALL_BASE=$base" unless defined $ENV{PERL_MM_OPT};
        $ENV{PERL_MB_OPT} = "--install_base $base" unless defined $ENV{PERL_MB_OPT};
    }
}
1;

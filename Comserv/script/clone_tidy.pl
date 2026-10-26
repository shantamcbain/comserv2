#!/usr/bin/env perl
# CLI for "Tidy up with AI" (Comserv::Util::SiteTidy) through the app's own AI router.
#   perl script/clone_tidy.pl <SiteName> [page_code ...] [--save]
# Default is a dry run: proposals are printed, not stored. --save writes ai-tidy.json
# (still only proposals; accept them at /site/clone_review?site=<SiteName>).
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Catalyst::Test 'Comserv';
use Comserv::Util::SiteTidy;
my $save = grep { $_ eq '--save' } @ARGV; my @a = grep { $_ ne '--save' } @ARGV;
my ($site, @only) = @a; die "usage: $0 SiteName [page_code ...] [--save]\n" unless $site;
my (undef, $c) = ctx_request("/?SiteName=$site");
my $r = Comserv::Util::SiteTidy->new->run($c, $site, (@only ? (only => \@only) : ()), dry_run => !$save);
for my $code (sort keys %{$r->{data}{pages}}) {
    my $p = $r->{data}{pages}{$code}; next unless !@only || grep { $_ eq $code } @only;
    printf "== %s [%s] model=%s verbatim=%s\n   title: %s -> %s\n   issues: %s\n   body %d -> %d chars\n",
        $code, $p->{status}, $p->{model}, $p->{text_verbatim}, $p->{old_title}, $p->{new_title} || '(unchanged)',
        join(' | ', @{$p->{issues}}), length $p->{old_body}, length $p->{new_body};
}
print "MODELS: ", join(', ', map { "$_ x$r->{models}{$_}" } keys %{$r->{models}}), "\n";
print "ERROR: $_\n" for @{$r->{errors}};
print $save ? "saved\n" : "dry run (nothing stored)\n";

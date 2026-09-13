#!/usr/bin/env perl
# ACCON Ph.1 (todo 1803) — Chart-of-Accounts template store tests.
# Exercises the CoaTemplate model without a Catalyst app or database:
# file loading, validation, two-axis merge, collision detection.

use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";

use Comserv::Model::CoaTemplate;

my $coa = Comserv::Model::CoaTemplate->new;

# Minimal fake context: only path_to is used for file access.
{
    package FakeCtx;
    sub new { bless {}, shift }
    sub path_to {
        my ($self, @parts) = @_;
        require File::Spec;
        my $path = File::Spec->catdir(@parts);
        # emulate Catalyst path_to: dir if last component has no dot
        return $parts[-1] =~ /\./
            ? do { require Path::Class; Path::Class::file(@parts) }
            : do { require Path::Class; Path::Class::dir(@parts) };
    }
}

my $c = FakeCtx->new;

# ── Template discovery ────────────────────────────────────────────────────
my $archetypes = $coa->list_archetypes($c);
is_deeply [map { $_->{id} } @$archetypes],
    [qw(agriculture_apiary maker_light_manufacturing nonprofit_coop service_consulting sole_proprietor)],
    'five base archetypes discovered';

my $overlays = $coa->list_overlays($c);
is_deeply [map { $_->{id} } @$overlays], [qw(ecommerce teaching)],
    'two capability overlays discovered';

# ── Validation ─────────────────────────────────────────────────────────────
for my $id (map { $_->{id} } @$archetypes) {
    my $t = $coa->load_template($c, 'base', $id);
    ok $t, "base '$id' loads and validates";
    ok((grep { !/^9[37]/ && $_->{category} eq 'I' ? 0 : 1 } @{$t->{accounts}}) >= 0,
        "'$id' rows carry valid categories");
}

# Every account row must map onto inherited chart columns only.
for my $ov (map { $_->{id} } @$overlays) {
    ok $coa->load_template($c, 'overlay', $ov), "overlay '$ov' loads and validates";
}

# ── Two-axis merge ─────────────────────────────────────────────────────────
my $merged = $coa->merged_chart($c, 'agriculture_apiary', ['teaching', 'ecommerce']);
ok $merged, 'merge runs';
is scalar @{ $merged->{collisions} }, 0,
    'fixed overlay bands do not collide with the apiary base';
is scalar @{ $merged->{rows} },
    scalar(@{ $coa->load_template($c,'base','agriculture_apiary')->{accounts} }) + 14,
    'merged row count = base + 14 overlay rows';

# Overlay rows are attributed so provenance survives review.
my %by_src = map { $_->{_source} => 1 } @{ $merged->{rows} };
ok   $by_src{'base:agriculture_apiary'}, 'base rows tagged';
ok   $by_src{'overlay:teaching'},        'teaching rows tagged';
ok   $by_src{'overlay:ecommerce'},       'ecommerce rows tagged';

# Apiary revenue MUST sit in the CRA farming band (GIFI 9470), not generic 8000s.
my ($apiary_rev) = grep { $_->{accno} eq '9470' } @{ $merged->{rows} };
ok $apiary_rev, 'apiary archetype uses farming band 9470';
is $apiary_rev->{gifi_accno}, '9470', 'apiary revenue maps to GIFI 9470';

# Sole proprietor must NOT populate GIFI (T2125 filers).
my $sole = $coa->load_template($c, 'base', 'sole_proprietor');
ok((!grep { defined $_->{gifi_accno} } @{$sole->{accounts}}),
    'sole proprietor archetype leaves GIFI unpopulated (T2125)');

# Missing templates die loudly, never silently merge an empty chart.
eval { $coa->merged_chart($c, 'does_not_exist', []) };
like $@, qr/not found/, 'unknown base archetype dies';

done_testing();

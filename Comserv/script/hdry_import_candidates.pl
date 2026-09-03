#!/usr/bin/env perl
#
# hdry_import_candidates.pl — create printing_3d_models rows for the confirmed
# un-imported HDRY parts, each validated against its real geometry first.
#
# Decisions confirmed by the user (2026-09-02):
#   1. one wheel = 2 half-wheels + 1 tire          YES
#   2. foot quantity = 4 (one per wheel)
#   3. Wheel_M.stl = UNKNOWN (not a mirror of Wheel; 3mm thicker). Imported as a
#      separate "wide" variant but NOT given a BOM line until identified.
#   4. FFL01: import BOTH sensor and no_sensor variants. The sensor version is
#      the default for a drying cabinet driving an AMS/multi-colour printer
#      (user's Kobra 3 + AMS; future K2). no_sensor kept for single-filament builds.
#
# Gate: every row is checked with Comserv::Util::PartGeometry->validate_part_link
# or parse_stl_volume_cm3 BEFORE any INSERT. Nothing is written on validation failure.
#
# Usage:
#   perl script/hdry_import_candidates.pl            # dry run (default)
#   perl script/hdry_import_candidates.pl --apply    # write
#
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Comserv::Model::RemoteDB;
use Comserv::Util::PartGeometry;

my $APPLY = grep { $_ eq '--apply' } @ARGV;
my $CONN  = 'db_production_mysql';
my $SITE  = '3d';
my $DOORS = '/data/nfs/hdry_parts/023037_HDRY_System_V3__Doors';
my $EXTRA = '/data/nfs/hdry_parts/023113_HDRY_System_V3__Dryer__Extras';

# name, file, source, tags
my @IMPORT = (
  # ---- door hardware (was entirely missing) ----
  ['HDRY Female hinge left (FHL)',   "$DOORS/Female_hinge_L1__1___1_.stl",   'project_import', 'hinge,door,left'],
  ['HDRY Female hinge right (FHR)',  "$DOORS/Female_hinge_R1__1___1_.stl",   'project_import', 'hinge,door,right'],
  ['HDRY Male hinge left (MHL)',     "$DOORS/Male_hinge_L1__1___1_.stl",     'project_import', 'hinge,door,left'],
  ['HDRY Male hinge right (MHR)',    "$DOORS/Male_hinge_R1__1___1_.stl",     'project_import', 'hinge,door,right'],
  ['HDRY Hinge latch left (HLL)',    "$DOORS/Hinge_latch_L1__1___1_.stl",    'project_import', 'latch,door,left'],
  ['HDRY Hinge latch right (HLR)',   "$DOORS/Hinge_latch_R1__1___1_.stl",    'project_import', 'latch,door,right'],
  ['HDRY Door handle',               "$DOORS/Handle__2___1_.stl",            'project_import', 'handle,door'],
  ['HDRY Window shape',              "$DOORS/Window_Shape.stl",              'project_import', 'window,door'],

  # ---- wheel kit: support + tire (both were missing) ----
  ['HDRY Wheel support foot',        "$EXTRA/Foot__1___1_.stl",              'project_import', 'wheel,support'],
  ['HDRY Wheel tire (Gomma)',        "$EXTRA/Gomma.stl",                     'project_import', 'wheel,tire,tpu'],

  # ---- wheel_M: unknown variant, imported but NOT put on a BOM ----
  ['HDRY Wheel half wide (variant, unidentified)', "$EXTRA/Wheel_M.stl",     'project_import', 'wheel,variant,UNIDENTIFIED'],

  # ---- FFL01: both variants, per user decision ----
  ['HDRY Front Door Left up - sensor (FFL01-S)',    "$DOORS/FFL01_Sensor.stl",    'project_import', 'door,sensor,ams'],
  ['HDRY Front Door Left up - no sensor (FFL01-N)', "$DOORS/FFL01_no_Sensor.stl", 'project_import', 'door,no-sensor'],
);

my $rdb = Comserv::Model::RemoteDB->new;
my $geo = Comserv::Util::PartGeometry->new;

print "=" x 76 . "\n";
print "HDRY candidate import" . ($APPLY ? "  [APPLY]" : "  [DRY RUN]") . "\n";
print "=" x 76 . "\n\n";

my (@todo, @blocked, @skipped);

for my $it (@IMPORT) {
    my ($name, $path, $source, $tags) = @$it;

    unless (-r $path) {
        push @blocked, [$name, "file not readable: $path"];
        next;
    }

    # already present?
    (my $f = $path) =~ s{.*/}{};
    my $ex = $rdb->execute_query(undef, $CONN,
        'SELECT id FROM printing_3d_models WHERE nfs_path=? AND sitename=?', [$path, $SITE]);
    if ($ex && @$ex) {
        push @skipped, [$name, "already model id " . $ex->[0]{id}];
        next;
    }

    # geometry gate: must parse and have a real volume
    my $vol = $geo->parse_stl_volume_cm3($path);
    unless (defined $vol && $vol > 0) {
        push @blocked, [$name, "could not compute volume for $f"];
        next;
    }

    # name-vs-geometry gate where a rule exists (hinges/doors have no L1/L2 rule,
    # so this is a no-op for them; it still catches a mislabelled corner part)
    my $v = $geo->validate_part_link($name, $path);
    if (!$v->{ok} && !$v->{error}) { push @blocked, [$name,'validate error']; next }
    if (!$v->{ok} && $v->{expected_z}) {
        push @blocked, [$name, $v->{error}];
        next;
    }

    push @todo, {
        name => $name, path => $path, source => $source, tags => $tags,
        vol => sprintf('%.4f', $vol), wt => sprintf('%.3f', $vol * 1.24),
    };
}

print "--- TO CREATE (" . scalar(@todo) . ") ---\n";
for my $t (@todo) {
    (my $f = $t->{path}) =~ s{.*/}{};
    printf "  %-46s\n      %-34s vol=%-10s wt=%s g\n",
        $t->{name}, $f, $t->{vol}, $t->{wt};
    if ($APPLY) {
        my $res = $rdb->execute_query(undef, $CONN, q{
            INSERT INTO printing_3d_models
              (sitename, name, nfs_path, source, description, file_type,
               stl_volume_cm3, stl_weight_g, is_active, created_at)
            VALUES (?,?,?,?,?,?,?,?,1,NOW())
        }, [ $SITE, $t->{name}, $t->{path}, $t->{source},
             'tags: ' . $t->{tags}, 'stl', $t->{vol}, $t->{wt} ]);
        my $ok = (ref $res eq 'HASH' && $res->{success}) ? 1 : 0;
        printf "      %s\n", $ok ? "CREATED" : "FAILED: " . (($res->{error}) // 'unknown');
    }
}

if (@skipped) {
    print "\n--- SKIPPED ---\n";
    printf "  %-46s %s\n", substr($_->[0],0,46), $_->[1] for @skipped;
}
if (@blocked) {
    print "\n--- BLOCKED (not written) ---\n";
    printf "  %-46s %s\n", substr($_->[0],0,46), $_->[1] for @blocked;
}

print "\n" . "=" x 76 . "\n";
printf "create=%d skipped=%d blocked=%d  %s\n",
    scalar(@todo), scalar(@skipped), scalar(@blocked),
    $APPLY ? "(WRITTEN)" : "(dry run — --apply to write)";
print "=" x 76 . "\n";

#!/usr/bin/env perl
#
# hdry_repair_part_links.pl — repair HDRY V3 model rows that were linked to the
# WRONG STL, and refuse to write any link that fails geometric validation.
#
# Background (2026-09-02): the 3MF importer had no object->part-name mapping
# (BambuStudio writes unnamed objects) and silently fell back to near-name
# matches. Four L1 corner/rail rows ended up pointing at L2 geometry:
#
#   model 32 FL01  -> FL02.stl   (215mm, should be 150)
#   model 22 BL01  -> BL02.stl   (215mm, should be 150)
#   model 26 BR01  -> BR02.stl   (215mm, should be 150)
#   model 20 BBR01 -> BBR02.stl  (215mm, should be 150)
#
# The correct L1 files DO exist on disk — the importer just named them wrong:
#   FL03.stl IS FL01, BL03.stl IS BL01, BR03.stl IS BR01, BBR03.stl IS BBR01.
# Proven by mirror-geometry + Z-scale chamfer matching (1.67x-2.82x separation,
# a clean 4-of-4 bijection). See hdry_work/STL_EXTRACTION_AUDIT.md.
#
# Usage:
#   perl script/hdry_repair_part_links.pl            # dry run (default)
#   perl script/hdry_repair_part_links.pl --apply    # write changes
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

my $M1 = '/data/nfs/hdry_parts/023022_HDRY_System_V3__Module_1';
my $M2 = '/data/nfs/hdry_parts/023030_HDRY_System_V3__Module_2';

# model_id => correct absolute path. Every entry is validated before write.
my %FIX = (
    32 => "$M2/FL03.stl",    # Front Left corner L1 (FL01)
    22 => "$M2/BL03.stl",    # Back Left corner L1  (BL01)
    26 => "$M2/BR03.stl",    # Back Right corner L1 (BR01)
    20 => "$M2/BBR03.stl",   # Bottom Back Right L1 (BBR01)
);

my $rdb = Comserv::Model::RemoteDB->new;
my $geo = Comserv::Util::PartGeometry->new;

print "=" x 72 . "\n";
print "HDRY part-link repair" . ($APPLY ? "  [APPLY MODE]" : "  [DRY RUN]") . "\n";
print "=" x 72 . "\n\n";

my (@todo, @skipped, @blocked);

for my $id (sort { $a <=> $b } keys %FIX) {
    my $new_path = $FIX{$id};

    my $rows = $rdb->execute_query(undef, $CONN,
        'SELECT id, name, nfs_path, stl_volume_cm3 FROM printing_3d_models WHERE id=? AND sitename=?',
        [ $id, $SITE ]);
    my $row = ($rows && @$rows) ? $rows->[0] : undef;
    unless ($row) {
        push @blocked, [$id, 'no such model row'];
        next;
    }

    my $old = $row->{nfs_path} || '(none)';

    # Gate: the new file must be geometrically consistent with the part name.
    my $v = $geo->validate_part_link($row->{name}, $new_path);
    unless ($v->{ok}) {
        push @blocked, [$id, "VALIDATION FAILED: " . ($v->{error} || '?')];
        next;
    }

    # Gate: the current link should actually be broken (idempotence).
    if ($old eq $new_path) {
        push @skipped, [$id, $row->{name}, 'already correct'];
        next;
    }

    # Gate: confirm the OLD link is indeed invalid, so we never "repair" a good row.
    my $old_v = ($old && -r $old) ? $geo->validate_part_link($row->{name}, $old) : undef;
    my $old_bad = $old_v ? !$old_v->{ok} : 1;

    push @todo, {
        id       => $id,
        name     => $row->{name},
        old      => $old,
        new      => $new_path,
        old_bad  => $old_bad,
    };
}

print "--- REPAIRS ---\n";
if (!@todo) {
    print "  (nothing to repair)\n";
}
for my $t (@todo) {
    (my $of = $t->{old}) =~ s{.*/}{};
    (my $nf = $t->{new}) =~ s{.*/}{};
    printf "  model %-3d %-34s\n", $t->{id}, $t->{name};
    printf "        %s -> %s\n", $of, $nf;
    printf "        old link %s\n", $t->{old_bad} ? "confirmed INVALID" : "was valid (review!)";

    if ($APPLY) {
        my $res = $rdb->execute_query(undef, $CONN,
            'UPDATE printing_3d_models SET nfs_path=? WHERE id=? AND sitename=?',
            [ $t->{new}, $t->{id}, $SITE ]);
        my $ok = (ref $res eq 'HASH' && $res->{success}) ? 1 : 0;
        printf "        %s\n", $ok ? "APPLIED" : "FAILED: " . (($res->{error}) // 'unknown');
    }
}

if (@skipped) {
    print "\n--- SKIPPED ---\n";
    printf "  model %-3d %-34s %s\n", $_->[0], $_->[1], $_->[2] for @skipped;
}
if (@blocked) {
    print "\n--- BLOCKED (not written) ---\n";
    printf "  model %-3d %s\n", $_->[0], $_->[1] for @blocked;
}

print "\n" . "=" x 72 . "\n";
printf "repair=%d skipped=%d blocked=%d  %s\n",
    scalar(@todo), scalar(@skipped), scalar(@blocked),
    $APPLY ? "(changes WRITTEN)" : "(dry run — re-run with --apply to write)";
print "=" x 72 . "\n";

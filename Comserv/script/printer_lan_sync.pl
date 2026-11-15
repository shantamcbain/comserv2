#!/usr/bin/env perl
# Follow known printers and enroll any Kobra the scan finds.
# Detached from the web worker: a /24 sweep must not block /3d/queue.
#
#   perl script/printer_lan_sync.pl
#   perl script/printer_lan_sync.pl --follow-only

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Comserv::Model::RemoteDB;
use Comserv::Model::Schema::Ency;
use Comserv::Util::Printing3d::LanMap;

my $follow_only = grep { $_ eq '--follow-only' } @ARGV;

my $rdb  = Comserv::Model::RemoteDB->new;
my $info = $rdb->get_connection_info('ency');
my $dbh  = $rdb->get_connection(undef, $info->{connection_name}) or die "no database handle\n";
$dbh->do('SET NAMES utf8mb4');
my $schema = Comserv::Model::Schema::Ency->connect(
    sub { $dbh }, '', '', { RaiseError => 1, PrintError => 0 });

my $map = Comserv::Util::Printing3d::LanMap->new;

if ($follow_only) {
    my @rows = $schema->resultset('Printing3dPrinter')->search({ sitename => '3d' })->all;
    for my $row (@rows) {
        my $r = $map->resolve(undef, $row);
        $row->discard_changes;
        printf "printer #%d ok=%s host=%s err=%s notes_host=%s\n",
            $row->id, ($r->{ok} ? 1 : 0), ($r->{host} || ''),
            ($r->{error} || ''), Comserv::Util::Printing3d::LanMap::host_from_notes($row->notes || '');
        my $st = $r->{state} || {};
        printf "  state ok=%s print_state=%s\n", ($st->{ok} ? 1 : 0), ($st->{print_state} || '');
    }
    exit 0;
}

my $res = $map->sync_farm(undef, $schema, '3d');
for my $f (@{ $res->{followed} || [] }) {
    printf "followed #%s ok=%s host=%s err=%s\n", $f->{id}, $f->{ok}, $f->{host}, $f->{error};
}
for my $e (@{ $res->{enrolled} || [] }) {
    printf "enrolled printer #%s host=%s serial=%s\n", $e->{printer_id}, $e->{host}, $e->{serial};
}
print "enrolled " . scalar(@{ $res->{enrolled} || [] }) . "\n";
exit 0;

#!/usr/bin/env perl
# Finish one queued consignment photo count, OUTSIDE the web server.
#
#   perl script/consignment_count_worker.pl <count_id>
#
# Why this exists: reading a container photo runs a 7B vision model on CPU (~20 s
# warm, minutes cold). Doing that inside the request blocked the single web worker
# and froze the whole app for 3.5 minutes on the first real photo (2026-11-06), so
# the request now only stores the photo (status='reading') and spawns this script.
#
# The row is the handoff: status 'reading' -> 'draft' (with raw_text + lines) or
# 'failed' (with the reason in notes). The review screen polls for that change.
#
# Standalone by design: no Catalyst app, no session. The Grok fallback model is
# constructed directly (Comserv::Model::Grok pulls its key from DB/env itself).

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Comserv::Model::RemoteDB;
use Comserv::Model::Schema::Ency;
use Comserv::Model::Grok;
use Comserv::Util::ConsignmentCountRun;
use Comserv::Util::Logging;

my $count_id = shift or die "usage: $0 <count_id>\n";
$count_id =~ /^\d+$/ or die "count_id must be numeric\n";

$| = 1;

my $rdb  = Comserv::Model::RemoteDB->new;
my $info = $rdb->get_connection_info('ency');
my $dbh  = $rdb->get_connection(undef, $info->{connection_name}) or die "no database handle\n";
$dbh->do('SET NAMES utf8mb4');

my $schema = Comserv::Model::Schema::Ency->connect(
    sub { $dbh }, '', '', { RaiseError => 1, PrintError => 0 });

my $grok = eval { Comserv::Model::Grok->new };
unless ($grok) {
    warn "grok model unavailable, local vision only: $@\n";
}

my $run = Comserv::Util::ConsignmentCountRun->new(
    root => "$Bin/..",
    ($grok ? (grok => $grok) : ()),
);

my $res = $run->finish_from_photo($schema, $count_id);

if ($res->{ok}) {
    print "count #$count_id read by $res->{engine}: $res->{raw_text}\n";
    exit 0;
}
print "count #$count_id failed: " . ($res->{error} || 'unknown error') . "\n";
exit 1;

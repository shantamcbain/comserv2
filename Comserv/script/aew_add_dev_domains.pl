#!/usr/bin/env perl
# Add dev workstation hostnames/IPs to sitedomain (same site as workstation.local).
# Run on the workstation: perl script/aew_add_dev_domains.pl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Comserv::Model::HybridDB;
use Comserv::Util::Logging;

my @domains = (
    '172.30.131.126',   # ZeroTier (zthnhd6k65) — tablet/remote login
    '192.168.1.199',    # LAN — optional; prefer workstation.local on LAN
);

my $ref_domain = 'workstation.local';

my $c = bless {}, 'Comserv::Controller::Root';
my $schema = Comserv::Model::HybridDB->new->schema($c, 'DBEncy');
my $rs = $schema->resultset('SiteDomain');

my $ref = $rs->find({ domain => $ref_domain });
unless ($ref) {
    die "Reference domain $ref_domain not found in sitedomain — cannot continue.\n";
}
my $site_id = $ref->site_id;
print "Using site_id=$site_id from $ref_domain\n";

for my $domain (@domains) {
    if ($rs->find({ domain => $domain })) {
        print "OK (exists): $domain\n";
        next;
    }
    $rs->create({ site_id => $site_id, domain => $domain });
    print "ADDED: $domain -> site_id $site_id\n";
}

print "\nRemote editor URLs:\n";
print "  ZeroTier: http://172.30.131.126:3001/ai/editing_widget_popup\n";
print "  LAN name: http://workstation.local:3001/ai/editing_widget_popup\n";
print "  SSH tunnel: ssh -N comserv-aew  then  http://workstation.local:3001/... (add 127.0.0.1 workstation.local on tablet)\n";
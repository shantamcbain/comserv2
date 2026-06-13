#!/usr/bin/env perl
# Add dev workstation hostnames/IPs to sitedomain (same site as workstation.local).
# Run on the workstation: perl script/aew_add_dev_domains.pl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use DBI;
use Comserv::Model::RemoteDB;

my @domains = (
    '172.30.131.126',   # ZeroTier (zthnhd6k65) — tablet/remote login
    '192.168.1.199',    # LAN — phone on same Wi‑Fi
    '127.0.0.1',        # SSH tunnel from Android (Termius → http://127.0.0.1:3001/...)
);

my $ref_domain = 'workstation.local';
my $conn_name  = 'zerotier_ency';

my $rdb = Comserv::Model::RemoteDB->new;
$rdb->_load_config();
my $cfg = $rdb->config->{$conn_name}
    or die "Connection $conn_name not in RemoteDB config\n";

my $host = $cfg->{host} // 'localhost';
my $port = $cfg->{port} // 3306;
my $dsn  = ($host =~ /^(?:localhost|127\.0\.0\.1)$/)
    ? "dbi:MariaDB:database=$cfg->{database};host=127.0.0.1"
    : "dbi:MariaDB:database=$cfg->{database};host=$host;port=$port";

my $dbh = DBI->connect($dsn, $cfg->{username}, $cfg->{password},
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 })
    or die "DB connect failed ($conn_name): $DBI::errstr\n";

my ($site_id) = $dbh->selectrow_array(
    'SELECT site_id FROM sitedomain WHERE domain = ?', undef, $ref_domain
);
unless ($site_id) {
    die "Reference domain $ref_domain not found in sitedomain — cannot continue.\n";
}
print "Using site_id=$site_id from $ref_domain (via $conn_name)\n";

for my $domain (@domains) {
    my ($exists) = $dbh->selectrow_array(
        'SELECT id FROM sitedomain WHERE domain = ?', undef, $domain
    );
    if ($exists) {
        print "OK (exists): $domain\n";
        next;
    }
    $dbh->do('INSERT INTO sitedomain (site_id, domain) VALUES (?, ?)', undef, $site_id, $domain);
    print "ADDED: $domain -> site_id $site_id\n";
}

print "\nRemote URLs:\n";
print "  AI widget:      http://172.30.131.126:3001/ai/widget\n";
print "  AI widget TLS:  https://172.30.131.126:3443/ai/widget\n";
print "  Code editor:    http://172.30.131.126:3001/ai/editing_widget_popup\n";
print "  LAN widget:     http://192.168.1.199:3001/ai/widget\n";
print "  Android tunnel: Termius port-forward 3001, then http://127.0.0.1:3001/ai/widget\n";
print "  More options:   ./script/aew_android_access.sh\n";
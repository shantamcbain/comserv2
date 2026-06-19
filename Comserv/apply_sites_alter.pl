#!/usr/bin/env perl
# One-time script: add points_enabled and cash_allowed columns to sites table
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Comserv::Model::DBSchemaManager;
use DBI;

my $mgr = Comserv::Model::DBSchemaManager->new();
my $db_config = $mgr->db_config;

my $cfg = $db_config->{production_server} || $db_config->{shanta_ency};
die "No production_server or shanta_ency config found in db_config.json\n" unless $cfg;

my $dsn = "DBI:mysql:database=$cfg->{database};host=$cfg->{host};port=$cfg->{port}";
my $dbh = DBI->connect($dsn, $cfg->{username}, $cfg->{password}, {
    RaiseError => 1,
    AutoCommit => 1,
    mysql_enable_utf8 => 1
}) or die "Cannot connect: $DBI::errstr";

print "Connected to $cfg->{host}:$cfg->{port}/$cfg->{database}\n";

my $sql = q{
    ALTER TABLE sites
      ADD COLUMN points_enabled TINYINT(1) NOT NULL DEFAULT 0 AFTER http_header_keywords,
      ADD COLUMN cash_allowed   TINYINT(1) NOT NULL DEFAULT 0 AFTER points_enabled
};

eval {
    $dbh->do($sql);
    print "SUCCESS: Columns added to sites table\n";
};
if ($@) {
    print "ERROR: $@\n";
}

$dbh->disconnect();
#!/usr/bin/env perl
# UPDATE: set sitename='ENCY' for all todo rows whose subject contains 'ENCY'
# (any case) and whose sitename is not already 'ENCY'.
# Safe: snapshots record_id->old_sitename to a CSV first, runs one UPDATE via
# the SAME RemoteDB connection the app uses, then verifies the match is empty.
use strict;
use warnings;
use lib 'Comserv/lib';

use Comserv::Model::RemoteDB;
use Comserv::Model::Schema::Ency;

my $BAK = '/tmp/ency_sitename_backup_' . time() . '.csv';

my $remote_db = Comserv::Model::RemoteDB->new;
my $info = $remote_db->get_connection_info('ency');
my $conn = $info->{config};
my $dsn = $conn->{db_type} eq 'sqlite'
    ? "dbi:SQLite:dbname=$conn->{database_path}"
    : "dbi:mysql:database=$conn->{database};host=$conn->{host};port=$conn->{port}";
my $schema = Comserv::Model::Schema::Ency->connect(
    $dsn, $conn->{username}, $conn->{password},
    { RaiseError => 1, PrintError => 0, AutoCommit => 0 },
);
my $dbh = $schema->storage->dbh;

# 1) Snapshot matching rows (record_id, old sitename) BEFORE mutating.
my $sel = $dbh->prepare(
    "SELECT record_id, sitename FROM todo WHERE subject LIKE ? AND sitename <> 'ENCY'"
);
$sel->execute('%ENCY%');
open(my $bk, '>', $BAK) or die "cannot write backup: $!";
print $bk "record_id,old_sitename\n";
my $n = 0;
while (my $r = $sel->fetchrow_hashref) {
    print $bk "$r->{record_id},$r->{sitename}\n";
    $n++;
}
close($bk);
print "Snapshot of $n rows written to $BAK\n";

# 2) Perform the single UPDATE.
my $upd = $dbh->prepare(
    "UPDATE todo SET sitename = 'ENCY' WHERE subject LIKE ? AND sitename <> 'ENCY'"
);
$upd->execute('%ENCY%');
my $affected = $upd->rows;
print "UPDATE affected rows: $affected\n";

# 3) Verify: zero rows should still match the criteria.
my $chk = $dbh->prepare(
    "SELECT COUNT(*) AS n FROM todo WHERE subject LIKE ? AND sitename <> 'ENCY'"
);
$chk->execute('%ENCY%');
my $remaining = $chk->fetchrow_hashref->{n};
print "Rows STILL matching (should be 0): $remaining\n";

if ($remaining == 0) {
    $dbh->commit;
    print "COMMITTED.\n";
    # Sanity: how many rows now have sitename='ENCY'
    my $tot = $dbh->prepare("SELECT COUNT(*) AS n FROM todo WHERE sitename = 'ENCY'");
    $tot->execute;
    print "Total rows now sitename='ENCY': ", $tot->fetchrow_hashref->{n}, "\n";
} else {
    $dbh->rollback;
    die "VERIFY FAILED ($remaining still match) — rolled back. No changes made.\n";
}

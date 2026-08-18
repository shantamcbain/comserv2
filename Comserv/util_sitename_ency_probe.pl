#!/usr/bin/env perl
# Read-only probe: report which ency connection the app uses + matching rows.
# Uses Comserv::Model::RemoteDB exactly like Comserv::Model::DBEncy does.
use strict;
use warnings;
use lib 'Comserv/lib';

use Comserv::Model::RemoteDB;
use Comserv::Model::Schema::Ency;

my $remote_db = Comserv::Model::RemoteDB->new;
my $info = $remote_db->get_connection_info('ency');
die "No connection info for 'ency'\n" unless $info;

my $conn = $info->{config};
my $name = $info->{connection_name};
print "SELECTED CONNECTION: $name\n";
print "  target: ", ($conn->{host} ? "$conn->{host}:$conn->{port}/$conn->{database}" : $conn->{database_path}), "\n";

my $dsn = $conn->{db_type} eq 'sqlite'
    ? "dbi:SQLite:dbname=$conn->{database_path}"
    : "dbi:mysql:database=$conn->{database};host=$conn->{host};port=$conn->{port}";
my $schema = Comserv::Model::Schema::Ency->connect(
    $dsn, $conn->{username}, $conn->{password},
    { RaiseError => 1, PrintError => 0 },
);

print "\nDISTINCT sitenames present in todo table:\n";
my $sth = $schema->storage->dbh->prepare(
    "SELECT sitename, COUNT(*) AS n FROM todo GROUP BY sitename ORDER BY n DESC"
);
$sth->execute;
while (my $row = $sth->fetchrow_hashref) {
    printf "  %-20s %d\n", $row->{sitename}, $row->{n};
}

print "\nMATCHING ROWS (subject LIKE '%ENCY%' AND sitename <> 'ENCY'):\n";
my $match = $schema->resultset('Todo')->search(
    { subject => { like => '%ENCY%' }, sitename => { '!=' => 'ENCY' } },
    { order_by => { -asc => 'record_id' } },
);
my $count = 0;
while (my $t = $match->next) {
    $count++;
    printf "  rec=%d sitename=%-10s subject=%s\n",
        $t->record_id, $t->sitename, substr($t->subject, 0, 70);
    last if $count >= 50;
}
my $total = $schema->resultset('Todo')->search(
    { subject => { like => '%ENCY%' }, sitename => { '!=' => 'ENCY' } }
)->count;
print "\nTOTAL matching rows that would be updated: $total\n";

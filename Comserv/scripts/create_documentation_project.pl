#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use DateTime;
use DBI;
use JSON;

# Read db_config.json to find production host
my $config_file = "$FindBin::Bin/../db_config.json";
my ($host, $db, $user, $pass) = ('192.168.1.198', 'ency', 'shanta_forager', '');

if (-f $config_file) {
    local $/;
    open my $fh, '<', $config_file or die "Cannot read $config_file: $!";
    my $cfg = decode_json(<$fh>);
    close $fh;
    if (my $prod = $cfg->{production_ency} || $cfg->{zerotier_ency} || $cfg->{local_ency}) {
        $host = $prod->{host}   if $prod->{host} && $prod->{host} !~ /YOUR_/;
        $db   = $prod->{database} if $prod->{database};
        $user = $prod->{username} if $prod->{username};
        $pass = $prod->{password} if $prod->{password};
    }
}

$pass ||= $ENV{DB_PASS} || 'UA=nPF8*m+T#';
$user ||= $ENV{DB_USER} || 'shanta_forager';

my $dbh = DBI->connect("DBI:mysql:database=$db;host=$host", $user, $pass,
    { RaiseError => 1, PrintError => 0, mysql_connect_timeout => 5 })
    or die "Cannot connect to $host/$db: $DBI::errstr\n";

print "Connected to $host/$db\n";

# Parent is DOCSYS (id=37) — Documentation System Refactoring & Enhancement
my $parent_id   = 37;
my $project_code = 'DOCSYS-ROLES';

# Check already exists
my $check = $dbh->selectrow_array(
    "SELECT id FROM projects WHERE project_code = ?", undef, $project_code
);

if ($check) {
    print "Sub-project $project_code already exists (id=$check) under DOCSYS (id=$parent_id). Nothing inserted.\n";
    $dbh->disconnect;
    exit 0;
}

my $now   = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
my $today = DateTime->now->strftime('%Y-%m-%d');
my $end   = DateTime->now->add(months => 2)->strftime('%Y-%m-%d');

my $sth = $dbh->prepare(<<'SQL');
INSERT INTO projects
    (name, description, start_date, end_date, status,
     project_code, project_size, estimated_man_hours,
     developer_name, client_name, sitename, comments,
     username_of_poster, group_of_poster, date_time_posted, parent_id, record_id)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
SQL

$sth->execute(
    'Role-Based Documentation Visibility',
    'Improve documentation system with proper role-based visibility filtering. '
        . 'Roles: unauthenticated (login/getting-started only), normal, editor, '
        . 'developer, admin, CSC admin (full access). '
        . 'Improve META block scanning for accurate document categorisation. '
        . 'Add admin UI for assigning roles per document. '
        . 'SiteName and username filtering. '
        . 'Zenflow task: documentation-9122.',
    $today,
    $end,
    'In-Process',
    $project_code,
    3,
    40,
    'Development Team',
    'CSC',
    'CSC',
    'Sub-project of DOCSYS (id=37). Zenflow task documentation-9122.',
    'system',
    'admin',
    $now,
    $parent_id,
    0,
);

my $new_id = $dbh->last_insert_id(undef, undef, 'projects', 'id');
print "Created sub-project 'Role-Based Documentation Visibility' id=$new_id\n";
print "  Code: $project_code  Parent: DOCSYS (id=$parent_id)\n";
print "  View at: /project/details?project_id=$new_id\n";

$dbh->disconnect;

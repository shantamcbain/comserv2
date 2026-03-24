#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use DateTime;
use DBI;
use JSON;

my $config_file = "$FindBin::Bin/../db_config.template.json";

my $dsn;
my $db_user;
my $db_pass;

if (-f $config_file) {
    local $/;
    open my $fh, '<', $config_file or die "Cannot read $config_file: $!";
    my $cfg = decode_json(<$fh>);
    close $fh;
    my $env = $cfg->{environments}{development} || $cfg->{environments}{production};
    if ($env) {
        $dsn      = "DBI:mysql:database=$env->{database};host=$env->{host};port=" . ($env->{port} || 3306);
        $db_user  = $env->{username};
        $db_pass  = $env->{password};
    }
}

$dsn     //= $ENV{DB_DSN}  // "DBI:mysql:database=ency;host=localhost";
$db_user //= $ENV{DB_USER} // 'root';
$db_pass //= $ENV{DB_PASS} // '';

my $dbh = DBI->connect($dsn, $db_user, $db_pass, { RaiseError => 1, PrintError => 0 })
    or die "Cannot connect to database: $DBI::errstr\n";

my $now = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
my $today = DateTime->now->strftime('%Y-%m-%d');
my $end   = DateTime->now->add(months => 3)->strftime('%Y-%m-%d');

my $check = $dbh->selectrow_array(
    "SELECT id FROM projects WHERE project_code = ?", undef, 'DOC-ROLE-001'
);

if ($check) {
    print "Project DOC-ROLE-001 already exists (id=$check). Nothing inserted.\n";
    $dbh->disconnect;
    exit 0;
}

my $sth = $dbh->prepare(<<'SQL');
INSERT INTO projects
    (name, description, start_date, end_date, status,
     project_code, project_size, estimated_man_hours,
     developer_name, client_name, sitename, comments,
     username_of_poster, group_of_poster, date_time_posted)
VALUES
    (?, ?, ?, ?, ?,
     ?, ?, ?,
     ?, ?, ?, ?,
     ?, ?, ?)
SQL

$sth->execute(
    'Documentation System Improvements',
    'Role-based visibility filtering for documentation pages. '
        . 'Unauthenticated users see only login/getting-started docs. '
        . 'Normal users see user-level docs. Editors, developers, admins '
        . 'and CSC admins see progressively more content. '
        . 'Improved META block scanning for accurate document categorisation. '
        . 'Admin UI to assign roles per document. '
        . 'SiteName and username filtering. '
        . 'Optional future migration to DB-based Pages system.',
    $today,
    $end,
    'In-Process',
    'DOC-ROLE-001',
    3,
    40,
    'Development Team',
    'CSC',
    'CSC',
    'Zenflow task: documentation-9122. '
        . 'Tracks role-based documentation visibility improvements.',
    'system',
    'admin',
    $now,
);

my $new_id = $dbh->last_insert_id(undef, undef, 'projects', 'id');
print "Created project 'Documentation System Improvements' with id=$new_id (code=DOC-ROLE-001).\n";
print "View at: /project/project\n";

$dbh->disconnect;

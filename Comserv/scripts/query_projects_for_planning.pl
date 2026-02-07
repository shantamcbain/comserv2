#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Comserv::Model::Schema::Ency;
use Comserv::Model::RemoteDB;
use Data::Dumper;

my $remote_db = Comserv::Model::RemoteDB->new;
my $conn_wrapper = $remote_db->select_connection('ency');

unless ($conn_wrapper && $conn_wrapper->{config}) {
    die "ERROR: Could not select database connection for 'ency'\n";
}

my $conn_info = $conn_wrapper->{config};
print "Using connection: " . $conn_wrapper->{connection_name} . "\n";
print "Host: " . ($conn_info->{host} || 'N/A') . "\n";
print "Database: " . ($conn_info->{database} || 'N/A') . "\n\n";

my $db_driver = $conn_info->{db_type};
$db_driver = 'MariaDB' if lc($db_driver) eq 'mariadb';
$db_driver = 'mysql' if lc($db_driver) eq 'mysql';

my $dsn = "dbi:$db_driver:database=" . $conn_info->{database} . 
          ";host=" . $conn_info->{host} . ";port=" . ($conn_info->{port} || 3306);

my $schema = Comserv::Model::Schema::Ency->connect(
    $dsn,
    $conn_info->{user},
    $conn_info->{password},
    { mysql_enable_utf8 => 1, quote_char => '`', name_sep => '.' }
);

print "=== Querying Projects Table for Planning System Mapping ===\n\n";

my $projects_rs = $schema->resultset('Project')->search(
    {},
    {
        order_by => { -desc => 'id' },
        columns => [qw/id name description project_code status sitename start_date end_date developer_name/]
    }
);

my $count = $projects_rs->count;
print "Total projects found: $count\n\n";

print "=" x 120 . "\n";
printf "%-5s | %-40s | %-20s | %-15s | %-15s | %-10s\n", 
    "ID", "Name", "Code", "Status", "Sitename", "Developer";
print "=" x 120 . "\n";

while (my $project = $projects_rs->next) {
    printf "%-5s | %-40s | %-20s | %-15s | %-15s | %-10s\n",
        $project->id || 'N/A',
        substr($project->name || 'N/A', 0, 40),
        $project->project_code || 'N/A',
        $project->status || 'N/A',
        $project->sitename || 'N/A',
        $project->developer_name || 'N/A';
}

print "=" x 120 . "\n";

print "\n=== Project Details (Full) ===\n\n";

$projects_rs->reset;
while (my $project = $projects_rs->next) {
    print "-" x 80 . "\n";
    print "Project ID: " . ($project->id || 'N/A') . "\n";
    print "Name: " . ($project->name || 'N/A') . "\n";
    print "Code: " . ($project->project_code || 'N/A') . "\n";
    print "Status: " . ($project->status || 'N/A') . "\n";
    print "Sitename: " . ($project->sitename || 'N/A') . "\n";
    print "Developer: " . ($project->developer_name || 'N/A') . "\n";
    print "Start Date: " . ($project->start_date || 'N/A') . "\n";
    print "End Date: " . ($project->end_date || 'N/A') . "\n";
    print "Description: " . (substr($project->description || 'N/A', 0, 200)) . "\n";
    print "\n";
}

print "=" x 80 . "\n";
print "\nQuery complete. Total projects: $count\n";

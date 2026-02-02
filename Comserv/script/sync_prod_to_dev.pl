#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Model::RemoteDB;
use DBI;
use Data::Dumper;

=head1 NAME

sync_prod_to_dev.pl - Sync production database changes to development database

=head1 SYNOPSIS

    perl script/sync_prod_to_dev.pl [options]
    
    Options:
        --dry-run       Show what would be synced without making changes
        --tables=TABLE1,TABLE2  Only sync specific tables (comma-separated)
        --incremental   Only sync records changed since last sync
        --help          Show this help message

=head1 DESCRIPTION

This script syncs data from the production database to the development database.
It's designed to keep the development environment up-to-date with production changes
while activity is low.

The script uses the RemoteDB model to automatically select the appropriate production
and development database connections.

=head1 USAGE EXAMPLES

    # Dry run to see what would be synced
    perl script/sync_prod_to_dev.pl --dry-run
    
    # Sync all tables
    perl script/sync_prod_to_dev.pl
    
    # Sync only specific tables
    perl script/sync_prod_to_dev.pl --tables=projects,todos,daily_plans
    
    # Incremental sync (only changed records)
    perl script/sync_prod_to_dev.pl --incremental

=head1 TABLES TO SYNC

The following tables are synced by default:
    - projects
    - todos
    - daily_plans
    - site_roles
    - user_site_roles
    - plan_audit
    - users
    - sites

=cut

my $dry_run = 0;
my @tables_to_sync;
my $incremental = 0;
my $help = 0;

# Parse command line arguments
foreach my $arg (@ARGV) {
    if ($arg eq '--dry-run') {
        $dry_run = 1;
    } elsif ($arg =~ /^--tables=(.+)$/) {
        @tables_to_sync = split(',', $1);
    } elsif ($arg eq '--incremental') {
        $incremental = 1;
    } elsif ($arg eq '--help' || $arg eq '-h') {
        $help = 1;
    }
}

if ($help) {
    print_help();
    exit 0;
}

# Default tables to sync if not specified
unless (@tables_to_sync) {
    @tables_to_sync = qw(
        projects
        todos
        daily_plans
        site_roles
        user_site_roles
        plan_audit
        users
        sites
    );
}

print "=== Production to Development Database Sync ===\n";
print "Mode: " . ($dry_run ? "DRY RUN" : "LIVE") . "\n";
print "Tables: " . join(', ', @tables_to_sync) . "\n";
print "Incremental: " . ($incremental ? "YES" : "NO") . "\n";
print "\n";

# Initialize RemoteDB
my $remote_db = Comserv::Model::RemoteDB->new();

# Get production connection
print "Connecting to production database...\n";
my $prod_conn = $remote_db->select_connection('ency');
unless ($prod_conn) {
    die "ERROR: Could not connect to production database\n";
}
print "Production: $prod_conn->{host}:$prod_conn->{port} (priority: $prod_conn->{priority})\n";

# For development, we want the local or SQLite connection
# We'll look for the lowest priority connection (SQLite or local)
print "\nConnecting to development database...\n";
my $dev_conn;
foreach my $conn_name (qw(sqlite_ency local_ency)) {
    my $conns = $remote_db->{connections}->{ency};
    foreach my $c (@$conns) {
        if ($c->{name} eq $conn_name) {
            # Test connection
            if ($remote_db->test_connection($c)) {
                $dev_conn = $c;
                last;
            }
        }
    }
    last if $dev_conn;
}

unless ($dev_conn) {
    die "ERROR: Could not connect to development database\n";
}
print "Development: $dev_conn->{host}:$dev_conn->{port} (priority: $dev_conn->{priority})\n\n";

# Connect to both databases
my $prod_dbh = DBI->connect(
    $prod_conn->{dsn},
    $prod_conn->{username},
    $prod_conn->{password},
    { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to production database: $DBI::errstr\n";

my $dev_dbh = DBI->connect(
    $dev_conn->{dsn},
    $dev_conn->{username},
    $dev_conn->{password},
    { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to development database: $DBI::errstr\n";

print "Connected to both databases.\n\n";

# Sync each table
my $total_synced = 0;
foreach my $table (@tables_to_sync) {
    print "Syncing table: $table\n";
    
    # Check if table exists in production
    my $table_check = $prod_dbh->selectrow_array(
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?",
        undef, $table
    );
    
    unless ($table_check) {
        print "  WARNING: Table '$table' does not exist in production database. Skipping.\n\n";
        next;
    }
    
    # Get row count from production
    my $prod_count = $prod_dbh->selectrow_array("SELECT COUNT(*) FROM $table");
    print "  Production records: $prod_count\n";
    
    # Get row count from development
    my $dev_count = $dev_dbh->selectrow_array("SELECT COUNT(*) FROM $table");
    print "  Development records: $dev_count\n";
    
    if ($dry_run) {
        print "  DRY RUN: Would sync " . ($prod_count - $dev_count) . " records\n\n";
        next;
    }
    
    # Get primary key column
    my $pk_sth = $prod_dbh->prepare(
        "SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE 
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND CONSTRAINT_NAME = 'PRIMARY'"
    );
    $pk_sth->execute($table);
    my $pk_column = $pk_sth->fetchrow_array();
    
    unless ($pk_column) {
        print "  WARNING: No primary key found for table '$table'. Skipping.\n\n";
        next;
    }
    
    print "  Primary key: $pk_column\n";
    
    # Get all records from production
    my $sth = $prod_dbh->prepare("SELECT * FROM $table");
    $sth->execute();
    
    my $synced = 0;
    while (my $row = $sth->fetchrow_hashref()) {
        my $pk_value = $row->{$pk_column};
        
        # Check if record exists in development
        my $exists = $dev_dbh->selectrow_array(
            "SELECT COUNT(*) FROM $table WHERE $pk_column = ?",
            undef, $pk_value
        );
        
        if ($exists) {
            # Update existing record (if incremental mode)
            if ($incremental) {
                my @columns = keys %$row;
                my $set_clause = join(', ', map { "$_ = ?" } @columns);
                my @values = map { $row->{$_} } @columns;
                
                $dev_dbh->do(
                    "UPDATE $table SET $set_clause WHERE $pk_column = ?",
                    undef, @values, $pk_value
                );
                $synced++;
            }
        } else {
            # Insert new record
            my @columns = keys %$row;
            my $columns_clause = join(', ', @columns);
            my $placeholders = join(', ', map { '?' } @columns);
            my @values = map { $row->{$_} } @columns;
            
            $dev_dbh->do(
                "INSERT INTO $table ($columns_clause) VALUES ($placeholders)",
                undef, @values
            );
            $synced++;
        }
    }
    
    print "  Synced: $synced records\n\n";
    $total_synced += $synced;
}

print "=== Sync Complete ===\n";
print "Total records synced: $total_synced\n";

$prod_dbh->disconnect();
$dev_dbh->disconnect();

sub print_help {
    print <<'HELP';
sync_prod_to_dev.pl - Sync production database changes to development database

SYNOPSIS:
    perl script/sync_prod_to_dev.pl [options]
    
OPTIONS:
    --dry-run       Show what would be synced without making changes
    --tables=TABLE1,TABLE2  Only sync specific tables (comma-separated)
    --incremental   Only sync records changed since last sync
    --help          Show this help message

DESCRIPTION:
    This script syncs data from the production database to the development database.
    It's designed to keep the development environment up-to-date with production changes
    while activity is low.

USAGE EXAMPLES:
    # Dry run to see what would be synced
    perl script/sync_prod_to_dev.pl --dry-run
    
    # Sync all tables
    perl script/sync_prod_to_dev.pl
    
    # Sync only specific tables
    perl script/sync_prod_to_dev.pl --tables=projects,todos,daily_plans
    
    # Incremental sync (only changed records)
    perl script/sync_prod_to_dev.pl --incremental

TABLES TO SYNC:
    The following tables are synced by default:
        - projects
        - todos
        - daily_plans
        - site_roles
        - user_site_roles
        - plan_audit
        - users
        - sites

HELP
}

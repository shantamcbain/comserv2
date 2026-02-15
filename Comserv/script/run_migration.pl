#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Model::DBEncy;
use Comserv::Util::Logging;
use File::Slurp qw(read_file);
use Try::Tiny;
use Term::ANSIColor qw(:constants);

my $logger = Comserv::Util::Logging->instance();

print BOLD, CYAN, "\n=== Workshop System Migration Runner ===\n", RESET;
print "Migration: 002_workshop_system.sql\n";
print "Date: 2026-02-14\n\n";

my $migration_file = "$FindBin::Bin/../sql/migrations/002_workshop_system.sql";

unless (-f $migration_file) {
    print BOLD, RED, "ERROR: Migration file not found: $migration_file\n", RESET;
    exit 1;
}

print "Reading migration file: $migration_file\n";
my $sql_content = read_file($migration_file);

my @statements = split /;/, $sql_content;
@statements = grep { $_ =~ /\S/ } @statements;
@statements = grep { $_ !~ /^\s*--/ } @statements;

print "Found ", scalar(@statements), " SQL statements\n\n";

print BOLD, YELLOW, "WARNING: This will modify the database schema.\n", RESET;
print "Do you want to proceed? (yes/no): ";
my $confirm = <STDIN>;
chomp $confirm;

unless ($confirm eq 'yes') {
    print BOLD, RED, "Migration cancelled by user.\n", RESET;
    exit 0;
}

print "\n", BOLD, GREEN, "Starting migration...\n", RESET;

try {
    require Comserv;
    my $app = Comserv->new();
    
    my $schema = $app->model('DBEncy')->schema;
    my $dbh = $schema->storage->dbh;
    
    print "Connected to database: " . $schema->storage->connect_info->[0]{dsn} . "\n\n";
    
    my $executed = 0;
    my $failed = 0;
    
    foreach my $statement (@statements) {
        $statement =~ s/^\s+//;
        $statement =~ s/\s+$//;
        next unless $statement;
        
        my $preview = substr($statement, 0, 80);
        $preview =~ s/\n/ /g;
        print "Executing: $preview...\n";
        
        try {
            $dbh->do($statement);
            $executed++;
            print BOLD, GREEN, "  ✓ Success\n", RESET;
        } catch {
            $failed++;
            print BOLD, RED, "  ✗ Failed: $_\n", RESET;
            $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'run_migration',
                "Failed to execute SQL: $preview - Error: $_");
        };
    }
    
    print "\n", BOLD, CYAN, "=== Migration Summary ===\n", RESET;
    print "Total statements: ", scalar(@statements), "\n";
    print BOLD, GREEN, "Executed successfully: $executed\n", RESET;
    
    if ($failed > 0) {
        print BOLD, RED, "Failed: $failed\n", RESET;
        print "\n", BOLD, YELLOW, "Migration completed with errors. Please review the log.\n", RESET;
    } else {
        print "\n", BOLD, GREEN, "Migration completed successfully!\n", RESET;
        print "\nNext steps:\n";
        print "1. Run verification script: mysql -u <user> -p <database> < sql/migrations/002_workshop_system_verify.sql\n";
        print "2. Update DBIx::Class Result classes (Phase 1B)\n";
    }
    
} catch {
    print BOLD, RED, "\nFATAL ERROR: $_\n", RESET;
    $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'run_migration',
        "Fatal error during migration: $_");
    exit 1;
};

print "\n", BOLD, CYAN, "=== End of Migration ===\n", RESET;

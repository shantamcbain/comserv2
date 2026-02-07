#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Getopt::Long;
use DBI;
use Data::Dumper;
use Try::Tiny;
use JSON;
use Comserv::Util::Logging;
use Comserv::Util::DatabaseEnv;

my $dry_run = 0;
my $schema_only = 0;
my $tables = '';
my $anonymize = 1;
my $verbose = 0;
my $help = 0;

GetOptions(
    'dry-run'       => \$dry_run,
    'schema-only'   => \$schema_only,
    'tables=s'      => \$tables,
    'anonymize!'    => \$anonymize,
    'verbose'       => \$verbose,
    'help'          => \$help,
) or die "Error parsing command line options\n";

if ($help) {
    print_help();
    exit 0;
}

my $logging = Comserv::Util::Logging->instance;
my $db_env = Comserv::Util::DatabaseEnv->new;

print "\n=== Database Sync: Production -> Development ===\n";
print "Mode: " . ($dry_run ? "DRY RUN (no changes)" : "LIVE (applying changes)") . "\n";
print "Schema only: " . ($schema_only ? "YES" : "NO") . "\n";
print "Anonymize data: " . ($anonymize ? "YES" : "NO") . "\n";
print "Tables filter: " . ($tables ? $tables : "ALL") . "\n\n";

my $prod_conn_info = $db_env->get_environment_connection(undef, 'production', 'ency');
my $dev_conn_info = $db_env->get_environment_connection(undef, 'dev', 'ency');

unless ($prod_conn_info && $prod_conn_info->{config}) {
    die "ERROR: Production database connection not configured\n";
}

unless ($dev_conn_info && $dev_conn_info->{config}) {
    die "ERROR: Development database connection not configured\n";
}

print "Connecting to production database...\n";
my $prod_dbh = connect_to_database($prod_conn_info->{config});

print "Connecting to development database...\n";
my $dev_dbh = connect_to_database($dev_conn_info->{config});

my @selected_tables;
if ($tables) {
    @selected_tables = split(',', $tables);
    print "Syncing specific tables: " . join(', ', @selected_tables) . "\n\n";
} else {
    @selected_tables = get_all_tables($prod_dbh);
    print "Syncing all tables (" . scalar(@selected_tables) . " total)\n\n";
}

my $sync_report = {
    total_tables => scalar(@selected_tables),
    synced_tables => 0,
    schema_changes => [],
    data_changes => [],
    errors => [],
    skipped_tables => [],
};

foreach my $table (@selected_tables) {
    print "Processing table: $table\n";
    
    if (should_skip_table($table)) {
        print "  SKIPPED (sensitive table)\n";
        push @{$sync_report->{skipped_tables}}, $table;
        next;
    }
    
    try {
        sync_table_schema($prod_dbh, $dev_dbh, $table, $sync_report);
        
        unless ($schema_only) {
            sync_table_data($prod_dbh, $dev_dbh, $table, $anonymize, $sync_report);
        }
        
        $sync_report->{synced_tables}++;
        print "  ✓ SUCCESS\n";
        
    } catch {
        my $error = $_;
        print "  ✗ ERROR: $error\n";
        push @{$sync_report->{errors}}, { table => $table, error => $error };
    };
    
    print "\n";
}

$prod_dbh->disconnect;
$dev_dbh->disconnect;

print_summary_report($sync_report);

sub connect_to_database {
    my ($config) = @_;
    
    my $dsn = "DBI:mysql:database=$config->{database};host=$config->{host};port=$config->{port}";
    my $dbh = DBI->connect(
        $dsn,
        $config->{username},
        $config->{password},
        {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            mysql_enable_utf8 => 1,
        }
    ) or die "Could not connect to database: $DBI::errstr\n";
    
    return $dbh;
}

sub get_all_tables {
    my ($dbh) = @_;
    
    my $sth = $dbh->prepare("SHOW TABLES");
    $sth->execute();
    
    my @tables;
    while (my ($table) = $sth->fetchrow_array) {
        push @tables, $table;
    }
    
    return @tables;
}

sub should_skip_table {
    my ($table) = @_;
    
    my @sensitive_tables = qw(
        api_tokens
        user_sessions
        password_reset_tokens
        oauth_tokens
    );
    
    return grep { $_ eq $table } @sensitive_tables;
}

sub sync_table_schema {
    my ($prod_dbh, $dev_dbh, $table, $report) = @_;
    
    my $prod_schema = get_table_schema($prod_dbh, $table);
    my $dev_schema = get_table_schema($dev_dbh, $table);
    
    unless ($dev_schema) {
        print "  Table does not exist in dev, creating...\n";
        create_table_from_production($prod_dbh, $dev_dbh, $table, $report);
        return;
    }
    
    my @schema_diffs = compare_schemas($prod_schema, $dev_schema);
    
    if (@schema_diffs) {
        print "  Found " . scalar(@schema_diffs) . " schema differences\n";
        
        foreach my $diff (@schema_diffs) {
            print "    - $diff->{type}: $diff->{description}\n";
            push @{$report->{schema_changes}}, {
                table => $table,
                change => $diff
            };
            
            unless ($dry_run) {
                apply_schema_change($dev_dbh, $table, $diff);
            }
        }
    } else {
        print "  Schema is in sync\n";
    }
}

sub get_table_schema {
    my ($dbh, $table) = @_;
    
    my $sth = eval { $dbh->prepare("DESCRIBE $table") };
    return undef unless $sth;
    
    $sth->execute();
    
    my @columns;
    while (my $row = $sth->fetchrow_hashref) {
        push @columns, {
            field => $row->{Field},
            type => $row->{Type},
            null => $row->{Null},
            key => $row->{Key},
            default => $row->{Default},
            extra => $row->{Extra},
        };
    }
    
    return \@columns;
}

sub create_table_from_production {
    my ($prod_dbh, $dev_dbh, $table, $report) = @_;
    
    my $sth = $prod_dbh->prepare("SHOW CREATE TABLE $table");
    $sth->execute();
    my ($table_name, $create_sql) = $sth->fetchrow_array;
    
    push @{$report->{schema_changes}}, {
        table => $table,
        change => { type => 'create_table', description => "Created table from production" }
    };
    
    unless ($dry_run) {
        $dev_dbh->do($create_sql);
        print "  Created table in dev database\n";
    } else {
        print "  [DRY RUN] Would create table: $table\n";
    }
}

sub compare_schemas {
    my ($prod_schema, $dev_schema) = @_;
    
    my @diffs;
    my %dev_fields = map { $_->{field} => $_ } @$dev_schema;
    my %prod_fields = map { $_->{field} => $_ } @$prod_schema;
    
    foreach my $prod_col (@$prod_schema) {
        my $field = $prod_col->{field};
        
        unless (exists $dev_fields{$field}) {
            push @diffs, {
                type => 'add_column',
                field => $field,
                description => "Add column '$field' ($prod_col->{type})",
                column_def => $prod_col,
            };
        } else {
            my $dev_col = $dev_fields{$field};
            if ($prod_col->{type} ne $dev_col->{type}) {
                push @diffs, {
                    type => 'modify_column',
                    field => $field,
                    description => "Modify column '$field' type from '$dev_col->{type}' to '$prod_col->{type}'",
                    column_def => $prod_col,
                };
            }
        }
    }
    
    foreach my $dev_col (@$dev_schema) {
        my $field = $dev_col->{field};
        
        unless (exists $prod_fields{$field}) {
            push @diffs, {
                type => 'remove_column',
                field => $field,
                description => "Remove column '$field' (not in production)",
            };
        }
    }
    
    return @diffs;
}

sub apply_schema_change {
    my ($dbh, $table, $diff) = @_;
    
    if ($diff->{type} eq 'add_column') {
        my $col = $diff->{column_def};
        my $sql = "ALTER TABLE $table ADD COLUMN `$col->{field}` $col->{type}";
        $sql .= " NOT NULL" if $col->{null} eq 'NO';
        $sql .= " DEFAULT " . $dbh->quote($col->{default}) if defined $col->{default};
        $sql .= " $col->{extra}" if $col->{extra};
        
        $dbh->do($sql);
        print "    Applied: $sql\n" if $verbose;
        
    } elsif ($diff->{type} eq 'modify_column') {
        my $col = $diff->{column_def};
        my $sql = "ALTER TABLE $table MODIFY COLUMN `$col->{field}` $col->{type}";
        $sql .= " NOT NULL" if $col->{null} eq 'NO';
        $sql .= " DEFAULT " . $dbh->quote($col->{default}) if defined $col->{default};
        $sql .= " $col->{extra}" if $col->{extra};
        
        $dbh->do($sql);
        print "    Applied: $sql\n" if $verbose;
        
    } elsif ($diff->{type} eq 'remove_column') {
        my $sql = "ALTER TABLE $table DROP COLUMN `$diff->{field}`";
        
        print "    [WARNING] Skipping column removal: $sql\n";
    }
}

sub sync_table_data {
    my ($prod_dbh, $dev_dbh, $table, $anonymize, $report) = @_;
    
    my $count_sth = $prod_dbh->prepare("SELECT COUNT(*) FROM $table");
    $count_sth->execute();
    my ($row_count) = $count_sth->fetchrow_array;
    
    if ($row_count == 0) {
        print "  No data to sync (table is empty)\n";
        return;
    }
    
    if ($row_count > 10000) {
        print "  [NOTICE] Large table ($row_count rows) - skipping data sync (use --tables option for specific sync)\n";
        return;
    }
    
    print "  Syncing $row_count rows...\n";
    
    unless ($dry_run) {
        $dev_dbh->do("TRUNCATE TABLE $table");
    }
    
    my $select_sth = $prod_dbh->prepare("SELECT * FROM $table");
    $select_sth->execute();
    
    my $synced_rows = 0;
    
    while (my $row = $select_sth->fetchrow_hashref) {
        if ($anonymize) {
            anonymize_row($table, $row);
        }
        
        unless ($dry_run) {
            insert_row($dev_dbh, $table, $row);
        }
        
        $synced_rows++;
    }
    
    push @{$report->{data_changes}}, {
        table => $table,
        rows_synced => $synced_rows
    };
    
    print "  Synced $synced_rows rows\n";
}

sub anonymize_row {
    my ($table, $row) = @_;
    
    if (exists $row->{email}) {
        $row->{email} = anonymize_email($row->{email});
    }
    
    if (exists $row->{password}) {
        $row->{password} = 'anonymized_password_hash';
    }
    
    if (exists $row->{first_name}) {
        $row->{first_name} = 'Test';
    }
    
    if (exists $row->{last_name}) {
        $row->{last_name} = 'User' . int(rand(1000));
    }
    
    if (exists $row->{phone}) {
        $row->{phone} = '555-0100';
    }
}

sub anonymize_email {
    my ($email) = @_;
    
    if ($email =~ /^(.+)@(.+)$/) {
        my $prefix = substr($1, 0, 3);
        return "${prefix}_test\@example.com";
    }
    
    return 'test@example.com';
}

sub insert_row {
    my ($dbh, $table, $row) = @_;
    
    my @fields = keys %$row;
    my @values = map { $row->{$_} } @fields;
    
    my $fields_str = join(', ', map { "`$_`" } @fields);
    my $placeholders = join(', ', ('?') x scalar(@fields));
    
    my $sql = "INSERT INTO $table ($fields_str) VALUES ($placeholders)";
    my $sth = $dbh->prepare($sql);
    $sth->execute(@values);
}

sub print_summary_report {
    my ($report) = @_;
    
    print "\n" . ("=" x 60) . "\n";
    print "SYNC SUMMARY REPORT\n";
    print ("=" x 60) . "\n\n";
    
    print "Total tables processed: $report->{total_tables}\n";
    print "Successfully synced: $report->{synced_tables}\n";
    print "Skipped (sensitive): " . scalar(@{$report->{skipped_tables}}) . "\n";
    print "Errors: " . scalar(@{$report->{errors}}) . "\n\n";
    
    if (@{$report->{schema_changes}}) {
        print "Schema changes: " . scalar(@{$report->{schema_changes}}) . "\n";
        foreach my $change (@{$report->{schema_changes}}) {
            print "  - $change->{table}: $change->{change}{description}\n";
        }
        print "\n";
    }
    
    if (@{$report->{data_changes}}) {
        print "Data synced:\n";
        foreach my $data (@{$report->{data_changes}}) {
            print "  - $data->{table}: $data->{rows_synced} rows\n";
        }
        print "\n";
    }
    
    if (@{$report->{errors}}) {
        print "ERRORS:\n";
        foreach my $error (@{$report->{errors}}) {
            print "  - $error->{table}: $error->{error}\n";
        }
        print "\n";
    }
    
    if ($dry_run) {
        print "\n[DRY RUN MODE] No changes were applied to the development database.\n";
        print "Run without --dry-run to apply changes.\n";
    }
    
    print "\n";
}

sub print_help {
    print <<'HELP';
Usage: sync_dev_from_production.pl [OPTIONS]

Sync development database schema and data from production database.

Options:
  --dry-run         Preview changes without applying them
  --schema-only     Only sync schema structure (no data copy)
  --tables=LIST     Comma-separated list of specific tables to sync
  --anonymize       Anonymize sensitive data (email, names, phone) [default: on]
  --no-anonymize    Disable data anonymization
  --verbose         Show detailed SQL statements
  --help            Show this help message

Examples:
  # Dry run to see what would change
  perl sync_dev_from_production.pl --dry-run

  # Sync schema only (no data)
  perl sync_dev_from_production.pl --schema-only

  # Sync specific tables with data
  perl sync_dev_from_production.pl --tables=users,projects,todos

  # Sync without anonymization (use with caution!)
  perl sync_dev_from_production.pl --no-anonymize

HELP
}

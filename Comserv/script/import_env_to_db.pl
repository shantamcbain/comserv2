#!/usr/bin/perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Comserv::Util::EnvFileManager;
use Comserv::Schema::Ency;
use JSON;
use Getopt::Long;
use Pod::Usage;

my $help = 0;
my $env_file = '.env';
my $dry_run = 0;
my $force = 0;

GetOptions(
    'help|h' => \$help,
    'env=s' => \$env_file,
    'dry-run' => \$dry_run,
    'force' => \$force,
) or pod2usage(2);

pod2usage(1) if $help;

unless (-f $env_file) {
    die "Error: .env file not found at $env_file\n";
}

my $env_mgr = Comserv::Util::EnvFileManager->new(env_path => $env_file);
my $env_vars = $env_mgr->read_env_file();
my $secrets = $env_mgr->detect_secrets($env_vars);

print "=== Comserv Environment Variables Import ===\n\n";
print "Source: $env_file\n";
print "Total variables: " . scalar(keys %$env_vars) . "\n";
print "Detected secrets: " . grep { $secrets->{$_} } keys %$env_vars . "\n";
print "Dry run: " . ($dry_run ? 'Yes' : 'No') . "\n";
print "\n";

unless ($dry_run || $force) {
    print "This will import all variables from $env_file into the database.\n";
    print "Existing variables with the same key will be skipped.\n";
    print "Press ENTER to continue or Ctrl+C to cancel...\n";
    <STDIN>;
}

my $schema = get_schema();

my $imported = 0;
my $skipped = 0;
my $failed = 0;

foreach my $key (sort keys %$env_vars) {
    my $value = $env_vars->{$key};
    
    printf "Processing: %-30s ... ", $key;
    
    my $existing = $schema->resultset('EnvVariable')->find({ key => $key });
    if ($existing) {
        print "SKIPPED (already exists)\n";
        $skipped++;
        next;
    }
    
    my $is_secret = $secrets->{$key} ? 1 : 0;
    
    unless ($dry_run) {
        try {
            $schema->resultset('EnvVariable')->create({
                key => $key,
                value => $value,
                var_type => 'string',
                is_secret => $is_secret,
                is_editable => 1,
                editable_by_roles => JSON::to_json(['admin']),
                description => "Imported from .env file",
            });
            print "OK" . ($is_secret ? " (secret)" : "") . "\n";
            $imported++;
        } catch {
            print "FAILED: $_\n";
            $failed++;
        };
    } else {
        print "OK (dry run)" . ($is_secret ? " (secret)" : "") . "\n";
        $imported++;
    }
}

print "\n=== Import Summary ===\n";
print "Imported: $imported\n";
print "Skipped: $skipped\n";
print "Failed: $failed\n";

if ($dry_run) {
    print "\nNo changes applied (dry run mode)\n";
}

exit($failed > 0 ? 1 : 0);

sub get_schema {
    require DBIx::Class::Schema::Loader qw(make_schema_at);
    
    my $db_config = {
        dsn => $ENV{COMSERV_DSN} || 'DBI:mysql:comserv',
        user => $ENV{COMSERV_DB_USER} || 'root',
        password => $ENV{COMSERV_DB_PASS} || '',
    };
    
    my $schema = Comserv::Schema::Ency->connect(
        $db_config->{dsn},
        $db_config->{user},
        $db_config->{password},
    );
    
    return $schema;
}

__END__

=head1 NAME

import_env_to_db.pl - Import environment variables from .env to database

=head1 SYNOPSIS

import_env_to_db.pl [options]

Options:
  --env FILE        Path to .env file (default: .env)
  --dry-run         Preview changes without applying
  --force           Skip confirmation prompt
  --help            Show this help message

=head1 DESCRIPTION

Imports environment variables from a .env file into the Comserv database.
Automatically detects secrets based on variable name patterns.

=cut

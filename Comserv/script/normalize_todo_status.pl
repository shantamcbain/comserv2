#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Getopt::Long qw(GetOptions);

use Comserv::Model::RemoteDB;
use Comserv::Model::Schema::Ency;

my $dry_run = 1;
my $force   = 0;
my $help    = 0;

GetOptions(
    'dry-run!'  => \$dry_run,
    'force'     => \$force,
    'help|h'    => \$help,
) or do { print "Usage: $0 [--no-dry-run --force]\n"; exit 1 };

if ($help) {
    print <<'USAGE';
normalize_todo_status.pl — Converts legacy string status values in the todo
table to canonical integers (1=NEW 2=IN PROGRESS 3=DONE 4=CANCELLED).

Options:
  --no-dry-run   Actually write changes (default: dry-run only)
  --force        Required together with --no-dry-run to confirm
  --help         This message
USAGE
    exit 0;
}

if (!$dry_run && !$force) {
    print "Add --force to actually write changes, or run without --no-dry-run for a preview.\n";
    exit 1;
}

sub normalize {
    my ($val) = @_;
    return undef unless defined $val;
    return $val + 0 if $val =~ /^\d+$/;
    my $lc = lc($val);
    $lc =~ s/[-_ ]+//g;
    return 1 if $lc eq 'new';
    return 2 if $lc =~ /^in?progress$|^inprog$|^inprocess$/;
    return 3 if $lc =~ /^done$|^completed$|^complete$/;
    return 4 if $lc =~ /^cancel/;
    return undef;
}

use JSON qw(decode_json);
use File::Slurp qw(read_file);

my $secrets_file = "$ENV{HOME}/.comserv/secrets/dbi/zerotier_ency.json";
my $secrets = decode_json(read_file($secrets_file));
my ($conn_name) = keys %$secrets;
my $conn = $secrets->{$conn_name};

my $dsn = sprintf("dbi:MariaDB:database=%s;host=%s;port=%s",
    $conn->{database}, $conn->{host}, $conn->{port} || 3306);

my $schema = Comserv::Model::Schema::Ency->connect(
    $dsn, $conn->{username}, $conn->{password},
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 }
);

my $rs = $schema->resultset('Todo')->search(
    { status => { '!=' => undef } },
    { columns => [qw(record_id status)] }
);

my ($fixed, $skipped, $unknown) = (0, 0, 0);

while (my $todo = $rs->next) {
    my $raw = $todo->get_column('status');
    next unless defined $raw;
    next if $raw =~ /^\d+$/;

    my $norm = normalize($raw);
    if (!defined $norm) {
        printf "  record_id=%-6d  status='%s'  → UNKNOWN (skipped)\n", $todo->record_id, $raw;
        $unknown++;
        next;
    }

    printf "  record_id=%-6d  status='%s'  → %d%s\n",
        $todo->record_id, $raw, $norm, ($dry_run ? ' [DRY RUN]' : '');

    unless ($dry_run) {
        $todo->update({ status => $norm });
    }
    $fixed++;
}

printf "\nDone. %d to fix, %d skipped (already numeric), %d unknown.\n",
    $fixed, $skipped, $unknown;
print "Re-run with --no-dry-run --force to apply.\n" if $dry_run;

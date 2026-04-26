#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

use Comserv::Model::Schema::Ency;
use Comserv::Util::PointSystem;

my $host     = $ENV{DB_HOST}  || '192.168.1.198';
my $port     = $ENV{DB_PORT}  || 3306;
my $dbname   = $ENV{DB_NAME}  || 'ency';
my $user     = $ENV{DB_USER}  || 'shanta_forager';
my $pass     = $ENV{DB_PASS}  || '';
my $dry_run  = 0;
my $limit    = 0;
my $help     = 0;

GetOptions(
    'host=s'     => \$host,
    'port=i'     => \$port,
    'database=s' => \$dbname,
    'user=s'     => \$user,
    'password=s' => \$pass,
    'dry-run'    => \$dry_run,
    'limit=i'    => \$limit,
    'help|h'     => \$help,
) or die "Usage: $0 [options]\n";

if ($help) {
    print <<'HELP';
back_credit_logs.pl — Back-credit historical closed log entries with points.

Finds all log rows where status=3 (DONE) and points_processed=0,
then calls PointSystem->bill_time_log() for each one.

Usage:
  perl back_credit_logs.pl [options]

Options:
  --dry-run          Show what would happen without writing anything
  --limit N          Process at most N log entries (0 = all)
  --host HOST        DB host (default: 192.168.1.198)
  --port PORT        DB port (default: 3306)
  --database DB      Database name (default: ency)
  --user USER        DB username
  --password PASS    DB password
  --help             Show this help

Environment variables DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS are
also respected as defaults.

HELP
    exit 0;
}

my $dsn = "dbi:MariaDB:database=$dbname;host=$host;port=$port";
my $schema = Comserv::Model::Schema::Ency->connect(
    $dsn, $user, $pass,
    { RaiseError => 1, PrintError => 0 }
);

print "Back-credit historical log entries" . ($dry_run ? " [DRY RUN]" : "") . "\n";
print "DB: $dbname\@$host:$port\n\n";

my $search = { status => 3, points_processed => 0 };
my $rs = $schema->resultset('Log')->search(
    $search,
    {
        order_by => { -asc => 'record_id' },
        ($limit ? (rows => $limit) : ()),
    }
);

my $total    = $rs->count;
my $credited = 0;
my $skipped  = 0;
my $errors   = 0;

print "Found $total unprocessed closed log entries.\n\n";

while (my $log = $rs->next) {
    my $id       = $log->record_id;
    my $username = $log->username // '(none)';
    my $time_str = $log->time     // '00:00:00';
    my $abstract = $log->abstract // '';

    printf "Log #%d  user=%-15s  time=%s  %s\n",
        $id, $username, $time_str, substr($abstract, 0, 50);

    if ($dry_run) {
        print "  [dry-run] would call bill_time_log()\n";
        $skipped++;
        next;
    }

    my $ps = Comserv::Util::PointSystem->new_from_schema(schema => $schema);

    my ($ok, $err) = eval { $ps->bill_time_log($log) };
    if ($@) {
        print "  ERROR: $@\n";
        $errors++;
    } elsif ($ok) {
        print "  Credited.\n";
        $credited++;
    } else {
        print "  Skipped: $err\n";
        $skipped++;
    }
}

print "\n";
printf "Done. Credited: %d  Skipped: %d  Errors: %d  (of %d total)\n",
    $credited, $skipped, $errors, $total;

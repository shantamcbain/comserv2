#!/usr/bin/env perl
#
# backfill_system_log_dedupe.pl
# -----------------------------------------------------------------------------
# One-time maintenance script to collapse existing duplicate rows in system_log
# using the SAME coalescing key the live write path now uses:
#     (level, subroutine, message, DATE(timestamp))
#
# For every group of identical-key rows, ONE row is kept (the earliest id) and
# its occurrence_count / first_seen / last_seen are set from the whole group.
# The remaining duplicate rows in the group are deleted.
#
# This is the catch-up for the write-time dedupe added in Logging.pm: it stops
# FUTURE growth, but the ~1.28M historical rows are still un-deduped. Running
# this once collapses them, drastically shrinking the table.
#
# SAFETY:
#   * Default mode is DRY-RUN: it only reports how many rows WOULD be removed.
#   * Pass --apply to actually delete.
#   * Pass --optimize to also OPTIMIZE TABLE afterwards (reclaims disk; locks
#     the table briefly — only use on a calm DB with no writers).
#   * Connection is resolved through Comserv::Model::RemoteDB (same as the app),
#     so it targets the active PRIMARY Ency. Override with --host/--port/etc.
#
# Usage:
#   perl script/backfill_system_log_dedupe.pl            # dry-run, print stats
#   perl script/backfill_system_log_dedupe.pl --apply    # coalesce + delete
#   perl script/backfill_system_log_dedupe.pl --apply --optimize

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use DBI;
use Comserv::Model::RemoteDB;

my %opt = ( apply => 0, optimize => 0, host => undef, port => undef, db => undef, user => undef, pass => undef );
GetOptions(
    'apply'     => \$opt{apply},
    'optimize'  => \$opt{optimize},
    'host=s'    => \$opt{host},
    'port=s'    => \$opt{port},
    'db=s'      => \$opt{db},
    'user=s'    => \$opt{user},
    'pass=s'    => \$opt{pass},
) or die "bad args\n";

# --- Resolve connection (mirrors the app's RemoteDB selection) ---------------
my ($dsn, $user, $pass);
if ($opt{host}) {
    $dsn  = "dbi:MariaDB:database=" . ($opt{db}//'ency') . ";host=$opt{host};port=" . ($opt{port}//3306);
    $user = $opt{user} // 'shanta_forager';
    $pass = $opt{pass} // '';
}
else {
    my $rd  = Comserv::Model::RemoteDB->new;
    my $cfg = $rd->get_connection_info('ency')->{config};
    $dsn  = "dbi:MariaDB:database=$cfg->{database};host=$cfg->{host};port=$cfg->{port}";
    $user = $cfg->{username};
    $pass = $cfg->{password};
}
my $dbh = DBI->connect($dsn, $user, $pass,
    { RaiseError => 0, PrintError => 1, AutoCommit => 1, mariadb_connect_timeout => 10 });
die "connect failed: " . $DBI::errstr . "\n" unless $dbh;
$dbh->do('SET SESSION innodb_lock_wait_timeout = 120');

my $mode = $opt{apply} ? 'APPLY' : 'DRY-RUN';
print "[$mode] Connected to $dsn\n";

# --- Baseline ----------------------------------------------------------------
my ($before) = $dbh->selectrow_array("SELECT COUNT(*) FROM system_log");
print "Rows before: ", $before, "\n";

# Distinct groups and how many rows they'd collapse to.
my $stats = $dbh->selectrow_hashref(
    "SELECT COUNT(*) AS groups,
            SUM(cnt) AS total_rows,
            SUM(cnt) - COUNT(*) AS removable
       FROM (SELECT COUNT(*) AS cnt
               FROM system_log
              GROUP BY level, subroutine, message, DATE(timestamp)) g"
);
my $groups    = $stats->{groups}    // 0;
my $total_rows= $stats->{total_rows}// 0;
my $removable = $stats->{removable} // 0;
printf "Distinct (level,subroutine,message,day) groups: %d\n", $groups;
printf "Rows that would remain after coalesce:        %d\n", $groups;
printf "Rows that would be DELETED:                   %d\n", $removable;

if (!$opt{apply}) {
    print "\n[DRY-RUN] No changes made. Re-run with --apply to perform the coalesce.\n";
    $dbh->disconnect;
    exit 0;
}

# --- APPLY: build keepers temp table ----------------------------------------
print "\n[APPLY] Building keeper set (full scan + group by)...\n";
$dbh->do("DROP TEMPORARY TABLE IF EXISTS sl_keep");
$dbh->do(
    "CREATE TEMPORARY TABLE sl_keep (
        keep_id   BIGINT,
        cnt       BIGINT,
        fs        DATETIME,
        ls        DATETIME,
        level     VARCHAR(20),
        subroutine VARCHAR(255),
        message   TEXT,
        d         DATE,
        KEY (keep_id),
        KEY (level, subroutine(180), d)
     )"
);
$dbh->do(
    "INSERT INTO sl_keep (keep_id, cnt, fs, ls, level, subroutine, message, d)
     SELECT MIN(id) AS keep_id, COUNT(*) AS cnt,
            MIN(timestamp) AS fs, MAX(timestamp) AS ls,
            level, subroutine, message, DATE(timestamp) AS d
       FROM system_log
      GROUP BY level, subroutine, message, DATE(timestamp)"
);
my ($keepers) = $dbh->selectrow_array("SELECT COUNT(*) FROM sl_keep");
print "Keeper rows: $keepers\n";

# --- Update keepers with aggregated counts/times ----------------------------
print "[APPLY] Updating keeper rows (occurrence_count / first_seen / last_seen)...\n";
my $u = $dbh->do(
    "UPDATE system_log sl JOIN sl_keep k ON sl.id = k.keep_id
        SET sl.occurrence_count = k.cnt,
            sl.first_seen       = k.fs,
            sl.last_seen        = k.ls"
);
print "  keepers updated: ", ($u // 0), "\n";

# --- Delete duplicates in id-range chunks (bound each statement) -------------
print "[APPLY] Deleting duplicate rows (chunked by id range)...\n";
my ($min_id, $max_id) = $dbh->selectrow_array("SELECT MIN(id), MAX(id) FROM system_log");
$min_id //= 0; $max_id //= 0;
my $CHUNK = 200_000;
my $deleted = 0;
for (my $lo = $min_id; $lo <= $max_id; $lo += $CHUNK) {
    my $hi = $lo + $CHUNK - 1;
    my $d = $dbh->do(
        "DELETE sl FROM system_log sl
           LEFT JOIN sl_keep k ON sl.id = k.keep_id
          WHERE k.keep_id IS NULL
            AND sl.id BETWEEN ? AND ?", undef, $lo, $hi);
    $deleted += ($d // 0);
    print "  id $lo-$hi: deleted ", ($d // 0), " (running: $deleted)\n";
}
print "Total deleted: $deleted\n";

# --- Optimize (optional) -----------------------------------------------------
if ($opt{optimize}) {
    print "[APPLY] OPTIMIZE TABLE system_log (reclaims disk; brief lock)...\n";
    $dbh->do("OPTIMIZE TABLE system_log");
}

my ($after) = $dbh->selectrow_array("SELECT COUNT(*) FROM system_log");
print "Rows after:  $after\n";
printf "Reduction:   %d rows (%.1f%%)\n",
    ($before - $after), ($before ? (($before-$after)/$before*100) : 0);

$dbh->disconnect;
print "DONE\n";

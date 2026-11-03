#!/usr/bin/env perl
# COMSERV_NO_HEALTH_LOG=1 must only silence health/heartbeat noise BELOW WARN; WARN+ always reach system_log.
# Also: LoginThrottle (writes system_log rows directly) does not depend on that switch, and the
# fork-safe hooks in Logging.pm are still present. In-memory SQLite + fake $c; log files go to a temp dir.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use lib "$FindBin::Bin/../lib";

BEGIN {
    for my $m (qw(DBD::SQLite SQL::Translator)) { eval "require $m; 1" or plan skip_all => "$m not installed"; }
    my $d = tempdir(CLEANUP => 1);
    $ENV{COMSERV_LOG_DIR} = $d; $ENV{DISABLE_FILE_LOGGING} = 1; $ENV{COMSERV_DISABLE_FILE_LOG} = 1;
    $ENV{EMAIL_NOTIFICATIONS_DISABLED} = 1; $ENV{COMSERV_LOG_MIN_LEVEL} = 'CRITICAL';
}
use Comserv::Util::Logging;
use Comserv::Model::Schema::Ency::Result::SystemLog;

{ package T::Schema; use base 'DBIx::Class::Schema'; }
T::Schema->register_class(SystemLog => 'Comserv::Model::Schema::Ency::Result::SystemLog');
my $schema = T::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 });
$schema->deploy;

{
    package FakeDbh; sub new { bless {}, shift } sub do { 0 }          # SET SESSION / coalescing UPDATE: nothing matched
    package FakeStorage; sub new { bless {}, shift } sub dbh { FakeDbh->new }
    package FakeModel;
    sub new { bless { s => $_[1] }, $_[0] } sub storage { FakeStorage->new } sub resultset { $_[0]{s}->resultset($_[1]) }
    package FakeCtx;
    use Scalar::Util;
    sub new { bless { s => $_[1], stash => { SiteName => 'CSC' }, session => {} }, $_[0] }
    sub model { FakeModel->new($_[0]{s}) } sub stash { $_[0]{stash} } sub session { $_[0]{session} }
}
my $log = Comserv::Util::Logging->instance;
sub rows { $schema->resultset('SystemLog')->search({}, { order_by => 'id' })->count }
sub try_log {
    my ($level, $sub, $msg, %o) = @_;
    my $n = rows();
    local $ENV{COMSERV_NO_HEALTH_LOG} = $o{no_health} ? '1' : '';
    local $Comserv::Util::Logging::DB_LOG_MIN_LEVEL = $o{db_min} || 'WARN';
    $log->log_with_details(FakeCtx->new($schema), $level, __FILE__, __LINE__, $sub, $msg);
    return rows() - $n;
}

is(try_log('warn',  'do_login',  'ordinary warning'),                       1, 'baseline: WARN reaches system_log');
is(try_log('warn',  'do_login',  'ordinary warning 2', no_health => 1),     1, 'NO_HEALTH_LOG=1: ordinary WARN still logged');
is(try_log('warn',  'run',       'hardware monitor heartbeat late', no_health => 1), 1, 'NO_HEALTH_LOG=1: WARN about health/heartbeat still logged');
is(try_log('warn',  'watchdog',  'node down', no_health => 1),              1, 'NO_HEALTH_LOG=1: WARN from watchdog still logged');
is(try_log('info',  'health_eval', 'health check ok',  no_health => 1, db_min => 'INFO'), 0, 'NO_HEALTH_LOG=1: INFO health noise suppressed');
is(try_log('info',  'heartbeat', 'beat',               no_health => 1, db_min => 'INFO'), 0, 'NO_HEALTH_LOG=1: INFO heartbeat noise suppressed');
is(try_log('info',  'do_login',  'login ok',           no_health => 1, db_min => 'INFO'), 1, 'NO_HEALTH_LOG=1: non-health INFO still logged when DB level allows');
is(try_log('info',  'health_eval', 'health check ok',  db_min => 'INFO'), 1, 'switch off: health INFO logged when DB level allows');

# ---- LoginThrottle writes system_log directly: unaffected by the switch -------------------
{
    my $src = do { local (@ARGV, $/) = ("$FindBin::Bin/../lib/Comserv/Util/LoginThrottle.pm"); <> };
    SKIP: {
        skip 'LoginThrottle.pm not present', 2 unless length $src;
        unlike($src, qr/NO_HEALTH_LOG|log_with_details/, 'LoginThrottle does not go through log_with_details / NO_HEALTH_LOG');
        like($src, qr/SystemLog|system_log/, 'LoginThrottle stores its rows in system_log directly');
    }
}
# ---- fork-safe hooks kept ------------------------------------------------------------------
{
    my $src = do { local (@ARGV, $/) = ("$FindBin::Bin/../lib/Comserv/Util/Logging.pm"); <> };
    like($src, qr/ForkSafe::child_prepare/, 'ForkSafe child_prepare hook still in Logging.pm');
    like($src, qr/ForkSafe::child_exit/,    'ForkSafe child_exit hook still in Logging.pm');
}
done_testing;

package Comserv::Util::DbReadiness;
use strict;
use warnings;
use Time::HiRes ();

# Database readiness for /health and startup (Oct 31 2026 outage: production1
# booted before MariaDB was reachable, fell back to an empty SQLite file and
# /health still answered 200, so HAProxy kept routing traffic to it).
#
#   is_production()            CATALYST_ENV (or ENVIRONMENT) is production/staging.
#                              Those environments must never fall back to SQLite.
#   settings($app_config)      <DBReadiness> block from comserv.conf with defaults.
#   wait_for($code, %opt)      retry $code with backoff until true or timeout.
#   check($dbh, %opt)          real (non-SQLite) DB connected + core tables exist;
#                              result cached for cache_s seconds per process.

our @CORE_TABLES = qw(page internal_links_tb users sites);
my %DEFAULTS = (startup_wait_s => 120, health_cache_s => 5, core_tables => join(',', @CORE_TABLES));

sub is_production {
    my ($class, %env) = @_;
    my $e = exists $env{env} ? $env{env}
          : ($ENV{CATALYST_ENV} // $ENV{ENVIRONMENT} // '');
    return (defined $e && $e =~ /^(production|staging)$/i) ? 1 : 0;
}

sub settings {
    my ($class, $cfg) = @_;
    my $blk = (ref $cfg eq 'HASH' && ref $cfg->{DBReadiness} eq 'HASH') ? $cfg->{DBReadiness} : {};
    my %s = (%DEFAULTS, map { defined $blk->{$_} ? ($_ => $blk->{$_}) : () } keys %DEFAULTS);
    $s{core_tables} = [ grep { length } split /\s*,\s*/, $s{core_tables} ];
    return \%s;
}

# Exponential backoff 1,2,4,8,15,15... seconds until $code returns true or
# $timeout seconds pass. Returns the true value or undef. $sleep is injectable.
sub wait_for {
    my ($class, $code, %opt) = @_;
    my $timeout = $opt{timeout} // 120;
    my $sleep   = $opt{sleep} || \&Time::HiRes::sleep;
    my $now     = $opt{now}   || \&Time::HiRes::time;
    my $start   = $now->();
    my $delay   = 1;
    my $attempt = 0;
    while (1) {
        $attempt++;
        my $r = eval { $code->($attempt) };
        return $r if $r;
        my $left = $timeout - ($now->() - $start);
        return undef if $left <= 0;
        $opt{on_retry}->($attempt, $@, $delay) if $opt{on_retry};
        $sleep->($delay < $left ? $delay : $left);
        $delay = $delay * 2 > 15 ? 15 : $delay * 2;
    }
}

my %cache;    # pid-keyed so a forked worker never trusts its parent's result
sub _reset_cache { %cache = () }

sub check {
    my ($class, $dbh, %opt) = @_;
    my $ttl    = $opt{cache_s} // 5;
    my @tables = @{ $opt{tables} || \@CORE_TABLES };
    my $now    = time;
    my $c = $cache{$$};
    return { %{ $c->{res} } } if $c && $now - $c->{at} < $ttl;

    my %res = (ok => 0);
    eval {
        die "no database handle\n" unless $dbh;
        my $driver = $dbh->{Driver} ? $dbh->{Driver}{Name} : '';
        $res{driver} = $driver;
        die "SQLite fallback is not a real database\n" if $driver =~ /SQLite/i;
        die "ping failed\n" unless $dbh->ping;
        my $have = $dbh->selectcol_arrayref(
            'SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()');
        my %have = map { lc($_) => 1 } @$have;
        my @missing = grep { !$have{lc $_} } @tables;
        die 'missing tables: ' . join(',', @missing) . "\n" if @missing;
        $res{ok} = 1;
        1;
    } or do { ($res{error} = $@ || 'unknown') =~ s/\s+$//; };
    $cache{$$} = { at => $now, res => \%res };
    return { %res };
}

1;

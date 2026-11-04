use strict; use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::DbReadiness;
my $R = 'Comserv::Util::DbReadiness';

# --- production detection
ok  $R->is_production(env => 'production'), 'production';
ok  $R->is_production(env => 'staging'),    'staging counts as production';
ok !$R->is_production(env => 'development'),'development keeps SQLite fallback';
ok !$R->is_production(env => ''),           'unset = dev';

# --- settings
my $s = $R->settings({});
is $s->{startup_wait_s}, 120, 'default wait 120s';
is_deeply $s->{core_tables}, [qw(page internal_links_tb users sites)], 'default core tables';
$s = $R->settings({ DBReadiness => { startup_wait_s => 30, core_tables => 'page, users' } });
is $s->{startup_wait_s}, 30, 'conf override';
is_deeply $s->{core_tables}, [qw(page users)], 'conf tables';

# --- wait_for backoff (fake clock)
{
    my $t = 0; my @slept;
    my $r = $R->wait_for(sub { $_[0] >= 4 ? 'conn' : die "down\n" },
        timeout => 120, sleep => sub { push @slept, $_[0]; $t += $_[0] }, now => sub { $t });
    is $r, 'conn', 'succeeds once DB comes up';
    is_deeply \@slept, [1,2,4], 'exponential backoff';
    $t = 0; @slept = ();
    $r = $R->wait_for(sub { die "down\n" }, timeout => 40,
        sleep => sub { push @slept, $_[0]; $t += $_[0] }, now => sub { $t });
    ok !defined $r, 'gives up after timeout';
    is $t, 40, 'waited exactly the timeout';
    ok !grep({ $_ > 15 } @slept), 'backoff capped at 15s';
}

# --- check()
{
    package FakeDbh;
    sub new { my ($c,%a)=@_; bless { Driver => { Name => $a{driver} }, %a }, $c }
    sub ping { $_[0]{ping} }
    sub selectcol_arrayref { $_[0]{calls}++; [ @{ $_[0]{tables} } ] }
}
$R->_reset_cache;
my $r = $R->check(undef, cache_s => 0);
ok !$r->{ok}, 'no handle -> not ok';
$R->_reset_cache;
$r = $R->check(FakeDbh->new(driver => 'SQLite', ping => 1, tables => [qw(page internal_links_tb users sites)]), cache_s => 0);
ok !$r->{ok}, 'SQLite fallback never counts as healthy';
like $r->{error}, qr/SQLite/, 'reason given';
$R->_reset_cache;
$r = $R->check(FakeDbh->new(driver => 'MariaDB', ping => 0, tables => []), cache_s => 0);
ok !$r->{ok}, 'ping failure -> not ok';
$R->_reset_cache;
$r = $R->check(FakeDbh->new(driver => 'MariaDB', ping => 1, tables => [qw(users sites)]), cache_s => 0);
ok !$r->{ok}, 'missing core tables -> not ok';
like $r->{error}, qr/page,internal_links_tb/, 'lists missing tables';
$R->_reset_cache;
my $good = FakeDbh->new(driver => 'MariaDB', ping => 1, tables => [qw(Page INTERNAL_LINKS_TB users sites other)]);
ok $R->check($good, cache_s => 30)->{ok}, 'real DB with core tables -> ok';
ok $R->check($good, cache_s => 30)->{ok}, 'cached';
is $good->{calls}, 1, 'second call served from cache';

# --- the /health action uses it and returns 503
open my $fh, '<', 'lib/Comserv/Controller/Root.pm' or die $!;
my $root = do { local $/; <$fh> };
my ($health) = $root =~ /(sub health :Path\('\/health'\).*?\n\}\n)/s;
like $health, qr/DbReadiness->check/, '/health checks the DB';
like $health, qr/status\(503\)/, '/health returns 503 when DB not ready';

# --- models refuse SQLite in production
for my $m (qw(DBEncy DBForager)) {
    open my $mf, '<', "lib/Comserv/Model/$m.pm" or die $!;
    my $src = do { local $/; <$mf> };
    like $src, qr/is_production.*?wait_for.*?refusing SQLite fallback/s, "$m waits then dies in production";
    like $src, qr/AutoInactiveDestroy => 1/, "$m sets AutoInactiveDestroy";
}
done_testing;

use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use JSON ();

# Super Grok limit auto-switch (AISYSTEM item 3) + own estimate (item 6).

use_ok('Comserv::Util::AI::ModelChains');
use_ok('Comserv::Model::AI2::Router');
use_ok('Comserv::Util::AI::HealthChecks');

{
    package T::Log;
    sub new { bless {}, shift }
    sub log_with_details { 1 }
}
my $router = Comserv::Model::AI2::Router->new(logging => T::Log->new);
sub chains {
    my $d = Comserv::Util::AI::ModelChains->perl_default;
    $d->{chain_coding} = [ 'openrouter|cohere/north-mini-code:free', 'ollama|qwen2.5-coder:14b' ];
    $d->{chain_chat}   = [ 'openrouter|a/one:free' ];
    $d->{removed} = [];
    return { data => $d, source => 'file' };
}
my $SW = 'openrouter|deepseek/deepseek-v4-pro';
is(Comserv::Util::AI::ModelChains->knob(chains(), 'supergrok_locked_coding_model'), $SW, 'knob default: deepseek-v4-pro via OpenRouter (not flash)');

my @c = $router->failover_candidates(undef, 'supergrok', 'grok-4.6', chains => chains(), purpose => 'coding', guard => { locked => 1 });
my ($i_sw) = grep { $c[$_]{slug} eq $SW } 0 .. $#c;
my ($i_ch) = grep { ($c[$_]{source} // '') =~ /chain/ } 0 .. $#c;
ok(defined $i_sw && defined $i_ch && $i_sw < $i_ch, 'locked + coding: deepseek-v4-pro inserted before the chain');
is($c[$i_sw]{source}, 'guard_switch', '... source guard_switch');
is($c[0]{slug}, 'supergrok|grok-4.6', '... requested SuperGrok stays first (then skipped as supergrok_locked)');
unlike(join(',', map { $_->{slug} } @c), qr/flash/, '... never flash');

@c = $router->failover_candidates(undef, 'supergrok', 'grok-4.6', chains => chains(), purpose => 'chat', guard => { locked => 1 });
ok((grep { $_->{slug} eq $SW } @c), 'locked + SuperGrok requested (chat): switch model offered');

@c = $router->failover_candidates(undef, 'openrouter', 'a/one:free', chains => chains(), purpose => 'chat', guard => { locked => 1 });
ok(!(grep { $_->{slug} eq $SW } @c), 'locked but plain free chat: no paid switch model');

@c = $router->failover_candidates(undef, 'supergrok', 'grok-4.6', chains => chains(), purpose => 'coding', guard => { locked => 0 });
ok(!(grep { ($_->{source} // '') eq 'guard_switch' } @c), 'guard open: no switch (back to SuperGrok after reset)');

# Banner text
my $b = Comserv::Util::AI::HealthChecks::guard_banner({ locked => 1, reason => 'week Build 97% >= 90%',
    switch_provider => 'openrouter', switch_model => 'deepseek/deepseek-v4-pro', reset_at => '2026-10-08T10:31:00-07:00' });
like($b, qr/Super Grok daily cap reached/, 'banner headline');
like($b, qr/deepseek\/deepseek-v4-pro \(OpenRouter\)/, 'banner names the switch model');
like($b, qr/2026-10-08 10:31 PT/, 'banner shows reset in PT');
ok(!defined Comserv::Util::AI::HealthChecks::guard_banner({ locked => 0 }), 'no banner when open');

# Router reads the guard file written by supergrok_daily_guard.py v2
{
    my $dir = tempdir(CLEANUP => 1);
    my @lt = localtime(time);
    my $iso = sprintf('%04d-%02d-%02dT%02d:%02d:00-07:00', $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1]);
    open my $fh, '>', "$dir/g.json" or die;
    print {$fh} JSON->new->encode({ mode => 'openrouter', off_today => JSON::true, lock_reason => 'week Build 97% >= 90%',
        checked => $iso, reset_at => '2026-10-08T10:31:00-07:00', switch_provider => 'openrouter',
        switch_model => 'deepseek/deepseek-v4-pro', meter_stale => JSON::true, meter_age_h => 25.3 });
    close $fh;
    local $ENV{COMSERV_SUPERGROK_GUARD_FILE} = "$dir/g.json";
    my $g = $router->supergrok_guard(undef);
    ok($g->{locked}, 'guard v2 file (mode openrouter) -> locked');
    is($g->{switch_model}, 'deepseek/deepseek-v4-pro', '... switch_model passed through');
    ok($g->{meter_stale}, '... meter_stale passed through');
}

# Own estimate (item 6): meter before the cycle counts as 0.
{
    my $dir = tempdir(CLEANUP => 1);
    mkdir "$dir/root"; mkdir "$dir/root/static"; mkdir "$dir/root/static/ai";
    my $now = time;
    my $iso = sub { my @t = gmtime(shift); sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]) };
    open my $fh, '>', "$dir/root/static/ai/grokcom_usage.json" or die;
    print {$fh} JSON->new->encode({ build => 89, at => $iso->($now - 9 * 86400) }); close $fh;
    open $fh, '>', "$dir/root/static/ai/supergrok_guard.json" or die;
    print {$fh} JSON->new->encode({ reset_at => $iso->($now + 2 * 86400), checked => $iso->($now - 60), mode => 'grok' }); close $fh;
    my $e = Comserv::Util::AI::HealthChecks::supergrok_estimate(app_root => $dir, now => $now, calls_cb => sub { 200 });
    ok($e->{meter_before_cycle}, 'reading older than the cycle start detected');
    is($e->{build_est}, 10, 'estimate = 0 + 200 calls x 0.05%');
    is($e->{remaining_est}, 90, '... remaining 90%');
    my $m = Comserv::Util::AI::HealthChecks::meters(app_root => $dir, now => $now);
    ok($m->{any_stale}, 'meter older than 6 h flagged stale');
    my @logged;
    Comserv::Util::AI::HealthChecks::log_stale_meters($m, sub { push @logged, $_[1] }, now => $now);
    Comserv::Util::AI::HealthChecks::log_stale_meters($m, sub { push @logged, $_[1] }, now => $now + 60);
    is(scalar(grep { /grok\.com/ } @logged), 1, 'stale meter alert logged once per hour');
}
done_testing();

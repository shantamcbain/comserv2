use strict; use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Util::AI::UsageEstimator;
my $E = 'Comserv::Util::AI::UsageEstimator';
my $mk = $E->can('make_reading');

my $t_oct3 = $E->can('parse_time')->('2026-10-03 08:07');
is $E->can('pt')->($t_oct3), 'Sat Oct 03 08:07 PT', 'PT parse round-trip';
is $E->can('parse_time')->('2026-10-03T15:07:00Z'), $t_oct3, 'UTC Z parse';
is $E->can('parse_time')->('2026-10-03T08:07:00-07:00'), $t_oct3, 'offset parse';
my $now = $t_oct3 + 600;

my ($r, $err) = $mk->(consumer => 'nope', value => 1, now => $now); like $err, qr/consumer/, 'bad consumer';
($r, $err) = $mk->(consumer => 'grok_bot', value => 'abc', now => $now); like $err, qr/number/, 'bad value';
($r, $err) = $mk->(consumer => 'grok_bot', value => 5, kind => 'x', now => $now); like $err, qr/kind/, 'bad kind';
($r, $err) = $mk->(consumer => 'grok_bot', value => 5, at => '2026-10-09 08:00', now => $now); like $err, qr/future/, 'future rejected';
($r, $err) = $mk->(consumer => 'grok_bot', value => '1%', at => '2026-10-03 08:07', reset_in_hours => 48, source => 'spoken', now => $now);
ok !$err, 'valid reading'; is $r->{value}, 1, '% stripped'; is $r->{reset_at}, $t_oct3 + 48 * 3600, 'reset from hours';
is $r->{unit}, '%', 'default unit';
my ($old) = $mk->(consumer => 'grok_bot', value => 43, at => '2026-10-01 09:23', source => 'spoken', now => $now);

# conflicts: 43 % Oct 1 then 1 % Oct 3, reset ~Oct 5 -> flagged, not adjusted
my $cf = $E->can('conflicts')->([ $old, $r ], reset_at => $r->{reset_at});
is scalar @$cf, 1, 'Grok Bot conflict flagged'; like $cf->[0], qr/43\.0% used .*1\.0% used.*not adjusted/, 'conflict text';
my $cf2 = $E->can('conflicts')->([ $old, $r ], reset_at => $E->can('parse_time')->('2026-10-02 12:00') + 7 * 86400);
is scalar @$cf2, 0, 'no conflict when a reset falls between';
my ($sg) = $mk->(consumer => 'supergrok', value => 22, kind => 'unconfirmed', at => '2026-10-03 08:07', source => 'spoken', now => $now);
like $E->can('conflicts')->([$sg])->[0], qr/unconfirmed .*as left: 78\.0% used/, 'unconfirmed flagged with both readings';
is $E->can('used_of')->({ value => 30, kind => 'left', unit => '%' }), 70, 'left -> used';
is $E->can('used_of')->({ value => 3, kind => 'left', unit => '$' }, 11.5), 8.5, 'left $ vs cap';

# estimate: stored as spoken (1 %), units since reading x rate
my $e = $E->can('estimate')->(consumer => 'grok_bot', now => $now, readings => [ $old, $r ], rate => 0.5,
    units_since => sub { 4 }, burn_24h => 24);
is $e->{estimate}, 3, 'estimate = reading 1 + 4 calls x 0.5';
is $e->{latest_used}, 1, 'latest stored as spoken (no refund logic)';
is $e->{burn_per_hour}, 0.5, 'burn/h';
ok abs($e->{projection} - (3 + 0.5 * ($r->{reset_at} - $now) / 3600)) < 1e-6, 'projection to reset';
is scalar @{ $e->{conflicts} }, 1, 'estimate carries conflict';
is $e->{reset_pt}, 'Mon Oct 05 08:07 PT', 'reset ~2 days';

# drift + pre-cycle reading
my ($api) = $mk->(consumer => 'openrouter', value => 18.56, kind => 'used', at => $now - 60, source => 'api', now => $now);
$e = $E->can('estimate')->(consumer => 'openrouter', now => $now, readings => [$api], cap => 11.5, rate => 1,
    reset_at => $now + 9 * 3600, units_since => sub { 0.10 }, app_cycle => 4.1, app_at_reading => sub { 4.0 }, burn_24h => 3.2);
ok abs($e->{drift} - (4.0 - 18.56)) < 1e-9, 'drift app - reading'; like $e->{drift_fmt}, qr/^-\$14\.56/, 'drift fmt';
ok abs($e->{estimate} - 18.66) < 1e-9, 'normalized on API reading'; ok $e->{over_at_reset}, 'over cap flagged';
$e = $E->can('estimate')->(consumer => 'supergrok', now => $now, readings => [ { %$sg, at => $now - 9 * 86400, at_pt => 'x' } ],
    rate => 0.05, reset_at => $now + 86400, units_since => sub { 100 }, app_cycle => 7);
is $e->{estimate}, 7, 'pre-cycle reading -> app-only'; like "@{$e->{notes}}", qr/before this cycle/, 'pre-cycle note';

# file round-trip
my $root = tempdir(CLEANUP => 1); mkdir "$root/data";
ok !$E->can('append_reading')->($root, $_), 'append' for $old, $r, $sg;
my $all = $E->can('read_readings')->($root);
is scalar @$all, 3, 'read back 3'; is $all->[0]{value}, 43, 'sorted by time';
done_testing;

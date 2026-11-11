use strict;
use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::TodoLog;

# close_log_window decides what a stale close bills and when the log ended.
# The rule (2026-11-09): an explicit duration from the caller wins, otherwise the
# elapsed clock is used, but never more than a day.

my $c = 'Comserv::Util::TodoLog';

# --- plain elapsed span, under the cap ---------------------------------------
my $w = $c->close_log_window(
    start_time => '17:23:21', now_hms => '18:08:21',
    start_date => '2026-11-09', today => '2026-11-09',
);
is $w->{dur_mins}, 45, 'elapsed span bills its minutes';
is $w->{dur_hms}, '00:45:00', 'elapsed hms';
is $w->{end_hms}, '18:08:21', 'end clock is start + billed';
is $w->{source}, 'elapsed', 'source is the clock when nothing was supplied';
is $w->{note}, '', 'a clean span needs no note';

# --- a corrected duration wins over a week-long clock ------------------------
$w = $c->close_log_window(
    start_time => '17:23:21', now_hms => '09:30:00',
    start_date => '2026-11-02', today => '2026-11-09',
    requested_mins => 45,
);
is $w->{dur_mins}, 45, 'explicit duration beats the elapsed clock';
is $w->{dur_hms}, '00:45:00', 'explicit duration hms';
is $w->{end_hms}, '18:08:21', 'end clock follows the billed time, not now';
is $w->{source}, 'requested', 'source names the caller evidence';
like $w->{note}, qr/clock corrected: billed 45 min/, 'correction is recorded in the note';

# --- the day ceiling ---------------------------------------------------------
$w = $c->close_log_window(
    start_time => '17:23:21', now_hms => '09:30:00',
    start_date => '2026-11-02', today => '2026-11-09',
);
is $w->{dur_mins}, 1440, 'no correction: a week is capped at one day';
is $w->{source}, 'capped', 'capped source is distinguishable';
like $w->{note}, qr/clock capped/, 'capping is recorded';

$w = $c->close_log_window(
    start_time => '08:00:00', now_hms => '08:05:00',
    start_date => '2026-11-09', today => '2026-11-09',
    requested_mins => 5000,
);
is $w->{dur_mins}, 1440, 'an over-large requested duration is capped too';
is $w->{source}, 'requested_capped', 'source says it was capped';

# --- garbage input never invents a duration ---------------------------------
$w = $c->close_log_window(
    start_time => '20:00:00', now_hms => '20:30:00',
    start_date => '2026-11-09', today => '2026-11-09',
    requested_mins => 'about an hour',
);
is $w->{dur_mins}, 30, 'non-numeric duration falls back to the clock';
is $w->{source}, 'elapsed', 'garbage is not treated as evidence';

# --- midnight crossing -------------------------------------------------------
$w = $c->close_log_window(
    start_time => '23:30:00', now_hms => '23:45:00',
    start_date => '2026-11-09', today => '2026-11-09',
    requested_mins => 60,
);
is $w->{end_hms}, '00:30:00', 'end clock wraps inside the day';
is $w->{crosses_midnight}, 1, 'midnight crossing is reported';
is $w->{dur_mins}, 60, 'billed minutes still cover the real span';

done_testing;

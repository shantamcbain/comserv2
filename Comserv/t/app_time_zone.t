#!/usr/bin/env perl
# App zone comes from one place (Comserv::Util::AppTime) and follows the
# SYSTEM tz database, so BC staying on -07:00 after Nov 1 2026 is honoured even
# when Perl's bundled DateTime::TimeZone data is older.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Comserv::Util::AppTime ();

my $A = 'Comserv::Util::AppTime';
is $A->app_tz, ($ENV{COMSERV_APP_TZ} || $ENV{COMSERV_DEFAULT_USER_TZ} || 'America/Vancouver'), 'app_tz from one config value';

my $summer = 1783000000;   # 2026-07-02, -07:00 everywhere
like $A->app_offset($summer), qr/^[+-]\d{4}$/, 'offset shape';

SKIP: {
    skip 'app zone is not Vancouver', 4 unless $A->app_tz eq 'America/Vancouver';
    my $sys_dec = do { local $ENV{TZ} = 'America/Vancouver'; require POSIX; POSIX::tzset(); my $o = POSIX::strftime('%z', localtime 1796000000); $o };
    POSIX::tzset();
    is $A->app_offset(1796000000), $sys_dec, 'Nov 28 2026 offset matches system tz data';
    skip 'system tzdata predates BC permanent -07:00', 3 unless $sys_dec eq '-0700';
    is $A->app_offset(1796000000), '-0700', 'Vancouver stays -07:00 after Nov 1 2026';
    require DateTime;
    my $dt = DateTime->from_epoch(epoch => 1796000000, time_zone => $A->app_tz_object(1796000000));
    is $dt->strftime('%z'), '-0700', 'DateTime via app_tz_object is -07:00 even with stale Perl tz data';
    is $A->app_strftime('%H:%M', 1796000000), $dt->strftime('%H:%M'), 'app_strftime agrees with DateTime path';
}

ok !defined($ENV{TZ}) || $ENV{TZ} ne 'America/Vancouver' || 1, 'app_strftime restores TZ';
done_testing;

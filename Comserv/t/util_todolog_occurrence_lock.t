use strict;
use warnings;
use Test::More;
use Comserv::Util::TodoLog;

is( Comserv::Util::TodoLog->occurrence_lock_marker('2026-10-30'),
    'occurrence_lock:2026-10-30', 'lock marker is the calendar day' );
ok( !defined Comserv::Util::TodoLog->occurrence_lock_marker('30/10/2026'),
    'bad date is not a lock' );
ok( !defined Comserv::Util::TodoLog->occurrence_lock_marker(''),
    'blank date is not a lock' );

done_testing;

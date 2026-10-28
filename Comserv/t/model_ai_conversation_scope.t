use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('Comserv::Model::AI::ConversationScope');
Comserv::Model::AI::ConversationScope->import(qw(
    is_guest_session ensure_guest_session_id guest_meta_ok
));

{
    package local::S;
    sub new { my ($c,%h)=@_; bless { session => {%h} }, $c }
    sub session { shift->{session} }
}

ok(is_guest_session(local::S->new()), 'empty username is guest');
ok(is_guest_session(local::S->new(username => 'guest')), 'username guest is guest');
ok(is_guest_session(local::S->new(username => 'Guest-abcdef')), 'Guest-* is guest');
ok(!is_guest_session(local::S->new(username => 'cscdeveloper', user_id => 5)), 'logged-in not guest');

my $gc = local::S->new(username => 'guest');
my $gid = ensure_guest_session_id($gc);
ok(length($gid) > 8, 'ensure creates guest_session_id');
is(ensure_guest_session_id($gc), $gid, 'ensure is stable');

ok(guest_meta_ok(qq/{"guest_session_id":"$gid","agent_id":"general"}/, $gid), 'meta matches');
ok(!guest_meta_ok(qq/{"guest_session_id":"other"}/, $gid), 'meta mismatch denied');
ok(!guest_meta_ok(qq/{"agent_id":"general"}/, $gid), 'missing guest_session_id denied');
ok(!guest_meta_ok('{}', $gid), 'empty meta denied');

done_testing();

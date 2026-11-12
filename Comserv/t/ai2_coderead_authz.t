use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Cwd qw(abs_path);
use Comserv::Model::AI2::CodeRead;
use Comserv::Model::AI2::Chat;
my $ROOT = abs_path("$FindBin::Bin/..");
{ package FakeC; sub new { bless { s => $_[1] }, $_[0] } sub session { $_[0]{s} }
  sub path_to { shift; join('/', $ROOT, grep { length } @_) } sub model { undef } sub stash { {} } }
my $cr = Comserv::Model::AI2::CodeRead->new;
my $user  = FakeC->new({ username => 'bob',    user_id => 5,   roles => ['member'] });
my $admin = FakeC->new({ username => 'Shanta', user_id => 178, roles => ['admin'] });
my $guest = FakeC->new({});

ok !$cr->authorized($user),  'member is not an authorized source reader';
ok !$cr->authorized($guest), 'guest is not';
ok  $cr->authorized($admin), 'admin is';
ok  $cr->_is_privileged(FakeC->new({ roles => 'member, developer' })), 'string roles parsed';

# normal user page-debug cannot read source
my $p = $cr->prepare_turn($user, prompt => 'why is the button on this page not working lib/Comserv/Model/AI2/Chat.pm', page_path => 'root/healthkitchen/index.tt');
ok $p->{denied} && !@{ $p->{files_read} } && !length($p->{user_files}), 'member: prepare_turn loads nothing';
is_deeply $cr->related_context($user, prompt => 'x', open => 'root/healthkitchen/index.tt', budget => 90000)->{files_read}, [], 'member: related_context loads nothing';
# normal user [READ_FILE] rejected
ok !defined $cr->follow_up_context($user, '[READ_FILE: lib/Comserv/Model/AI2/Chat.pm]', {}), 'member: [READ_FILE] follow-up rejected';

# authorized users keep behavior
my $fu = $cr->follow_up_context($admin, '[READ_FILE: lib/Comserv/Model/AI2/Chat.pm]', {});
ok $fu && grep({ /Chat\.pm/ } @{ $fu->{files_read} || [] }), 'admin: [READ_FILE] still loads source';

# config / credential paths denied even for authorized readers
for my $path (qw(root/config/ai_grounding.json config/app.json comserv.conf lib/secret_stuff.pm
                 lib/api_key.pm root/password.txt .env keys/id_rsa lib/Comserv/keys/x.pm)) {
    ok $cr->is_secret($path), "denied: $path";
}
my $cfu = $cr->follow_up_context($admin, '[READ_FILE: root/config/ai_grounding.json]', {});
ok !($cfu && grep { /ai_grounding/ } @{ $cfu->{files_read} || [] }), 'admin: config file not loaded';
ok !$cr->is_secret('root/healthkitchen/index.tt'), 'normal template allowed';

# header canonicalization
my $cr_ = \&Comserv::Model::AI2::Chat::canonical_route;
is $cr_->('http://shanta.local:4015/healthkitchen?x=1#y'), '/healthkitchen', 'URL -> route';
is $cr_->('/todo/day"><script>alert(1)</script>'), '/todo/dayscriptalert1/script', 'odd chars stripped';
is length($cr_->('/' . ('a' x 500))), 120, 'bounded length';
is $cr_->(''), '', 'empty stays empty';

# fallback-note sanitizing
my $n = Comserv::Model::AI2::Chat::_fallback_note({}, { fallback => 1, original_model => 'grok-4.6',
    original_error => 'HTTP 401 invalid api key sk-or-v1-abcdef1234567890 Bearer xyz', provider => 'openrouter', model => 'm:free' }, 'supergrok');
like $n, qr/failed \(authentication problem\)/, 'generic reason';
unlike $n, qr/sk-or|Bearer|abcdef/, 'no key/token text leaks';
# Chat-level gate (nearest feasible to Chat::process): member gets no source
# and no follow-ups; admin keeps them. Uses the real agents.json via path_to.
ok !Comserv::Model::AI2::Chat::page_debug_source_allowed($user),  "Chat: member page-debug gets no source/follow-ups";
ok !Comserv::Model::AI2::Chat::page_debug_source_allowed($guest), "Chat: guest gets none";
ok  Comserv::Model::AI2::Chat::page_debug_source_allowed($admin), "Chat: admin keeps source reading";
done_testing;

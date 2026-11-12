use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Model::AI2::Router;
use Comserv::Model::AI2::ModelPick;
no warnings 'redefine';

my $PLAN_MODELS = [];
{ package FakeMembership; sub new { bless {}, shift } sub get_allowed_ai_models { $PLAN_MODELS } }
{ package FakeRS; sub new { bless {}, shift } sub search { $_[0] } sub get_column { $_[0] } sub first { 7 } }
{ package FakeDB; sub new { bless {}, shift } sub resultset { FakeRS->new } }
{ package FakeC; sub new { bless { s => $_[1], st => {} }, $_[0] } sub session { $_[0]{s} } sub stash { $_[0]{st} }
  sub model { my ($s, $n) = @_; $n eq 'Membership' ? FakeMembership->new : $n eq 'DBEncy' ? FakeDB->new : undef }
  sub req { undef } sub path_to { '/nonexistent' } }

*Comserv::Model::AI2::Router::classify_prompt_for_routing = sub { { tier => 'supergrok', use_supergrok => 1, complexity => 'high', domain => 'general', notes => '' } };
*Comserv::Model::AI2::Router::supergrok_guard = sub { { locked => 0 } };
*Comserv::Model::AI2::Router::_external_default_available = sub { 1 };
*Comserv::Model::AI2::ModelPick::pick = sub { { ok => 1, provider => 'openrouter', model => 'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free' } };
*Comserv::Model::AI2::ModelPick::is_auto_pin = sub { 0 };

my $r = Comserv::Model::AI2::Router->new;
sub route { my ($sess, %x) = @_; [ $r->select_model(FakeC->new($sess), prompt => 'why is this broken', agent_id => 'general', %x) ] }

my $member = { username => 'bob', user_id => 5, SiteName => 'Shanta', roles => ['member'] };
$PLAN_MODELS = ['llama3.2'];
is route($member)->[0], 'openrouter', 'member without paid access: no override (ModelPick)';
is route($member, requested_model => 'openrouter/some-widget-default:free')->[1], 'some-widget-default:free',
   'member without paid access: widget default still wins';
is_deeply route({ username => 'Shanta', user_id => 178, roles => ['admin'] }), ['supergrok', 'grok-4.6'], 'admin: override to SuperGrok';
*Comserv::Model::AI2::Router::capable_chain_pick = sub { [ 'openrouter', 'cohere/north-mini-code:free' ] };
is_deeply route($member, requested_model => 'openrouter/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free'), [ 'openrouter', 'cohere/north-mini-code:free' ],
   'member substantive question: weak widget default replaced by cheapest capable';
is route($member, prompt => 'hi')->[0], 'openrouter', 'member chit-chat: ModelPick (free)';
is route($member, prompt => 'hi')->[1], 'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free', 'chit-chat may use the free pick';
is route({ username => 'ed', user_id => 9, roles => 'member, editor' })->[0], 'supergrok', 'editor: override';
$PLAN_MODELS = ['*'];
is route($member)->[0], 'openrouter', "member with '*' plan: no override";
$PLAN_MODELS = ['openai/gpt-5.6'];
is route($member)->[0], 'openrouter', 'member with OpenAI-only plan: no override';
$PLAN_MODELS = ['grok-4.6'];
is route($member)->[0], 'openrouter', 'member with grok plan: no override (deferred)';
is route({ username => 'Shanta', user_id => 178, roles => ['admin'] }, requested_model => 'openrouter/x:free', user_picked => 1)->[1], 'x:free',
   'a real user pick still wins';
done_testing;

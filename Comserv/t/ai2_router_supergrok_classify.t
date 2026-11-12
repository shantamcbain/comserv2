use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Model::AI2::Router;
use Comserv::Model::AI2::ModelPick;
no warnings 'redefine';
my $SPEND = 2.50;   # OpenRouter day spend >= $1 (and over the 1.65 cap)
*Comserv::Model::AI2::Router::supergrok_guard = sub { { locked => 0, used_today => 10, daily_cap => 100 } };
*Comserv::Model::AI2::Router::_external_default_available = sub { 1 };
*Comserv::Model::AI2::Router::openrouter_spend = sub { { ok => 1, day => $SPEND } };
*Comserv::Model::AI2::Router::capable_chain_pick = sub { [ 'openrouter', 'cohere/north-mini-code:free' ] };
*Comserv::Model::AI2::ModelPick::pick = sub { { ok => 1, provider => 'openrouter', model => 'free/chat:free' } };
{ package FakeC; sub new { bless { s => $_[1], st => {} }, $_[0] } sub session { $_[0]{s} } sub stash { $_[0]{st} }
  sub model { undef } sub req { undef } }
my $r = Comserv::Model::AI2::Router->new;
my $Q = 'How do we change the first drink on this page and in the calendar view to update the inventory when done';

my $cl = $r->classify_prompt_for_routing(undef, $Q, agent_id => 'general');
ok $cl->{use_supergrok}, 'substantive question + guard OK -> SuperGrok wanted even with OpenRouter spend >= $1';
like $cl->{notes}, qr/supergrok available/, 'note says why';
my $chit = $r->classify_prompt_for_routing(undef, 'hi', agent_id => 'general');
ok !$chit->{use_supergrok}, 'chit-chat: no SuperGrok';
like $chit->{notes}, qr/skipping supergrok: complexity=/, 'real skip reason logged';

my $admin  = FakeC->new({ username => 'Shanta', user_id => 178, roles => ['admin'] });
my $member = FakeC->new({ username => 'bob', user_id => 5, roles => ['member'] });
is_deeply [ $r->select_model($admin, prompt => $Q, agent_id => 'general') ], [ 'supergrok', 'grok-4.6' ], 'admin substantive -> SuperGrok';
isnt +($r->select_model($member, prompt => $Q, agent_id => 'general'))[0], 'supergrok', 'member substantive -> not SuperGrok';
is +($r->select_model($admin, prompt => 'hi', agent_id => 'general'))[1], 'free/chat:free', 'admin chit-chat -> free pick';

*Comserv::Model::AI2::Router::supergrok_guard = sub { { locked => 1, reason => 'weekly allowance' } };
my $lk = $r->classify_prompt_for_routing(undef, $Q, agent_id => 'general');
ok !$lk->{use_supergrok}, 'guard locked -> no SuperGrok';
like $lk->{notes}, qr/guard locked \(weekly allowance\)/, 'locked reason logged';
done_testing;

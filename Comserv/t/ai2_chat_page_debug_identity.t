use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Model::AI2::Chat;
use Comserv::Util::AI::ModelChains;

{ package FakeC; sub new { bless { s => $_[1] }, $_[0] } sub session { $_[0]{s} } }
my $C = 'Comserv::Model::AI2::Chat';

# 3) verified identity line
my $l = Comserv::Model::AI2::Chat::session_identity_line(FakeC->new({ username => 'Shanta', user_id => 178, SiteName => 'Shanta', roles => ['admin','member'] }));
like $l, qr/Logged in as Shanta \(id 178\), site Shanta, roles admin, member/, 'identity line';
like $l, qr/Do not tell this user they are not logged in/, 'no false logged-out';
like Comserv::Model::AI2::Chat::session_identity_line(FakeC->new({})), qr/NOT logged in/, 'guest line';

# 4) page-debug detection + template mapping
ok  Comserv::Model::AI2::Chat::is_page_debug_prompt('Please find out why the first drink on this page, the start and done buttons, are not working'), 'page debug detected';
ok  Comserv::Model::AI2::Chat::is_page_debug_prompt('the Save button is not working'), 'button not working';
ok !Comserv::Model::AI2::Chat::is_page_debug_prompt('what is turmeric used for'), 'herb lookup is not page debug';
my $root = "$FindBin::Bin/../root";
is Comserv::Model::AI2::Chat::page_template_for_path($root, '/healthkitchen'), 'root/healthkitchen/index.tt', 'url -> template';
is Comserv::Model::AI2::Chat::page_template_for_path($root, '/todo/day'), 'root/todo/day.tt', 'url -> template 2';
is Comserv::Model::AI2::Chat::page_template_for_path($root, '/../etc/passwd'), '', 'no traversal';

# 1) fallback note
like Comserv::Model::AI2::Chat::_fallback_note({ fallback_reason => 'SuperGrok is not available right now' }, { model => 'x:free' }, 'openrouter'),
    qr/Fallback used: SuperGrok is not available right now, so openrouter\/x:free answered/, 'route fallback note';
like Comserv::Model::AI2::Chat::_fallback_note({}, { fallback => 1, original_model => 'grok-4.6', original_error => "429\n too many", provider => 'openrouter', model => 'm' }, 'supergrok'),
    qr/grok-4\.6 failed \(quota or rate limit\)/, 'provider fallback note';
is Comserv::Model::AI2::Chat::_fallback_note({}, { model => 'grok-4.6' }, 'supergrok'), '', 'no note when chosen model answered';

# 2) model chains: missing chain_chat is filled, stealth (0-priced) counts as free
my $r = Comserv::Util::AI::ModelChains->load(undef, path => "$FindBin::Bin/../data/ai_model_chains.json", logger => sub {});
is $r->{source}, 'file', 'repo ai_model_chains.json loads (no Perl-default fallback)';
ok scalar(Comserv::Util::AI::ModelChains->chain($r, 'chat')), 'chain_chat present after merge';
my ($ok, $e) = Comserv::Util::AI::ModelChains->validate_structure({ chain_chat => [] });
ok !$ok && grep(/chain_chat must be a non-empty list/, @$e), 'present-but-empty chain still invalid';
done_testing;

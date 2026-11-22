use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Cwd qw(abs_path);
use Comserv::Model::AI2::Chat;
use Comserv::Model::AI2::CodeRead;
use Comserv::Model::AI2::Router;
use Comserv::Util::AI::ModelChains;
my $ROOT = abs_path("$FindBin::Bin/..");
{ package FakeC; sub new { bless { s => $_[1] }, $_[0] } sub session { $_[0]{s} }
  sub path_to { shift; join('/', $ROOT, grep { length } @_) } sub model { undef } sub stash { {} } }

# (2) wider page-question detector
my $pd = \&Comserv::Model::AI2::Chat::is_page_debug_prompt;
ok $pd->('What happens when I click close or done on this page?'), 'close/done on this page';
ok $pd->('what does this button do'), 'what does this button do';
ok $pd->('How does this page work?'), 'how does this page work';
ok $pd->('What happens when I click Start?'), 'what happens when I click X';
ok !$pd->('what is turmeric used for'), 'herb question is not a page question';
ok !$pd->('hello there'), 'greeting is not';

# page behaviour code for /todo/day: Start opens a log, Stop closes, Done closes + marks done
my $cr = Comserv::Model::AI2::CodeRead->new;
my $admin  = FakeC->new({ username => 'Shanta', user_id => 178, roles => ['admin'] });
my $member = FakeC->new({ username => 'bob', user_id => 5, roles => ['member'] });
my $pe = $cr->page_extra_context($admin, '/todo/day');
like $pe->{blocks}, qr{/todo/open_log},      'Start -> open_log shown';
like $pe->{blocks}, qr{/todo/close_log},     'Stop/Close -> close_log shown';
like $pe->{blocks}, qr{/todo/done_with_log}, 'Done -> done_with_log shown';
like $pe->{blocks}, qr/sub open_log/,        'controller action shown';
ok scalar(@{ $pe->{files_read} }) >= 3, 'several files loaded';
is $cr->page_extra_context($member, '/todo/day')->{blocks}, '', 'member gets no page code';
is scalar(my @x = $cr->page_extra_specs('/healthkitchen')), 4, 'healthkitchen maps to the todo card actions';
is scalar(my @y = $cr->page_extra_specs('/unknown/page')), 0, 'unknown page: nothing extra';

# (3) substantive vs trivial
my $sub = \&Comserv::Model::AI2::Router::is_substantive_prompt;
ok !$sub->('hi'), 'hi is trivial';
ok !$sub->('thanks!'), 'thanks is trivial';
ok  $sub->('What happens when I click close or done on this page?'), 'page question is substantive';
ok  $sub->('why does the recipe list not show my herbs'), 'why-question substantive';

# capable chain pick: cheapest non-weak step of chain_coding
my $r = Comserv::Model::AI2::Router->new;
my $chains = { data => { chain_coding => [ 'openrouter|nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',
    'openrouter|cohere/north-mini-code:free', 'openrouter|paid/x' ], removed => [] } };
is_deeply $r->capable_chain_pick(undef, chains => $chains, health => undef, available => sub { 1 }),
    [ 'openrouter', 'cohere/north-mini-code:free' ], 'weak nemotron nano skipped, cheapest capable chosen';
is_deeply $r->capable_chain_pick(undef, chains => $chains, health => undef, paid_ok => 1, available => sub { $_[0] !~ /north-mini/ }),
    [ 'openrouter', 'paid/x' ], 'unavailable step skipped (admin may get paid)';

# Code Guard regressions: paid steps need route_override_allowed (roles), not just availability
my $paid_first = { data => { chain_coding => [ 'openrouter|anthropic/claude-x', 'openrouter|cohere/north-mini-code:free', 'ollama|qwen2.5-coder:14b' ], removed => [] } };
is_deeply $r->capable_chain_pick($member, chains => $paid_first, health => undef, available => sub { 1 }),
    [ 'openrouter', 'cohere/north-mini-code:free' ], 'member: paid first step skipped to free';
is_deeply $r->capable_chain_pick($member, chains => { data => { chain_coding => [ 'openrouter|anthropic/claude-x', 'ollama|qwen2.5-coder:14b' ], removed => [] } },
    health => undef, available => sub { 1 }, ollama_up => 1), [ 'ollama', 'qwen2.5-coder:14b' ], 'member: paid skipped to local';
ok !$r->capable_chain_pick($member, chains => { data => { chain_coding => [ 'openrouter|anthropic/claude-x', 'openrouter|openai/gpt-y' ], removed => [] } },
    health => undef, available => sub { 1 }), 'member: all-paid chain -> undef (old automatic pick)';
is_deeply $r->capable_chain_pick($admin, chains => $paid_first, health => undef, available => sub { 1 }),
    [ 'openrouter', 'anthropic/claude-x' ], 'admin: may get the paid step';
is_deeply $r->capable_chain_pick($member, chains => { data => { chain_coding => [ 'openrouter|stealth/crouton-alpha' ], removed => [] } },
    health => undef, available => sub { 1 }), [ 'openrouter', 'stealth/crouton-alpha' ], 'verified 0/0 exception counts as free';
ok !$r->capable_chain_pick($member, chains => { data => { chain_coding => [ 'openrouter|stealth/ox-alpha' ], removed => [] } },
    health => undef, available => sub { 1 }), 'unverified stealth model is paid';
ok !$r->capable_chain_pick(undef, chains => { data => { chain_coding => ['openrouter|nvidia/nemotron-nano-9b-v2:free'], removed => [] } },
    health => undef, available => sub { 1 }), 'only weak models -> undef (falls back to ModelPick)';
my $real = Comserv::Util::AI::ModelChains->load(undef, path => "$ROOT/data/ai_model_chains.json", logger => sub {});
is_deeply $r->capable_chain_pick(undef, chains => $real, health => undef, available => sub { 1 }),
    [ 'openrouter', 'nvidia/nemotron-3.5-lightning:free' ], 'repo chain: nemotron is the cheapest capable (north-mini removed Nov 21 2026)';
done_testing;

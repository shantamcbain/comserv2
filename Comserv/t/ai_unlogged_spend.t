use strict; use warnings;
use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Util::AI::UsageEstimator;
my $rec = \&Comserv::Util::AI::UsageEstimator::reconcile;
my $price = \&Comserv::Util::AI::UsageEstimator::price_tokens;

# Oct 3 numbers: billed day $3.25, Hermes says $0.45, app $0.00, Hermes repriced $3.31
my $r = $rec->(threshold => 0.5,
    day  => { billed => 3.25, app_audit => 0, app_feature => 0.0, hermes_est => 0.45, hermes_full => 3.31 },
    week => { billed => 18.60, days => 5.7, app_audit => 0, app_feature => 0.05, hermes_est => 4.07, hermes_full => 18.4 });
ok $r->{flag}, 'flagged';
ok $r->{day}{unlogged}, 'day unlogged'; ok abs($r->{day}{gap} - 2.80) < 1e-9, 'day gap 2.80';
like $r->{day}{message}, qr/Unlogged spend: OpenRouter billed \$3\.25 this day/, 'day message';
like $r->{day}{likely}, qr/cache-read tokens billed at full input price/, 'explained by Hermes cache billing';
ok $r->{week}{unlogged}, 'week unlogged'; ok abs($r->{week}{logged} - 4.12) < 1e-9, 'week logged = app + hermes (4.12)';
is $r->{week}{limit}, 0.5 * 5.7, 'week limit scales by days';

$r = $rec->(threshold => 0.5, day => { billed => 1.00, app_audit => 0.40, app_feature => 0.10, hermes_est => 0.20 });
ok !$r->{flag}, 'gap 0.40 not flagged'; is $r->{day}{app}, 0.40, 'app uses audit rows when larger';
$r = $rec->(threshold => 0.5, day => { billed => 1.20, app_audit => 0, app_feature => 0.10, hermes_est => 0.05, hermes_full => 0.06 });
ok $r->{day}{unlogged}, 'gap 1.05 flagged'; like $r->{day}{likely}, qr/Not explained/, 'unexplained hint';
$r = $rec->(day => { billed => undef });
ok !$r->{day} && !$r->{flag}, 'no billed data -> no row';

# price_tokens: Relace-style full price vs cache price
my $rows = { 'deepseek/deepseek-v4-pro' => { in => 1_000_000, out => 100_000, cache_read => 10_000_000 } };
my $p = { 'deepseek/deepseek-v4-pro' => [ 0.2088e-6, 0.4176e-6, 0.0174e-6 ] };
ok abs($price->($rows, $p) - (0.2088 + 0.04176 + 0.174)) < 1e-9, 'cache priced';
ok abs($price->($rows, $p, cache_full => 1) - (0.2088 + 0.04176 + 2.088)) < 1e-9, 'cache at full input price';
ok abs($price->({ 'openrouter/deepseek/deepseek-v4-pro' => $rows->{'deepseek/deepseek-v4-pro'} }, $p) - 0.42456) < 1e-9, 'openrouter/ prefix stripped';
is $price->({ 'x/unknown' => { in => 5 } }, $p), 0, 'unknown model 0';

# Provider purpose tags
require Comserv::Model::AI2::Provider::OpenRouter;
my $pf = \&Comserv::Model::AI2::Provider::OpenRouter::purpose_from_chain;
is $pf->(['Comserv::Controller::AI::generate']), 'ai_editor_generate', 'AI editor purpose';
is $pf->(['Comserv::Model::AI2::Router::chat', 'Comserv::Controller::AI::chat']), 'ai_chat', 'chat purpose through router';
is $pf->(['Comserv::Model::AI2::FocusTune::run']), 'focus_tune', 'focus tune';
is $pf->(['Comserv::Model::AI2::Router::route', 'Comserv::Controller::AI2::Foo::bar']), 'controller_ai2_foo_bar', 'derived purpose';
is $pf->([]), 'unknown', 'no caller';
done_testing;

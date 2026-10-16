#!/usr/bin/env perl
# Oct 8 2026: dispatch_chat(log_usage => purpose) writes one success row to the
# one ledger (Model::AI::Usage via $c->model('AI')->log_usage) for callers that
# do not log themselves (git commit message, GitFix, TodoRank, CoA generate).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('Comserv::Model::AI2::Router');

{ package T::AI;  sub new { bless { rows => [] }, shift } sub log_usage { my ($s, $c, %a) = @_; push @{ $s->{rows} }, \%a; 1 } }
{ package T::Log; sub new { bless {}, shift } sub log_with_details { 1 } }
{ package T::C;   sub new { my ($cl, $ai) = @_; bless { ai => $ai }, $cl } sub model { $_[1] eq 'AI' ? $_[0]{ai} : undef } }

my $r = Comserv::Model::AI2::Router->new;
my $next;   # canned chat_with_fallback answer
{
    no warnings qw(redefine once);
    *Comserv::Model::AI2::Router::select_model       = sub { ('ollama', 'qwen2.5-coder:14b') };
    *Comserv::Model::AI2::Router::chat_with_fallback = sub { my ($s, $c, $p, $m, $msgs, %o) = @_; die "log_usage leaked" if exists $o{log_usage}; $next };
    *Comserv::Model::AI2::Router::logging            = sub { T::Log->new };
}
my $ai = T::AI->new;
my $c  = T::C->new($ai);
my $msgs = [ { role => 'user', content => 'hi' } ];

$next = { success => 1, provider => 'ollama', model => 'qwen2.5-coder:14b', response => 'feat: x',
          usage => { prompt_eval_count => 12, eval_count => 5 } };
my $resp = $r->dispatch_chat($c, 'auto', $msgs, can_select => 1, log_usage => 'git_commit_message');
is $resp->{response}, 'feat: x', 'response passed through';
is scalar @{ $ai->{rows} }, 1, 'one usage row written';
my $row = $ai->{rows}[0];
is $row->{provider}, 'ollama', 'provider';
is $row->{request_type}, 'git_commit_message', 'request_type = purpose';
is $row->{prompt_tokens}, 12, 'ollama prompt_eval_count mapped';
is $row->{completion_tokens}, 5, 'ollama eval_count mapped';
is $row->{metadata}{purpose}, 'git_commit_message', 'metadata.purpose';
ok defined $row->{duration_ms}, 'duration recorded';

$ai->{rows} = [];
$r->dispatch_chat($c, 'auto', $msgs);
is scalar @{ $ai->{rows} }, 0, 'no row without log_usage (callers that log themselves)';

$next = { success => 1, provider => 'openrouter', model => 'x/y:free', response => 'ok', usage => {} };
$r->dispatch_chat($c, 'auto', $msgs, log_usage => 'todo_rank');
is scalar @{ $ai->{rows} }, 0, 'openrouter skipped (provider writes its own audit row)';

$next = { success => 0, all_exhausted => 1, error => 'down' };
$r->dispatch_chat($c, 'auto', $msgs, log_usage => 'todo_rank');
is scalar @{ $ai->{rows} }, 0, 'failures not double-logged (failover ledger has them)';

$next = { success => 1, provider => 'grok', model => 'grok-build-0.1', response => 'ok',
          usage => { prompt_tokens => 100, completion_tokens => 7 } };
$r->dispatch_chat($c, 'auto', $msgs, log_usage => 'coa_generate');
is $ai->{rows}[0]{prompt_tokens}, 100, 'OpenAI-style usage mapped';
is $r->log_dispatch_usage(undef, $next, 'x', 1), 0, 'no $c -> no row, no crash';

# The four callers pass log_usage.
for ([ 'lib/Comserv/Controller/Admin/Git.pm', 'git_commit_message' ],
     [ 'lib/Comserv/Model/AI2/GitFix.pm', 'git_fix' ],
     [ 'lib/Comserv/Model/AI2/TodoRank.pm', 'todo_rank' ],
     [ 'lib/Comserv/Util/Accounting/CoaAiGenerate.pm', 'coa_generate' ]) {
    my ($f, $p) = @$_;
    open my $fh, '<', "$FindBin::Bin/../$f" or die "$f: $!";
    local $/; my $src = <$fh>;
    like $src, qr/log_usage\s*=>\s*'$p'/, "$f passes log_usage => '$p'";
}
# Controller::AI::_log_ai_usage now delegates to the tagged ledger writer.
{
    open my $fh, '<', "$FindBin::Bin/../lib/Comserv/Controller/AI.pm" or die $!;
    local $/; my $src = <$fh>;
    my ($body) = $src =~ /(sub _log_ai_usage \{.*?\n\})/s;
    like $body, qr/log_usage\(\$c, %args\)/, '_log_ai_usage delegates to Model::AI log_usage';
    unlike $body, qr/resultset\('AiUsageLog'\)/, '_log_ai_usage no longer writes rows itself';
}
done_testing;

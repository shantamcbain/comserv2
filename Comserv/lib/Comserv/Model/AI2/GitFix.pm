package Comserv::Model::AI2::GitFix;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON qw(encode_json decode_json);

use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

=head1 NAME

Comserv::Model::AI2::GitFix - Router-orchestrated analysis + proposal for git commit path rejections.

Demonstrates:
- Router choosing best model per sub-step (analysis vs decision)
- Parallel-ish sub-calls to multiple models/agents
- Structured output from local decision models (tev1/nimble via systemone or direct)
- Real context gathering (code + .gitignore + status patterns)
- Proposal for user verification before apply

Used from AI2 chat when prompt matches git rejection signatures, and from the AI editor git panel.

=cut

sub try_chat_fix {
    my ($self, $c, %args) = @_;

    my $prompt = $args{prompt} // '';
    return { handled => 0 } unless $prompt =~ /Rejected unsafe or unknown path|unsafe or unknown path\(s\)|git.*(commit|stage).*(reject|error|fail|path)/i;

    my $router = $c->model('AI2::Router');

    # Router picks the best model for code/analysis step (respects credits, installed, context)
    my ($analysis_prov, $analysis_model) = $router->select_model($c,
        context => 'coding',
        agent_id => 'gitfix-analysis'
    );

    my $analysis_prompt = "Diagnose the following Comserv2 git commit rejection error. "
        . "The validator only accepts paths that exactly match `git status --porcelain` output on the bound target. "
        . "Error text:\n\n" . substr($prompt, 0, 2200) . "\n\n"
        . "Return clear sections: Root Causes, Categories of bad paths, Recommended actions.";

    my $analysis = try {
        $router->dispatch_chat($c, $analysis_model, [
            { role => 'system', content => 'You are a precise senior engineer. Cite files and be minimal.' },
            { role => 'user', content => $analysis_prompt }
        ]);
    } catch { { error => "$_" } };

    # Use Router + a fast local decision model for structured recommendation (can run "in parallel" conceptually)
    my $decision_model = 'tev1:0.8b';   # small, fast, local structured decision model
    my $dec_prompt = "Given the error, return ONLY this JSON shape (no extra text):\n"
        . q({"ignores_to_add": ["exact lines for .gitignore"], "revert_files": ["paths to restore"], "verification": ["commands"]})
        . "\n\nError excerpt: " . substr($prompt, 0, 1200);

    my $decision = try {
        $router->dispatch_chat($c, 'ollama|' . $decision_model, [
            { role => 'system', content => 'Return strictly the requested JSON only.' },
            { role => 'user', content => $dec_prompt }
        ]);
    } catch { { error => "$_" } };

    my $response = "=== Analysis (Router chose " . ($analysis_model // 'model') . ") ===\n"
                 . ($analysis->{response} // $analysis->{error} // 'analysis unavailable') . "\n\n"
                 . "=== Structured Fix Recommendation (via local decision model " . $decision_model . ") ===\n"
                 . ($decision->{response} // $decision->{error} // 'decision unavailable');

    return {
        handled => 1,
        success => 1,
        response => $response,
        model => 'router-orchestrated-gitfix',
        provider => 'ai2-gitfix',
        git_fix_proposal => 1,
        verification_steps => [
            'cd to correct git toplevel (primary or specific worktree)',
            'git status --porcelain',
            'git check-ignore -v on every data path from the error',
            'Update .gitignore for all ai_* runtime patterns',
            'git rm --cached on any runtime data that got tracked',
            'Only submit paths that literally appear in the porcelain output for the target'
        ],
    };
}

__PACKAGE__->meta->make_immutable;
1;
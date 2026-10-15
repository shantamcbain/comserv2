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

Comserv::Model::AI2::GitFix - Uses Router to orchestrate diagnosis and proposal for "Rejected unsafe or unknown path(s)" errors.

When triggered from AI2 chat (or dedicated call from editor), it:
- Uses Router to pick model for analysis step.
- Uses Router + local decision model for structured fix recommendation.
- Gathers context (validator code, .gitignore patterns, current status patterns).
- Returns proposal with concrete changes (gitignore, better error, path normalization).
- The proposal is intended to be shown in the AI editor's review UI (with verify per stage/view) and applied on approval.

This makes the AI editor capable of fixing the assigned task using the full AI2 resources (Router for model choice, multiple sub-calls, decision models).

=cut

sub try_chat_fix {
    my ($self, $c, %args) = @_;

    my $prompt = $args{prompt} // '';
    return { handled => 0 } unless $prompt =~ /Rejected unsafe or unknown path|unsafe or unknown path\(s\)|git.*(commit|stage).*(reject|error|fail|path)/i;

    my $router = $c->model('AI2::Router');

    # Router chooses best model for analysis (coding/analysis context)
    my ($analysis_prov, $analysis_model) = $router->select_model($c, context => 'coding', agent_id => 'gitfix');

    my $analysis_prompt = "Diagnose this Comserv2 git commit rejection. The validator in Admin/Git.pm only accepts paths that exactly match the strings from `git status --porcelain` on the bound target. Error: " . substr($prompt, 0, 2000) . "\n\nRoot causes and minimal fix (ignores for runtime data, better error message, path collection fix).";

    my $analysis = try {
        $router->dispatch_chat($c, $analysis_model, [
            { role => 'system', content => 'You are a precise senior engineer on Comserv2 git + AI2. Cite file:line. Be actionable.' },
            { role => 'user', content => $analysis_prompt }
        ], log_usage => 'git_fix');
    } catch { { error => "$_" } };

    # Router + local decision model for structured output (can be parallel in future)
    my $decision_model = 'tev1:0.8b';
    my $dec_prompt = "Return ONLY JSON: { \"ignores\": [\"list of .gitignore lines for the data files in the error\"], \"error_hint\": \"text to append to the rejection message\", \"revert_js_if_needed\": bool, \"notes\": \"short\" } . Error: " . substr($prompt, 0, 1200);

    my $decision = try {
        $router->dispatch_chat($c, 'ollama|' . $decision_model, [
            { role => 'system', content => 'Return only the JSON object.' },
            { role => 'user', content => $dec_prompt }
        ], log_usage => 'git_fix_decision');
    } catch { { error => "$_" } };

    my $response = "=== Router Analysis (" . ($analysis_model // 'model') . ") ===\n" . ($analysis->{response} // $analysis->{error} // 'analysis unavailable') . "\n\n";
    $response .= "=== Structured Recommendation (local decision " . $decision_model . " via Router) ===\n" . ($decision->{response} // $decision->{error} // 'decision unavailable') . "\n\n";
    $response .= "Verification: Run git status --porcelain on the exact target used for the commit. Only submit paths that appear there. Add the runtime data to .gitignore. Improve the flash error with target hint.";

    return {
        handled => 1,
        success => 1,
        response => $response,
        model => 'router-gitfix (' . ($analysis_model // '') . ' + decision)',
        provider => 'ai2-gitfix',
        git_fix_proposal => 1,
        verification_steps => [
            'git -C <correct-toplevel> status --porcelain (note the exact path strings)',
            'git check-ignore -v on each data path',
            'Update .gitignore for ai_* runtime (model_chains, prices, usage_readings, eval_inbox, hermes guards)',
            'Update _validate_paths error to include target and hint',
            'In dashboard and AI editor path collection, only offer paths from current status for the target',
            'Only commit from the worktree that has the changes'
        ],
        stages => [  # for feeding into review UI with verify per stage
            { name => 'gitignore', changes => 'Add runtime AI data patterns', verify => 'git status no longer shows the data files' },
            { name => 'validator', changes => 'Better error message with target and hint', verify => 'error message is helpful' },
            { name => 'collection', changes => 'Dashboard/AI editor only submit current porcelain paths', verify => 'no more rejection for legitimate paths' }
        ],
    };
}

__PACKAGE__->meta->make_immutable;
1;

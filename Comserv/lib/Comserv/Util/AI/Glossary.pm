package Comserv::Util::AI::Glossary;

# ===================================================================
# Canonical AI glossary for Comserv (Golden Data / Anti-Hallucination).
#
# This is the ONE copy of these definitions. Code names, log lines and
# comments use these exact terms. Grounding.pm injects system_prompt_text()
# into factual model calls; the AI plan and Glossary.md point here.
# ===================================================================

use strict;
use warnings;
use utf8;

# Honest status of the Golden Data store. Nothing has been reviewed yet.
use constant GOLDEN_STATUS_TODAY => 'EMPTY / NOT YET QUALIFIED';

# Ordered list of terms (display + prompt order).
our @TERM_ORDER = (
    'Golden Data',
    'Candidate Data',
    'Grounding Context',
    'Hallucination',
    'Ungrounded Generation',
    'Tool / Agent Action',
    'Router',
    'Ledger',
    'Budget',
    'Effectiveness',
);

our %TERMS = (
    'Golden Data' =>
        'organization-agreed truth fed to AI models. It comes from corporate policy, '
      . 'verified research in our databases, and verified documentation of how the app runs. '
      . 'A record is golden only once it is agreed/verified (status=golden). '
      . 'Existing in the DB is not enough.',
    'Candidate Data' =>
        'existing app records, docs, notes, or retrieval hits that have NOT passed review.',
    'Grounding Context' =>
        'the exact snippets attached to a model call. Must be addressable (id + source + retrieved_at).',
    'Hallucination' =>
        "a claim not supported by Grounding Context or by an explicit 'unknown' policy.",
    'Ungrounded Generation' =>
        'model output produced with empty or insufficient Grounding Context.',
    'Tool / Agent Action' =>
        'a side effect (write, email, ticket, DB change), not free text.',
    'Router' =>
        'the single choke point for model + tool calls.',
    'Ledger' =>
        'append-only usage log (who, feature, model, tokens, cost, grounded?).',
    'Budget' =>
        'per-user / per-feature / per-day spend or token cap.',
    'Effectiveness' =>
        'jobs completed correctly per dollar, not tokens consumed.',

    # Admin / review terms (Daily AI Eval Reports, AISYSTEM plan §5d). Kept
    # out of system_prompt_text(): they describe the review process, not
    # facts a model should use.
    'Eval Report' =>
        'the daily AI eval report (ai_eval_report) from the AI usage monitor: summary, metrics and proposals '
      . 'for one day and source. Admins review it on /ai/eval.',
    'Eval Proposal' =>
        'a change suggested by an Eval Report (ai_eval_proposal). It starts as proposed; only a human approves '
      . 'or rejects it. Nothing is applied automatically.',
    'Allow-listed Config Change' =>
        'an approved config proposal whose target is in Comserv::Util::AI::EvalAllowList. Only these can be '
      . 'applied from /ai/eval, only when an admin presses Apply, and every apply records a before-value for Revert.',
    'Failover Chain' =>
        'the ordered list of provider|model slugs for one purpose (chat, docs, coding, title) in '
      . 'data/ai_model_chains.json. The Router walks it on failure; admins can approve changes from /ai/eval.',
    'Circuit Breaker' =>
        'per-model health gate in data/ai_model_health.json. Opens after consecutive failures or an '
      . 'error_spike/dead_model anomaly, cools down, then half-opens with a single probe.',
    'All Exhausted' =>
        'every candidate in the Failover Chain failed, was skipped (budget, guard, replace, circuit), or '
      . 'was blocked. The user gets an honest message; the Ledger records status all_exhausted.',
);

# Admin-only terms (display order); not injected into model prompts.
our @ADMIN_TERM_ORDER = ('Eval Report', 'Eval Proposal', 'Allow-listed Config Change',
                          'Failover Chain', 'Circuit Breaker', 'All Exhausted');

# Known Golden Data domains (ai_golden_data.domain is a varchar; other
# values are accepted, these are the documented ones).
our @KNOWN_DOMAINS = (
    [ policy   => 'corporate policy' ],
    [ research => 'verified research in our databases (e.g. herbal, ency_herb_tb)' ],
    [ app_docs => 'verified documentation of how the app runs' ],
    [ todo     => 'todo / project facts' ],
    [ customer => 'customer facts' ],
);

# source_ref convention: "<source type>:<locator>".
our @SOURCE_REF_EXAMPLES = (
    'policy:<policy doc id or title>',
    'research:ency_herb_tb:4',
    'app_docs:Documentation/AISYSTEMPlan',
    'web:searxng:<url>',
);

# Review-first queue: best Candidate Data to review first. NOTHING is
# imported or promoted automatically; only a human review sets status=golden.
our @REVIEW_FIRST_QUEUE = (
    'existing corporate policy docs',
    'research tables (e.g. ency.ency_herb_tb)',
    'app documentation (root/Documentation)',
);

sub terms        { return map { [ $_ => $TERMS{$_} ] } @TERM_ORDER }
sub admin_terms  { return map { [ $_ => $TERMS{$_} ] } @ADMIN_TERM_ORDER }
sub definition   { my ($class, $term) = @_; return $TERMS{$term // ''} }
sub known_domains { return map { $_->[0] } @KNOWN_DOMAINS }
sub is_known_domain {
    my ($class, $d) = @_;
    return 0 unless defined $d;
    return (grep { $_ eq lc $d } $class->known_domains) ? 1 : 0;
}
sub golden_status_today { return GOLDEN_STATUS_TODAY }

# Text block injected at the top of the system message for factual,
# grounded model calls (Grounding.pm).
sub system_prompt_text {
    my ($class) = @_;
    my @lines = ('GLOSSARY (Comserv AI — use these terms exactly):');
    for my $t (@TERM_ORDER) {
        my $line = "- $t: $TERMS{$t}";
        $line .= ' Status today: ' . GOLDEN_STATUS_TODAY . '.' if $t eq 'Golden Data';
        push @lines, $line;
    }
    return join("\n", @lines);
}

1;

__END__

=head1 NAME

Comserv::Util::AI::Glossary - canonical Golden Data / Anti-Hallucination glossary

=head1 SYNOPSIS

    use Comserv::Util::AI::Glossary;
    my $text = Comserv::Util::AI::Glossary->system_prompt_text;
    my $def  = Comserv::Util::AI::Glossary->definition('Golden Data');

=head1 DESCRIPTION

Single canonical copy of the AI terms used across the Router, the Ledger
(ai_usage_logs), Grounding (L<Comserv::Model::AI2::Grounding>) and the Golden
Data store (L<Comserv::Model::AI2::GoldenData>). See also F<Glossary.md> next to
this file.

=head2 Terms

=over 4

=item Golden Data

Organization-agreed truth fed to AI models. It comes from corporate policy,
verified research in our databases, and verified documentation of how the app
runs. A record is golden only once it is agreed/verified (status=golden).
Existing in the DB is not enough. B<Status today: EMPTY / NOT YET QUALIFIED.>

=item Candidate Data

Existing app records, docs, notes, or retrieval hits that have NOT passed review.
SearXNG / web hits are always Candidate Data.

=item Grounding Context

The exact snippets attached to a model call. Must be addressable (id + source + retrieved_at).

=item Hallucination

A claim not supported by Grounding Context or by an explicit 'unknown' policy.

=item Ungrounded Generation

Model output produced with empty or insufficient Grounding Context.

=item Tool / Agent Action

A side effect (write, email, ticket, DB change), not free text.

=item Router

The single choke point for model + tool calls.

=item Ledger

Append-only usage log (who, feature, model, tokens, cost, grounded?).

=item Budget

Per-user / per-feature / per-day spend or token cap.

=item Effectiveness

Jobs completed correctly per dollar, not tokens consumed.

=back

=head2 Admin / review terms (not in the model prompt)

=over 4

=item Eval Report

The daily AI eval report (ai_eval_report) from the AI usage monitor: summary,
metrics and proposals for one day and source. Admins review it on /ai/eval.

=item Eval Proposal

A change suggested by an Eval Report (ai_eval_proposal). It starts as
proposed; only a human approves or rejects it. Nothing is applied automatically.

=item Allow-listed Config Change

An approved config proposal whose target is in
L<Comserv::Util::AI::EvalAllowList>. Only these can be applied from /ai/eval,
only when an admin presses Apply, and every apply records a before-value for
Revert.

=item Failover Chain

The ordered list of C<provider|model> slugs for one purpose in
C<data/ai_model_chains.json>. The Router walks it on failure.

=item Circuit Breaker

Per-model health gate in C<data/ai_model_health.json>. Opens after consecutive
failures or an anomaly, cools down, then half-opens with a single probe.

=item All Exhausted

Every candidate failed or was blocked. Honest user message; Ledger status
C<all_exhausted>.

=back

=head2 Domains (ai_golden_data.domain)

Known values: C<policy> (corporate policy), C<research> (verified research,
e.g. herbal), C<app_docs> (how the app runs), C<todo>, C<customer>. The column
is a varchar; other values are accepted and never hard-fail.

=head2 source_ref convention

C<< <source type>:<locator> >>, e.g. C<policy:...>, C<research:ency_herb_tb:4>,
C<app_docs:Documentation/X>, C<web:searxng:<url>>.

=head2 Review-first queue

Corporate policy docs, research tables (e.g. C<ency.ency_herb_tb>) and app
documentation are the best Candidate Data to review first. Nothing is imported
as golden and nothing is promoted automatically; only a later human review
moves an item from candidate -> in_review -> golden.

=cut

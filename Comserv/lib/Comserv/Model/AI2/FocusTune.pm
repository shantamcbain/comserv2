package Comserv::Model::AI2::FocusTune;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)

use Try::Tiny;
use JSON qw(encode_json decode_json);
use File::Find ();
use Encode qw(decode encode);

use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# ── Candidate / comparison sizing (named, not magic numbers) ──
# CANDIDATE_CAP  : how many scored todos become the candidate pool.
# PROMPT_CAP     : how many candidates we actually send to the model (prompt
#                  size / generation cost scales with this).
# COMPARE_TOP    : how many we show in the coded-vs-AI "top N" diff table.
use constant CANDIDATE_CAP => 50;
use constant PROMPT_CAP    => 25;
use constant COMPARE_TOP    => 20;

# ===================================================================
# AI2::FocusTune — the ONE place that knows how to ask an AI model
# "what are the top 5 todos to do next, by FUNCTION".
#
# This used to live inside Controller::Api (api_focus_top5), which made
# it unreachable from the Chat-with-AI system. Now BOTH callers delegate
# here:
#   * Controller::Api  /api/focus/top5   (the AI Focus-Tune UI button)
#   * Model::AI2::Chat /ai2/chat          (when the user asks in chat)
#
# Every model execution goes through Router->dispatch_chat (the SAME
# provider path the chat widget uses) so Ollama / Grok / OpenRouter all
# work. There is NO default model — the caller must pass an explicit list.
# ===================================================================

# Gather CSC open todos, score them (for context only — NOT used as the
# ranking signal), and take the top 50 by ap_score as the candidate set.
sub gather_candidates {
    my ($self, $c, $now_epoch) = @_;
    $now_epoch //= time();

    my @cands;
    my %rbid;
    eval {
        my $schema = $c->model('DBEncy');
        my @rows = $schema->resultset('Todo')->search(
            { sitename => 'CSC', status => { '!=' => '3' } },
            { order_by => { -asc => ['priority'] }, rows => 5000 }
        )->all;
        %rbid = map { $_->record_id => { $_->get_columns } } @rows;
        for my $t (@rows) {
            my $h = $rbid{ $t->record_id };
            Comserv::Util::TodoRanking::score_todo($h, { now_epoch => $now_epoch, row_by_id => \%rbid });
            push @cands, $h;
        }
    };
    @cands = sort { ($a->{ap_score} // 0) <=> ($b->{ap_score} // 0) } @cands;
    my @top = splice(@cands, 0, CANDIDATE_CAP);
    return (\@top, \%rbid);
}

# Build the function-based prompt (judge by FUNCTION, ignore the inconsistent
# ap_score ranking). Returns ($system, $user_prompt).
# $top is the full candidate set (up to CANDIDATE_CAP); we send only the top
# PROMPT_CAP to the model — generation cost scales with prompt size, and the
# model only needs the most-relevant candidates to pick a strong top 5. Smaller
# context = faster generation = less CPU pegged per call.
sub build_prompt {
    my ($self, $c, $top, $plan_docs, $cap) = @_;
    $cap //= PROMPT_CAP;
    my @send = @$top;
    if (@send > $cap) { @send = @send[0 .. ($cap - 1)]; }

    my @lines;
    for my $h (@send) {
        push @lines, sprintf(
            "rec=%s | pri=%s | due=%s | proj=%s | subj=%s",
            $h->{record_id}, $h->{priority},
            substr($h->{due_date} // '', 0, 10),
            $h->{project_code} // $h->{project_id} // '',
            ($h->{subject} // '') =~ s/\n/ /gr
        );
    }
    my $todo_block = join("\n", @lines);

    my @plan_blocks;
    for my $pd (@$plan_docs) {
        my $head = "PLAN: " . ($pd->{title} // $pd->{name} // $pd->{path} // '?');
        $head .= " [plan_id=" . $pd->{plan_id} . "]" if defined $pd->{plan_id};
        $head .= " [status=" . ($pd->{status} // '?') . "]" if $pd->{status};
        $head .= " path=" . ($pd->{path} // '?');
        my @pb = ($head);
        if ($pd->{open_phase_todos} && @{$pd->{open_phase_todos}}) {
            push @pb, "  existing open todos for this plan:";
            for my $pt (@{$pd->{open_phase_todos}}) {
                push @pb, sprintf("    rec=%s | pri=%s | subj=%s",
                    $pt->{record_id}, $pt->{priority} // '?',
                    ($pt->{subject} // '') =~ s/\n/ /gr);
            }
        }
        if ($pd->{next_steps} && @{$pd->{next_steps}}) {
            push @pb, "  next steps named in the doc (may NOT yet be todos):";
            for my $ns (@{$pd->{next_steps}}) {
                push @pb, "    - " . $ns;
            }
        }
        push @plan_blocks, join("\n", @pb);
    }
    my $plan_block = join("\n\n", @plan_blocks);

    my $system = "You are the Comserv2 planning Focus-Tune. You are given (1) a list of OPEN "
                . "todos with their record_id, priority, due date, project, and subject, and "
                . "(2) the PLAN DOCS (on-disk .tt plan files + DB DailyPlan rows). The todos are "
                . "presented in NO particular order — the current code ranking is known to be "
                . "INCONSISTENT across todos and must NOT be trusted. Do NOT sort by the existing "
                . "score; judge each todo only on its FUNCTION: what actually moves the project "
                . "forward. Prefer work that unblocks other work, advances a documented plan's next "
                . "step, fixes a real defect, or delivers user-facing value. Deprioritize routine "
                . "noise, already-superseded work, and low-impact polish. "
                . "Return ONLY a JSON object (no prose, no markdown fence) with these keys:\n"
                . "  \"picks\": [ EXACTLY 5 objects (or fewer if fewer are truly important), each EITHER\n"
                . "      {\"record_id\": <int from rec=>, \"why\": \"<one short sentence: the FUNCTION it serves / what it unblocks>\"}  when picking an existing todo, OR\n"
                . "      {\"plan_item\": {\"title\":\"<plan name>\", \"step\":\"<specific next step>\", \"plan_id\": <int|null>, \"path\":\"<doc path|null>\"}, \"why\":\"<one short sentence>\"} when the best next action is a plan-doc step with NO todo yet ];\n"
                . "  \"proposed_order\": [ an array of the record_ids you judge most important FIRST, up to 15, most-important first — your own functional ordering, NOT the code score ];\n"
                . "  \"weights\": { a JSON object proposing better scoring weights for the code algorithm, keys: stale_90, stale_180, block, cross_block, due_overdue, due_today, due_soon, superseded, routine, status_tier — numeric. These RETUNE (not replace) the existing weights; explain reasoning in weights_why. };\n"
                . "  \"weights_why\": \"<one paragraph: why these weights better reflect what to build next>\";\n"
                . "  \"mis_set\": [ an array of {\"record_id\": <int>, \"issue\": \"<e.g. wrong priority / missing project / status should be done / looks routine-mislabelled>\"} — todos whose settings look WRONG and should be cleaned up (this backlog of mis-set todos is a known problem). Up to 15. ]\n"
                . "All record_ids MUST be from the rec= values provided. Judge by FUNCTION, not by the existing ranking.";
    my $user_prompt = "";
    $user_prompt .= "OPEN TODOS (presented in no particular order — judge by function, ignore any implied ranking):\n$todo_block\n\n" if $todo_block;
    $user_prompt .= "PLAN DOCS (current intentions):\n$plan_block\n\n" if $plan_block;
    $user_prompt .= "Pick the 5 todos that, by FUNCTION, most move the project forward. Also "
                  . "return your own functional ordering, proposed retuning weights + why, and the "
                  . "mis-set todos you would flag for cleanup.";

    return ($system, $user_prompt);
}

# Gather the plan-doc context: BOTH the on-disk planning corpus
# (root/Documentation/**/*.{tt,md} that look like plan docs) AND the DB
# DailyPlan rows (with their open phase todos). Relocated here from
# Controller::Api::_focus_top5_plan_docs so BOTH the /api/focus/top5 UI
# button and the Chat-with-AI focustune agent share ONE implementation
# (the controller is not a model and must not be called as one).
sub plan_docs {
    my ($self, $c) = @_;
    my @docs;

    # ── DB DailyPlan rows (planning-system plans) + their open phase todos ──
    eval {
        my $schema = $c->model('DBEncy');
        my @plans  = $schema->resultset('DailyPlan')->search(
            { status => { '!=' => 'completed' } },
            { order_by => { -desc => 'last_modified' }, rows => 50 }
        )->all;
        for my $pl (@plans) {
            my %h = (
                title   => $pl->plan_name,
                name    => $pl->plan_name,
                path    => 'DailyPlan:' . $pl->plan_name,
                plan_id => $pl->id,
                status  => $pl->status,
            );
            my @pt;
            eval {
                my @rows = $schema->resultset('Todo')->search(
                    { plan_id => $pl->id, status => { '!=' => '3' } },
                    { order_by => { -asc => 'priority' }, rows => 200 }
                )->all;
                @pt = map { { record_id => $_->record_id, priority => $_->priority,
                              subject => $_->subject } } @rows;
            };
            $h{open_phase_todos} = \@pt if @pt;
            push @docs, \%h;
        }
    };
    $c->log->warn("focustune: could not load DailyPlan rows: $@") if $@;

    # ── On-disk planning corpus (root/Documentation/**) ──
    eval {
        my $docs_root = $c->path_to('root', 'Documentation');
        my @tt_files;
        File::Find::find({
            wanted => sub {
                return unless -f $_;
                return unless /\.(tt|md)$/i;
                push @tt_files, $File::Find::name;
            },
            no_chdir => 1,
        }, $docs_root);

        my @planish = grep { m{([Pp]lan|roadmap|phase|strategy|design|proposal|todo)}i } @tt_files;
        my @chosen = @planish ? @planish : @tt_files;
        @chosen = @chosen[0 .. 60] if @chosen > 60;

        my $cap_bytes = 4_000;
        for my $f (@chosen) {
            my $raw;
            if (open my $fh, '<', $f) {
                my $bytes = read($fh, $raw, $cap_bytes);
                close $fh;
                $raw = defined $bytes ? $raw : '';
            }
            my $txt;
            try { $txt = decode('utf-8', $raw, Encode::FB_DEFAULT); }
            catch { $txt = $raw; };
            next unless defined $txt && length($txt) > 40;
            my $rel = $f;
            $rel =~ s{^\Q$docs_root\E/?}{}i;
            my @steps = map { s/^\s*[-*]\s*//r }
                        grep { /^\s*[-*]\s*\S/ && /next|todo|phase|step|task|implement|add|fix|create|wire/i }
                        split /\n/, $txt;
            push @docs, {
                title => $rel,
                name  => $rel,
                path  => 'Documentation/' . $rel,
                next_steps => [ @steps ? @steps[0 .. ($#steps > 9 ? 9 : $#steps)] : () ],
            };
        }
    };
    $c->log->warn("focustune: could not scan on-disk plan docs: $@") if $@;

    return @docs;
}

# Run one tuning pass for a single {model} target using the AI2 chat system
# (Router->dispatch_chat). Returns { model, success, response|error, provider }.
sub run_one {
    my ($self, $c, $target, $system, $user_prompt, $can_select) = @_;
    my $model = ref($target) ? $target->{name} : $target;
    my $out = { model => $model, host => (ref($target) ? ($target->{host} // '') : '') };

    my $router = $c->model('AI2::Router');
    my $resp;
    eval {
        $resp = $router->dispatch_chat($c, $model, [
            { role => 'system', content => $system },
            { role => 'user',   content => $user_prompt },
        ], can_select => ($can_select // 1));
        1;
    } or do {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'focustune_run_one',
            "dispatch_chat threw for $model: $@");
        $resp = undef;
    };

    if ($resp && $resp->{success}) {
        $out->{success}  = 1;
        $out->{response} = $resp->{response} // '';
        $out->{provider} = $resp->{provider} // '';
    } else {
        $out->{success} = 0;
        $out->{error} = ($resp && $resp->{error}) ? $resp->{error} : 'AI ranking unavailable';
    }
    return $out;
}

# Parse one AI result into the structured payload (picks/weights/comparison/
# mis_set/proposed_order). Shared by both single + batch responses.
sub parse_result {
    my ($self, $c, $res, $top, $rbid, $now_epoch) = @_;
    $now_epoch //= time();

    my $out = { success => ($res->{success} ? 1 : 0), model => $res->{model} // '' };
    unless ($res && $res->{success}) {
        $out->{error} = $res->{error} // 'AI ranking unavailable';
        return $out;
    }
    my $raw = $res->{response} // '';
    $raw =~ s/^```(?:json)?\s*//i; $raw =~ s/\s*```$//;
    my $parsed;
    eval { require JSON; $parsed = JSON::decode_json($raw); };
    $parsed = {} unless ref($parsed) eq 'HASH';
    my %valid = map { $_->{record_id} => 1 } @$top;

    my @picks;
    my $picks_ref = ref($parsed->{picks}) eq 'ARRAY' ? $parsed->{picks} : [];
    for my $p (@$picks_ref) {
        next unless ref($p) eq 'HASH';
        if ($p->{record_id} && $valid{$p->{record_id}}) {
            push @picks, { type => 'todo', record_id => $p->{record_id} + 0, why => $p->{why} // '' };
        }
        elsif ($p->{plan_item} && ref($p->{plan_item}) eq 'HASH' && $p->{plan_item}{step}) {
            push @picks, {
                type    => 'plan_item',
                title   => $p->{plan_item}{title}    // '',
                step    => $p->{plan_item}{step},
                plan_id => (defined $p->{plan_item}{plan_id} ? $p->{plan_item}{plan_id} + 0 : undef),
                path    => $p->{plan_item}{path}     // undef,
                why     => $p->{why} // '',
            };
        }
        last if @picks >= 5;
    }

    my %ai_weights;
    if (ref($parsed->{weights}) eq 'HASH') {
        for my $k (qw(stale_90 stale_180 block cross_block due_overdue due_today due_soon superseded routine status_tier)) {
            my $v = $parsed->{weights}{$k};
            $ai_weights{$k} = $v + 0 if defined $v && $v =~ /^[-+]?\d+(\.\d+)?$/;
        }
    }

    my @coded_top = map { { record_id => $_->{record_id}, subject => $_->{subject} // '', ap_score => $_->{ap_score} // 0 } }
                     @$top[0 .. ($#$top > (COMPARE_TOP - 1) ? (COMPARE_TOP - 1) : $#$top)];

    my @simulated = map { { %$_ } } @$top;
    if (%ai_weights) {
        for my $h (@simulated) {
            Comserv::Util::TodoRanking::score_todo($h, {
                now_epoch => $now_epoch, row_by_id => $rbid, weights => \%ai_weights,
            });
        }
        @simulated = sort { ($a->{ap_score} // 0) <=> ($b->{ap_score} // 0) } @simulated;
    }
    my @sim_top = map { { record_id => $_->{record_id}, subject => $_->{subject} // '', ap_score => $_->{ap_score} // 0 } }
                 @simulated[0 .. ($#simulated > (COMPARE_TOP - 1) ? (COMPARE_TOP - 1) : $#simulated)];

    my @mis_set;
    if (ref($parsed->{mis_set}) eq 'ARRAY') {
        for my $m (@{$parsed->{mis_set}}) {
            next unless ref($m) eq 'HASH' && $m->{record_id} && $valid{$m->{record_id}};
            push @mis_set, { record_id => $m->{record_id} + 0, issue => $m->{issue} // '' };
        }
    }

    my @proposed_order = grep { $valid{$_} } map { $_ + 0 }
                         grep { /^\d+$/ } @{ ref($parsed->{proposed_order}) eq 'ARRAY' ? $parsed->{proposed_order} : [] };

    $out->{picks}          = \@picks;
    $out->{proposed_order} = \@proposed_order;
    $out->{weights}        = \%ai_weights;
    $out->{weights_why}    = $parsed->{weights_why} // '';
    $out->{comparison}     = {
        coded_top20     => \@coded_top,
        simulated_top20 => \@sim_top,
        note => 'SIMULATED only — nothing was written. Compare coded vs AI-weighted order before applying any change. The AI weights RETUNE the existing scorer, they do not replace it.',
    };
    $out->{mis_set_todos}  = \@mis_set;
    return $out;
}

__PACKAGE__->meta->make_immutable;

1;

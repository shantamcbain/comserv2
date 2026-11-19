package Comserv::Util::AI::ReviewRun;

# ============================================================================
# Comserv::Util::AI::ReviewRun - the actual commit-review run for CodeReviewer.
#
# WHAT: review() walks an ordered list of reviewer attempts, records every
#       attempt and returns the same result hash CodeReviewer::review used to
#       build. should_block()/gate_view() are the fail-closed policy helpers.
#
# WHY:  a commit went in with "Not reviewed: review call failed: OpenRouter
#       reply cut off ... finish_reason=length. Commit is allowed." A single
#       truncated reply must not mean "not reviewed".
#
# FAIL CLOSED: every commit is either reviewed or blocked. Only an empty diff
#       passes without review (nothing to review). A disabled reviewer also
#       blocks - silence is not approval.
#
# MODEL ORDER: primary at max_tokens 8000, primary again at 12000 (room to
#       finish), the alternate, then free coding models from
#       data/ai_model_chains.json chain_coding via ReviewGate. Vendor
#       independence is enforced at every step (never review your own vendor).
#
# CAP: a paid step whose worst-case estimate would pass the daily cap is
#       skipped; the free reviewer still runs. The result records which model
#       actually produced the review.
#
# 2026-11-18  todo #2761
# ============================================================================

use strict;
use warnings;

use Comserv::Util::AI::ReviewGate ();

# Parse helper: CodeReviewer is required lazily (it delegates back to us).
sub _parse_reply {
    my ($text) = @_;
    my $ok = eval { require Comserv::Util::AI::CodeReviewer; 1 };
    return undef unless $ok;
    return Comserv::Util::AI::CodeReviewer::parse_reply($text);
}

# review($c, diff => ..., author_models => [..], task => '', source => ...)
sub review {
    my ($class, $s, $c, %a) = @_;

    my $cfg = $s->config;
    my ($spent) = $s->spent_today;
    my $base = { cap => $cfg->{cap_usd_per_day}, spent_today => $spent, mode => ($cfg->{mode} // 'warn') };

    return { %$base, ok => 0, skipped => 1, disabled => 1,
             reason => 'reviewer disabled (data/ai_reviewer.json enabled=0)' }
        unless $cfg->{enabled};

    return { %$base, ok => 0, skipped => 1, empty_diff => 1, reason => 'empty diff' }
        unless defined $a{diff} && $a{diff} =~ /\S/;

    my @free = Comserv::Util::AI::ReviewGate->free_models(
        root  => $s->root,
        extra => $cfg->{free_models} || [],
    );
    my @steps = Comserv::Util::AI::ReviewGate->steps(
        cfg           => $cfg,
        author_models => $a{author_models},
        free_models   => \@free,
    );
    return { %$base, ok => 0, skipped => 1,
             reason => 'no independent reviewer: author vendor matches every reviewer model' }
        unless @steps;

    my ($msgs, $cut) = $s->build_messages(diff => $a{diff}, task => $a{task}, repo_note => $a{repo_note});
    my $chars = 0;
    $chars += length($_->{content} // '') for @$msgs;

    my $prov = $a{provider} || eval { $c->model('AI2::Provider::OpenRouter') };
    return { %$base, ok => 0, skipped => 1, reason => 'OpenRouter provider unavailable' }
        unless $prov;

    my $cap = $cfg->{cap_usd_per_day};
    my @attempts;
    my $total_usd = 0;
    my $cap_hit;
    my $calls = 0;
    my $last_raw;

    for my $step (@steps) {
        my $model = $step->{model};
        my $max   = $step->{max_tokens};
        my $why   = $step->{why};
        my $free  = Comserv::Util::AI::ReviewGate->is_free($model);

        my ($spent_now) = $s->spent_today;

        if (!$free) {
            my $est = $s->estimate_usd($model, $chars, $max);
            if ($spent_now + $est > $cap) {
                $cap_hit = sprintf('daily cap: spent $%.4f + up to $%.4f would pass the $%.2f cap; resets 00:00 PT',
                                   $spent_now, $est, $cap)
                    unless defined $cap_hit;
                push @attempts, { model => $model, why => $why, max_tokens => $max, result => 'skipped: daily cap' };
                next;
            }
        }

        my $t0 = time;
        my $r  = $prov->chat($c, model => $model, messages => $msgs, max_tokens => $max, purpose => 'code_review');
        $r = {} unless ref $r eq 'HASH';
        $calls++;

        my $u  = ref $r->{usage} eq 'HASH' ? $r->{usage} : {};
        my $pt = 0 + ($u->{prompt_tokens} // 0);
        my $ct = 0 + ($u->{completion_tokens} // 0);
        my $p  = $cfg->{prices}{$model}
              || ($free ? { in => 0, out => 0 } : { in => 15, out => 75 });
        my $usd = defined $u->{cost} ? 0 + $u->{cost} : ($pt * $p->{in} + $ct * $p->{out}) / 1e6;
        $s->_add_spend($usd) if $pt || $ct || $usd;
        $total_usd += $usd;

        my $failed = $r->{success} ? 0 : 1;
        my $rev = $failed ? undef : _parse_reply($r->{response});
        my $err = $failed ? ($r->{error} // '?') : ($rev ? undef : 'unparseable review reply');

        eval {
            my $usage = $a{usage_model} || $c->model('AI::Usage');
            $usage->log($c,
                provider            => 'openrouter',
                model               => $model,
                prompt_tokens       => $pt,
                completion_tokens   => $ct,
                estimated_cost_usd  => $usd,
                duration_ms         => (time - $t0) * 1000,
                request_type        => 'code_review',
                status              => ($err ? 'error' : 'success'),
                error_message       => $err,
                metadata            => {
                    feature          => 'code_reviewer',
                    source           => ($a{source} // 'manual'),
                    author_models    => $a{author_models} || [],
                    reviewer_pick    => $why,
                    diff_chars       => length($a{diff}),
                    diff_cut         => ($cut ? 1 : 0),
                    cap_usd_per_day  => $cap,
                    reviewer_step    => $why,
                    max_tokens       => $max,
                    attempt          => $calls,
                });
            1;
        };

        if ($failed) {
            push @attempts, { model => $model, why => $why, max_tokens => $max,
                              result => 'error: ' . ($r->{error} // '?') };
            next;
        }
        if (!$rev) {
            push @attempts, { model => $model, why => $why, max_tokens => $max, result => 'unparseable' };
            $last_raw = substr($r->{response} // '', 0, 3000);
            next;
        }

        my $high = grep { ($_->{severity} // '') =~ /high/i } @{ $rev->{findings} || [] };
        $s->append_score({
            at             => time,
            author_models  => [ grep { defined && length } @{ $a{author_models} || [] } ],
            reviewer_model => $model,
            source         => ($a{source} // 'manual'),
            files          => $a{files} || [],
            correctness    => $rev->{correctness},
            security       => $rev->{security},
            quality        => $rev->{quality},
            verdict        => $rev->{verdict},
            high_findings  => $high,
            diff_sha       => $a{diff_sha},
            override       => 0,
        });

        push @attempts, { model => $model, why => $why, max_tokens => $max, result => 'ok' };
        my ($now) = $s->spent_today;
        return { %$base, ok => 1, model => $model, pick => $why,
                 usd => sprintf('%.5f', $total_usd) + 0, spent_today => $now,
                 diff_cut => ($cut ? 1 : 0), review => $rev, raw => undef,
                 attempts => \@attempts, cap_hit => ($cap_hit ? 1 : 0) };
    }

    my ($now) = $s->spent_today;
    my $reason = ($cap_hit && !$calls)
        ? "daily cap reached and no free reviewer model: $cap_hit"
        : 'all reviewer models failed: ' . join('; ', map { "$_->{model} ($_->{why}): $_->{result}" } @attempts);
    my $last_model = @attempts ? $attempts[-1]{model} : undef;

    return { %$base, ok => 0, skipped => ($calls ? 0 : 1), failed => 1,
             model => $last_model, usd => sprintf('%.5f', $total_usd) + 0, spent_today => $now,
             attempts => \@attempts, cap_hit => ($cap_hit ? 1 : 0), raw => $last_raw, reason => $reason };
}

# Fail closed in ANY mode: only an empty diff (or an actual parsed review that
# the block-mode rules reject) may pass. A missing/failed/skipped review blocks.
sub should_block {
    my ($class, $s, $res) = @_;

    return 0 if ref $res eq 'HASH'
             && ($res->{empty_diff} || (($res->{reason} // '') eq 'empty diff'));

    return 1 unless ref $res eq 'HASH' && $res->{ok} && ref $res->{review} eq 'HASH';

    return 0 unless ($s->config->{mode} // '') eq 'block';

    my $rev = $res->{review};
    return 1 if ($rev->{security} // 5) < 4;
    return 1 if ($rev->{correctness} // 5) < 3;
    for my $f (@{ $rev->{findings} || [] }) {
        return 1 if ref $f eq 'HASH' && ($f->{severity} // '') =~ /high/i;
    }
    return 0;
}

# 2026-10-15: what the AI Editor commit form shows. Pure, testable.
# Fail closed: an unreviewed commit is blocked (even if the caller passed
# blocking => 0) and offers Retry review. Only an empty diff is a non-blocking
# "not reviewed". A parsed review in block mode with a high finding / low
# security / low correctness is blocked, commit only with "commit anyway".
sub gate_view {
    my ($class, $s, $res) = @_;
    $res = {} unless ref $res eq 'HASH';

    my $empty = ($res->{empty_diff} || (($res->{reason} // '') eq 'empty diff')) ? 1 : 0;
    my $rev   = ref $res->{review} eq 'HASH' ? $res->{review} : {};
    my $not_reviewed = (!$empty && !($res->{ok} && ref $res->{review} eq 'HASH')) ? 1 : 0;

    my @f = map { { severity => $_->{severity} // '', file => $_->{file} // '', line => $_->{line} // '',
                    issue => $_->{issue} // $_->{message} // $_->{text} // $_->{reason} // '' } }
            grep { ref $_ eq 'HASH' } @{ $rev->{findings} || [] };

    my $blocking = $not_reviewed ? 1
                 : $empty        ? 0
                 : (($res->{blocking} // $s->should_block($res)) ? 1 : 0);

    my $warning = $not_reviewed
        ? 'Not reviewed, commit blocked: ' . ($res->{reason} // 'no review') . '. Click Retry review.'
        : $empty
        ? 'Not reviewed: empty diff (nothing to review).'
        : '';

    return {
        reviewed    => ($not_reviewed || $empty) ? 0 : 1,
        blocking    => $blocking,
        allow       => $blocking ? 0 : 1,
        warning     => $warning,
        verdict     => $rev->{verdict} // '',
        scores      => { correctness => $rev->{correctness}, security => $rev->{security}, quality => $rev->{quality} },
        findings    => \@f,
        model       => $res->{model} // '',
        usd         => $res->{usd} // 0,
        spent_today => $res->{spent_today},
        cap         => $res->{cap},
        not_reviewed => $not_reviewed,
        retry       => $not_reviewed,
        empty_diff  => $empty,
        pick        => $res->{pick} // '',
        attempts    => $res->{attempts} || [],
    };
}

1;

__END__

=head1 NAME

Comserv::Util::AI::ReviewRun - fail-closed commit review run for CodeReviewer.

=head1 SYNOPSIS

    my $res = Comserv::Util::AI::ReviewRun->review($reviewer, $c,
        diff => $diff, author_models => \@authors, task => $task);

    my $blocked = Comserv::Util::AI::ReviewRun->should_block($reviewer, $res);
    my $view    = Comserv::Util::AI::ReviewRun->gate_view($reviewer, $res);

=head1 DESCRIPTION

Walks the ordered reviewer attempts from L<Comserv::Util::AI::ReviewGate>
(primary, primary retry with a larger budget, alternate, then free coding
models) and returns the first parsed review. Every commit is either reviewed
or blocked; only an empty diff passes without review, and a disabled reviewer
also blocks. Paid steps whose worst-case estimate would pass the daily cap are
skipped while free reviewers still run.

=cut

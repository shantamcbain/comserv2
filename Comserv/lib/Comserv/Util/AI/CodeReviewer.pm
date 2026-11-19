package Comserv::Util::AI::CodeReviewer;

# In-app code reviewer (Oct 12 2026, eval #34). Shanta approved 9:35 AM PT:
# "Review at commit with Sonnet 5.5, $0.50/day cap".
#   - Runs ONLY when asked at commit time (pre-commit hook endpoint / button),
#     never on every change.
#   - Primary anthropic/claude-sonnet-5.5, alternate openai/gpt-6-sol
#     (data/ai_reviewer.json). Never reviews output written by a model of its
#     own vendor: that step is skipped.
#   - Hard daily cap (cap_usd_per_day, PT calendar day). A paid call is refused
#     if spent + worst-case estimate would pass the cap (free models still run).
#   - Every call goes through Provider::OpenRouter->chat (Ledger audit row,
#     purpose code_review) and also writes its own Ledger row via
#     AI::Usage->log (request_type code_review) so it shows as its own usage.
#   - 2026-11-18 todo #2761: fail closed. Every commit is reviewed or blocked
#     (only an empty diff passes unreviewed; reviewer disabled also blocks).
#     review/should_block/gate_view live in Comserv::Util::AI::ReviewRun:
#     primary at max_tokens (8000), primary again at 12000 after a cut-off or
#     failure, alternate, then free coding models from data/ai_model_chains.json
#     (Comserv::Util::AI::ReviewGate). Vendor independence at every step. When
#     the daily cap is hit, paid steps are skipped and the free reviewer runs.
#     The result records which model gave the review (model, pick, attempts).
#   - mode 'block' also refuses a parsed review with a high finding, security
#     below 4, or correctness below 3. The fixer is a third vendor and returns
#     a diff only; it does not write files.
# Spend counter: data/ai_reviewer_spend.json { "YYYY-MM-DD": {usd, calls} }.

use strict;
use Comserv::Util::AppTime ();
use warnings;
use JSON::PP ();
use POSIX qw(strftime);
use Fcntl qw(:flock);
use Comserv::Util::AI::ReviewRun ();

my $J = JSON::PP->new->canonical->allow_nonref;

sub new { my ($class, %a) = @_; return bless { %a }, $class }
sub root { my $r = $_[0]{root} || '.'; $r =~ s{/$}{}; $r }
sub config_file { $_[0]->root . '/data/ai_reviewer.json' }
sub spend_file  { $_[0]->root . '/data/ai_reviewer_spend.json' }

sub _read_json { my ($f) = @_; open my $fh, '<', $f or return undef; local $/; my $d = eval { $J->decode(<$fh>) }; close $fh; $d }

sub config {
    my ($s) = @_;
    my $c = _read_json($s->config_file) || {};
    return { enabled => 0, mode => 'warn', cap_usd_per_day => 0.50, primary => 'anthropic/claude-sonnet-5.5',
             alternate => 'openai/gpt-6-sol', fixer => 'cohere/north-mini-code:free',
             prices => {}, max_diff_chars => 60000, max_tokens => 8000, free_models => [], %$c };
}

sub today_pt { local $ENV{TZ} = Comserv::Util::AppTime->app_tz; POSIX::tzset(); my $d = strftime('%Y-%m-%d', localtime($_[1] // time)); POSIX::tzset(); $d }

sub spent_today {
    my ($s) = @_;
    my $all = _read_json($s->spend_file) || {};
    my $d = $all->{ $s->today_pt } || {};
    return ($d->{usd} || 0, $d->{calls} || 0);
}

sub _add_spend {
    my ($s, $usd) = @_;
    my $f = $s->spend_file;
    open my $lk, '>>', "$f.lock" or return;
    flock $lk, LOCK_EX;
    my $all = _read_json($f) || {};
    my $d = $all->{ $s->today_pt } ||= { usd => 0, calls => 0 };
    $d->{usd} = sprintf('%.6f', $d->{usd} + ($usd || 0)) + 0;
    $d->{calls}++;
    if (open my $fh, '>', "$f.tmp") { print $fh $J->pretty->encode($all); close $fh; rename "$f.tmp", $f }
    close $lk;
}

# vendor('openrouter/anthropic/claude-sonnet-5.5') -> 'anthropic'
sub vendor {
    my ($m) = @_;
    $m = lc($m // '');
    $m =~ s{^[^|]+\|}{};
    $m =~ s{^openrouter/}{};
    return 'xai'       if $m =~ /grok|^x-ai\//;
    return 'anthropic' if $m =~ /claude|sonnet|opus|haiku|fable|^anthropic\//;
    return 'openai'    if $m =~ /^openai\/|\bgpt|\bcodex|^o\d/;
    return 'z-ai'      if $m =~ /glm|^z-ai\//;
    return 'google'    if $m =~ /gemini|gemma|^google\//;
    return 'deepseek'  if $m =~ /deepseek/;
    return 'qwen'      if $m =~ /qwen/;
    return 'nvidia'    if $m =~ /nemotron|^nvidia\//;
    return 'cohere'    if $m =~ /north-mini|cohere/;
    return 'moonshot'  if $m =~ /kimi|moonshot/;
    return $1          if $m =~ m{^([\w.\-]+)/};
    return $m;
}

# pick_model(author_models => [..]) -> ($model, $reason) ; $model undef = skip
sub pick_model {
    my ($s, %a) = @_;
    my $cfg = $s->config;
    my %av = map { vendor($_) => 1 } grep { defined && length } @{ $a{author_models} || [] };
    for my $m ($cfg->{primary}, $cfg->{alternate}) {
        next unless $m;
        return ($m, ($m eq $cfg->{primary} ? 'primary' : 'alternate (primary is the author vendor)')) unless $av{ vendor($m) };
    }
    return (undef, 'no independent reviewer: author vendor matches primary and alternate');
}

sub estimate_usd {
    my ($s, $model, $in_chars, $out_tokens) = @_;
    my $p = $s->config->{prices}{$model} || { in => 15, out => 75 };   # unknown price -> assume expensive
    return ($in_chars / 3.5) / 1e6 * $p->{in} + ($out_tokens // 0) / 1e6 * $p->{out};
}

sub build_messages {
    my ($s, %a) = @_;
    my $sys = join("\n",
        'You are a strict senior code reviewer for a Perl Catalyst app (Comserv: DBIx::Class, Template Toolkit, JS).',
        'Review ONLY the diff given. Score 0-5 each: correctness, security, quality (5 = no problems).',
        'List concrete findings with file, line (from the hunk), severity (high|medium|low) and a one-line reason.',
        'Flag: raw SQL in app code, secrets/credentials in code, missing input checks, XSS in templates (missing | html),',
        'broken Try::Tiny returns, logic errors, and code that cannot run.',
        'Reply with JSON only: {"correctness":n,"security":n,"quality":n,"verdict":"pass|warn","summary":"...",',
        '"findings":[{"file":"","line":0,"severity":"","reason":""}]}',
        'A file or module that is absent from the diff may already exist in the repository. Do not report it as missing or uncommitted unless the repository facts say it does not exist.');
    my $diff = $a{diff} // '';
    my $max = $s->config->{max_diff_chars} || 60000;
    my $cut = length($diff) > $max;
    $diff = substr($diff, 0, $max) . "\n... [diff cut at $max chars]" if $cut;
    my $facts = $a{repo_note} // '';
    my $user = ($a{task} ? "Task the change was for:\n$a{task}\n\n" : '')
             . ($facts =~ /\S/ ? "Repository facts:\n$facts\n\n" : '')
             . "Diff:\n$diff";
    return ([ { role => 'system', content => $sys }, { role => 'user', content => $user } ], $cut);
}

sub parse_reply {
    my ($text) = @_;
    return undef unless defined $text;
    my $j = eval { $J->decode($text) };
    if (!$j && $text =~ /(\{.*\})/s) { $j = eval { $J->decode($1) } }
    return undef unless ref $j eq 'HASH';
    for my $k (qw(correctness security quality)) { $j->{$k} = 0 + ($j->{$k} // 0) }
    $j->{findings} = [] unless ref $j->{findings} eq 'ARRAY';
    $j->{verdict} = ($j->{verdict} // '') =~ /pass/i ? 'pass' : 'warn';
    return $j;
}

# review($c, diff => ..., author_models => [..], task => '', source => 'commit_gate')
# -> { ok, skipped?, reason?, model, review => {...}, usd, spent_today, cap }
sub review { my ($s, $c, %a) = @_; return Comserv::Util::AI::ReviewRun->review($s, $c, %a) }

sub scores_file { $_[0]->root . '/data/ai_review_scores.json' }

sub append_score {
    my ($s, $row) = @_;
    return unless ref $row eq 'HASH';
    my $f = $s->scores_file;
    open my $lk, '>>', "$f.lock" or return;
    flock $lk, LOCK_EX;
    my $all = _read_json($f);
    $all = [] unless ref $all eq 'ARRAY';
    unshift @$all, $row;
    splice @$all, 500 if @$all > 500;
    if (open my $fh, '>', "$f.tmp") {
        print $fh $J->pretty->encode($all);
        close $fh;
        rename "$f.tmp", $f;
    }
    close $lk;
}

# Means per author model. Empty file => empty list, never a fake zero.
sub scores_by_author {
    my ($s) = @_;
    my $all = _read_json($s->scores_file);
    return [] unless ref $all eq 'ARRAY' && @$all;
    my %g;
    for my $row (@$all) {
        next unless ref $row eq 'HASH';
        my @authors = grep { defined && length } @{ $row->{author_models} || [] };
        @authors = ('(unknown author)') unless @authors;
        for my $m (@authors) {
            my $g = $g{$m} ||= { model => $m, n => 0, correctness => 0, security => 0, quality => 0, high => 0, overrides => 0 };
            $g->{n}++;
            $g->{correctness} += $row->{correctness} || 0;
            $g->{security}    += $row->{security} || 0;
            $g->{quality}     += $row->{quality} || 0;
            $g->{high}        += $row->{high_findings} || 0;
            $g->{overrides}   += $row->{override} ? 1 : 0;
        }
    }
    for my $g (values %g) {
        next unless $g->{n};
        $g->{$_} = sprintf('%.1f', $g->{$_} / $g->{n}) for qw(correctness security quality);
    }
    return [ sort { $b->{n} <=> $a->{n} || $a->{model} cmp $b->{model} } values %g ];
}

# Fail closed (todo #2761): see Comserv::Util::AI::ReviewRun::should_block.
sub should_block { my ($s, $res) = @_; return Comserv::Util::AI::ReviewRun->should_block($s, $res) }

# What the AI Editor commit form shows; unreviewed = blocked + Retry review (todo #2761).
sub gate_view { my ($s, $res) = @_; return Comserv::Util::AI::ReviewRun->gate_view($s, $res) }

# Third-vendor repair. Returns a unified diff. Does not write the worktree.
sub propose_fix {
    my ($s, $c, %a) = @_;
    my $cfg = $s->config;
    my ($spent) = $s->spent_today;
    my $fixer = $cfg->{fixer} || 'cohere/north-mini-code:free';
    $fixer = 'cohere/north-mini-code:free' if $fixer =~ /v4-pro/i;  # 2026-10-15: never v4-pro
    my %busy = map { vendor($_) => 1 } grep { defined && length } @{ $a{author_models} || [] };
    $busy{ vendor($a{reviewer_model}) } = 1 if $a{reviewer_model};
    return { ok => 0, skipped => 1, reason => 'no independent fixer: fixer vendor matches the author or the reviewer' }
        if $busy{ vendor($fixer) };
    return { ok => 0, skipped => 1, reason => 'empty diff' } unless defined $a{diff} && $a{diff} =~ /\S/;
    my $findings = $a{findings};
    $findings = [] unless ref $findings eq 'ARRAY';
    my $list = join("\n", map {
        ref $_ eq 'HASH' ? sprintf('%s %s:%s %s', $_->{severity} // '', $_->{file} // '', $_->{line} // '', $_->{reason} // '') : ''
    } @$findings);
    my $sys = join("\n",
        'You repair a Perl Catalyst diff. Return a unified diff only. No prose.',
        'Fix only the listed findings. Do not add features, rename files, or touch paths outside the diff.',
        'If you cannot fix it safely, return an empty reply.');
    my $user = "Findings:\n$list\n\nDiff:\n" . substr($a{diff}, 0, ($cfg->{max_diff_chars} || 60000));
    my $msgs = [ { role => 'system', content => $sys }, { role => 'user', content => $user } ];
    my $chars = length($sys) + length($user);
    my $est = $s->estimate_usd($fixer, $chars, $cfg->{max_tokens});
    if ($spent + $est > $cfg->{cap_usd_per_day}) {
        return { ok => 0, skipped => 1, model => $fixer, reason => 'daily cap reached; fixer not called' };
    }
    my $prov = eval { $c->model('AI2::Provider::OpenRouter') };
    return { ok => 0, skipped => 1, reason => 'OpenRouter provider unavailable' } unless $prov;
    my $r = $prov->chat($c, model => $fixer, messages => $msgs, max_tokens => $cfg->{max_tokens}, purpose => 'code_review');
    my $u = ref $r->{usage} eq 'HASH' ? $r->{usage} : {};
    my $pt = 0 + ($u->{prompt_tokens} // 0); my $ct = 0 + ($u->{completion_tokens} // 0);
    my $p = $cfg->{prices}{$fixer} || { in => 15, out => 75 };
    my $usd = defined $u->{cost} ? 0 + $u->{cost} : ($pt * $p->{in} + $ct * $p->{out}) / 1e6;
    $s->_add_spend($usd) if $pt || $ct || $usd;
    return { ok => 0, model => $fixer, reason => 'fixer call failed: ' . ($r->{error} // '?') } unless $r->{success};
    my $text = $r->{response} // '';
    my $patch = $text;
    if ($text =~ /\x60\x60\x60(?:diff)?\s*\n(.+?)\x60\x60\x60/s) { $patch = $1 }
    $patch =~ s/^\s+|\s+$//g;
    return { ok => 0, model => $fixer, usd => $usd, reason => 'fixer did not return a diff' }
        unless $patch =~ /^(?:diff --git|--- )/m;
    return { ok => 0, model => $fixer, reason => 'fixer patch has an unsafe path' }
        if $patch =~ m{(?:^|\n)(?:diff --git|---) [ab]/(\.\./|/)} || $patch =~ m{(?:^|\n)\+\+\+ [ab]/(\.\./|/)};
    return { ok => 1, model => $fixer, usd => sprintf('%.5f', $usd) + 0, patch => $patch };
}

1;

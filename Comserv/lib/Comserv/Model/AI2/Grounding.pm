package Comserv::Model::AI2::Grounding;

use strict;
use warnings;
use utf8;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use POSIX qw(strftime);
use JSON qw(decode_json);
use Comserv::Util::AI::Glossary;

extends 'Catalyst::Model';

use constant MAX_SNIPPETS => 6;
use constant MAX_TOTAL_CHARS => 6000;
use constant MAX_SNIPPET_CHARS => 1500;
use constant FALLBACK_NO_GOLDEN => q{I don't have golden data for this yet, so I can't give you a verified answer.};
use constant CANDIDATE_ONLY_PREFIX => q{Unverified — Candidate Data only (no Golden Data matched this question): };
# MODES documented only: off, shadow, enforce (default shadow)

has logger => (
    is      => 'rw',
    lazy    => 1,
    default => sub {
        require Comserv::Util::Logging;
        Comserv::Util::Logging->instance;
    },
);

has golden_store => (
    is      => 'rw',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI2::GoldenData;
        Comserv::Model::AI2::GoldenData->new;
    },
);

has config_override => (
    is      => 'rw',
    isa     => 'Maybe[HashRef]',
    default => undef,
);

=head1 NAME

Comserv::Model::AI2::Grounding - Grounding model for AI2 to enforce use of Golden Data and Candidate Data, preventing Hallucination and Ungrounded Generation.

=head1 DESCRIPTION

Implements retrieval of Golden Data (human-agreed truth), Candidate Data, prior stored web hits, and optional live web search. Builds Grounding Context payload for the Router. Supports modes (off/shadow/enforce), factual intent detection, post-check citation enforcement, and Ledger logging. All public methods catch errors and log via logger->log_with_details. Never dies from public methods. Uses DBIx::Class resultsets only (no raw SQL). No JS.

=cut

=head2 load_config

Load grounding configuration. Returns config_override if set. Otherwise reads JSON from $c->path_to('root','config','ai_grounding.json') if present and merges over defaults. On bad JSON logs warn and returns defaults.

=cut

sub load_config {
    my ($self, $c) = @_;
    my $sub_name = 'load_config';

    if (defined $self->config_override) {
        return $self->config_override;
    }

    my %defaults = (
        mode             => 'shadow',
        max_snippets     => MAX_SNIPPETS,
        max_total_chars  => MAX_TOTAL_CHARS,
        postcheck_action => 'strip',
        web_search       => 1,
    );

    if ($c && $c->can('path_to')) {
        my $p = $c->path_to('root', 'config', 'ai_grounding.json');
        if (-f "$p") {
            my $json_text = '';
            if (open my $fh, '<:encoding(UTF-8)', "$p") {
                local $/;
                $json_text = <$fh>;
                close $fh;
            }
            if ($json_text) {
                # NB: a `return` inside try{} only leaves the try block, so
                # capture the parsed config and return after it.
                my $cfg = try { decode_json($json_text) }
                catch {
                    $self->logger->log_with_details($c, 'warn', __FILE__, __LINE__, $sub_name, "Bad JSON in ai_grounding.json: $_");
                    undef;
                };
                return { %defaults, %$cfg } if ref $cfg eq 'HASH';
            }
        }
    }

    return \%defaults;
}

=head2 is_factual_intent

Return 1 for factual lookup-style prompts (what is, who is, define, policy, dosage, etc.). Return 0 for creative prompts (brainstorm, poem, story, imagine, write a song, etc.) or when $args{creative} is true. Default 0.

=cut

sub is_factual_intent {
    my ($self, $prompt, %args) = @_;
    return 0 if $args{creative};
    my $p = $prompt // '';
    if ($p =~ /\b(brainstorm|poem|story|imagine|ideas?\s+for|write\s+(?:a|me)\s+(?:song|poem|story|joke)|slogan|joke|rewrite|rephrase|draft\s+an?\s+email)\b/i) {
        return 0;
    }
    if ($p =~ /\b(what\s+is|what\s+are|who\s+is|who\s+was|when\s+(?:did|was|is)|where\s+is|how\s+many|how\s+much|define|definition|tell\s+me\s+about|information\s+on|info\s+on|used\s+for|look\s*up|find|search\s+for|is\s+it\s+true|policy|dosage|price\s+of)\b/i) {
        return 1;
    }
    return 0;
}

=head2 resolve_mode

Resolve effective grounding mode from args (grounding, creative, agent_id, skip_app_writes) and config. Order: skip_app_writes or code/programming/etc agent_id -> off; grounding=off/0 -> off; creative -> shadow; grounding=enforce/1 -> enforce; grounding=shadow -> shadow; else config mode (validated) or shadow.

=cut

sub resolve_mode {
    my ($self, $c, %args) = @_;
    my $mode = 'shadow';

    if ($args{skip_app_writes} || (defined $args{agent_id} && $args{agent_id} =~ /^(code|programming|documentation|analyze|focustune)$/i)) {
        $mode = 'off';
    }
    elsif (defined $args{grounding} && ($args{grounding} eq 'off' || $args{grounding} eq '0')) {
        $mode = 'off';
    }
    elsif ($args{creative}) {
        $mode = 'shadow';
    }
    elsif (defined $args{grounding} && ($args{grounding} eq 'enforce' || $args{grounding} eq '1')) {
        $mode = 'enforce';
    }
    elsif (defined $args{grounding} && $args{grounding} eq 'shadow') {
        $mode = 'shadow';
    }
    else {
        my $cfg = $self->load_config($c);
        my $cm = $cfg->{mode} // 'shadow';
        $mode = (grep { $_ eq $cm } qw(off shadow enforce)) ? $cm : 'shadow';
    }

    return $mode;
}

=head2 retrieve

Build snippets list from Golden Data (list_golden, status must be 'golden' for label GOLDEN), then Candidate Data (list_candidates), prior WebSearchResult, then (if web_search) live _do_web_search. Each snippet: {id, label, source, retrieved_at, title, text}. Stop at max_snippets or max_total_chars (truncate last if >200 chars remain). Return {snippets, golden_hit_count, candidate_hit_count, golden_table_missing}. Push progress to thinking. All errors caught/logged.

=cut

sub retrieve {
    my ($self, $c, %args) = @_;
    my $q          = $args{query} // '';
    my $do_web     = $args{web_search} // 1;
    my $thinking   = $args{thinking} // [];
    my $sub_name   = 'retrieve';

    my $cfg        = $self->load_config($c);
    my $max_snips  = $cfg->{max_snippets} // MAX_SNIPPETS;
    my $max_total  = $cfg->{max_total_chars} // MAX_TOTAL_CHARS;

    my @snippets;
    my $golden_hit_count     = 0;
    my $candidate_hit_count  = 0;
    my $golden_table_missing = 0;

    # Golden Data first
    try {
        my $res = $self->golden_store->list_golden($c, query => $q, limit => $max_snips);
        $golden_table_missing = $res->{table_missing} // 0;
        if ($golden_table_missing) {
            push @$thinking, "Golden Data table missing";
        }
        my $rows = $res->{rows} // [];
        for my $row (@$rows) {
            next unless ($row->{status} // '') eq 'golden';
            last if @snippets >= $max_snips;
            my $text = $self->_trim_text($row->{canonical_text} // '');
            my $snippet = {
                id            => 'G:' . ($row->{id} // ''),
                label         => 'GOLDEN',
                source        => $row->{source_ref} // ('ai_golden_data:' . ($row->{id} // '')),
                retrieved_at  => $self->_now_iso(),
                title         => $row->{title} // '',
                text          => $text,
            };
            if ($self->_add_snippet(\@snippets, $snippet, $max_snips, $max_total)) {
                $golden_hit_count++;
                push @$thinking, "Golden Data hit: " . ($row->{id} // '');
            }
            else {
                last;
            }
        }
    }
    catch {
        $self->logger->log_with_details($c, 'error', __FILE__, __LINE__, $sub_name, "Error listing Golden Data: $_");
    };

    # Candidate Data from list_candidates
    try {
        my $res = $self->golden_store->list_candidates($c, query => $q, limit => $max_snips);
        my $rows = $res->{rows} // [];
        for my $row (@$rows) {
            last if @snippets >= $max_snips;
            my $text = $self->_trim_text($row->{canonical_text} // '');
            my $snippet = {
                id            => 'C:gd-' . ($row->{id} // ''),
                label         => 'CANDIDATE',
                source        => $row->{source_ref} // ('ai_golden_data:' . ($row->{id} // '')),
                retrieved_at  => $self->_now_iso(),
                title         => $row->{title} // '',
                text          => $text,
            };
            if ($self->_add_snippet(\@snippets, $snippet, $max_snips, $max_total)) {
                $candidate_hit_count++;
                push @$thinking, "Candidate Data hit: " . ($row->{id} // '');
            }
            else {
                last;
            }
        }
    }
    catch {
        $self->logger->log_with_details($c, 'error', __FILE__, __LINE__, $sub_name, "Error listing Candidate Data: $_");
    };

    # Prior stored WebSearchResult hits
    try {
        my @keywords = $self->_extract_keywords($q);
        if (@keywords) {
            my $rs = $c->model('DBEncy')->schema->resultset('WebSearchResult')->search(
                {
                    -or => [
                        map {
                            ( +{ query => { -like => "%$_%" } },
                              +{ result_title => { -like => "%$_%" } } )
                        } @keywords
                    ],
                    # site-audit fetch logs are not answers to user questions
                    query          => { -not_like => 'site_audit:%' },
                    result_snippet => { -not_like => 'FAILED HTTP%' },
                },
                {
                    order_by => { -desc => 'created_at' },
                    rows     => 3
                }
            );
            my @hits = $rs->all;
            for my $hit (@hits) {
                last if @snippets >= $max_snips;
                my $text = $self->_trim_text($hit->result_snippet // '');
                my $url  = $hit->result_url // '';
                my $snippet = {
                    id            => 'C:wsr-' . ($hit->id // ''),
                    label         => 'CANDIDATE',
                    source        => "web:prior:$url",
                    retrieved_at  => $self->_now_iso(),
                    title         => $hit->result_title // '',
                    text          => $text,
                };
                if ($self->_add_snippet(\@snippets, $snippet, $max_snips, $max_total)) {
                    $candidate_hit_count++;
                    push @$thinking, "Prior web Candidate Data: " . ($hit->id // '');
                }
                else {
                    last;
                }
            }
        }
    }
    catch {
        $self->logger->log_with_details($c, 'warn', __FILE__, __LINE__, $sub_name, "Error fetching prior web results: $_");
    };

    # Live web search (if enabled)
    if ($do_web) {
        try {
            my $ctx;
            my $prov;
            my $ai = eval { $c->controller('AI') };
            if ($ai && $ai->can('_do_web_search')) {
                eval {
                    my $thinking_arrayref = $thinking;
                    ($ctx, $prov) = $ai->_do_web_search($c, $q, 'general', $thinking_arrayref);
                };
                if ($@) {
                    $self->logger->log_with_details($c, 'warn', __FILE__, __LINE__, $sub_name, "Error during live web search call: $@");
                }
            }
            if (defined $ctx && $ctx ne '') {
                my $web_n = 1;
                while ($ctx =~ /^##\s*(.+?)\nURL:\s*(\S+)\n(.*?)(?=\n## |\nUse the above|\z)/msg) {
                    last if @snippets >= $max_snips;
                    my ($title, $url, $sniptxt) = ($1, $2, $3);
                    my $text = $self->_trim_text($sniptxt);
                    my $snippet = {
                        id            => 'C:web-' . $web_n++,
                        label         => 'CANDIDATE',
                        source        => 'web:' . ($prov // 'unknown') . ":$url",
                        retrieved_at  => $self->_now_iso(),
                        title         => $title // '',
                        text          => $text,
                    };
                    if ($self->_add_snippet(\@snippets, $snippet, $max_snips, $max_total)) {
                        $candidate_hit_count++;
                        push @$thinking, "Live web Candidate Data hit: $url";
                    }
                    else {
                        last;
                    }
                }
            }
        }
        catch {
            $self->logger->log_with_details($c, 'warn', __FILE__, __LINE__, $sub_name, "Live web search error: $_");
        };
    }

    return {
        snippets             => \@snippets,
        golden_hit_count     => $golden_hit_count,
        candidate_hit_count  => $candidate_hit_count,
        golden_table_missing => $golden_table_missing,
    };
}

=head2 build_payload

Build chat messages array: system (Glossary + ANTI-HALLUCINATION POLICY referencing Golden Data, Candidate Data, Grounding Context, Hallucination, Router), history messages (valid role/content only), final user message with grounding_block + QUESTION.

=cut

sub build_payload {
    my ($self, %a) = @_;
    my $snippets  = $a{snippets} // [];
    my $question  = $a{question} // '';
    my $history   = $a{history} // [];

    my $glossary = '';
    try {
        $glossary = Comserv::Util::AI::Glossary->system_prompt_text() // '';
    }
    catch {
        # glossary optional; continue
    };

    my $policy = join("\n",
        "ANTI-HALLUCINATION POLICY (enforced by the Router):",
        "- Answer ONLY from the GROUNDING block in the user message. If the GROUNDING does not contain the answer, say: I don't have golden data for this yet, so I can't give you a verified answer.",
        "- Cite the snippet id in square brackets after every factual sentence, e.g. [G:12] or [C:web-3].",
        "- [GOLDEN] snippets are Golden Data (human-agreed truth). [CANDIDATE — unverified] snippets are Candidate Data: you may use them but you must say they are unverified. Never call Candidate Data golden or verified.",
        "- Do not add facts that are not in the GROUNDING (that is a Hallucination)."
    );

    my $sys_content = $glossary . "\n\n" . $policy;

    my @messages = (
        { role => 'system', content => $sys_content },
    );

    for my $h (@$history) {
        if (ref $h eq 'HASH' && defined $h->{role} && defined $h->{content}) {
            push @messages, { role => $h->{role}, content => $h->{content} };
        }
    }

    my $grounding = $self->grounding_block($snippets);
    push @messages, { role => 'user', content => $grounding . "\n\nQUESTION: " . $question };

    return \@messages;
}

=head2 grounding_block

Format snippets as GROUNDING (Grounding Context — cite by id) block. Numbered 1..N, [id] [GOLDEN] or [CANDIDATE — unverified], source=, retrieved_at=, optional title=, then indented text. Ends with END GROUNDING.

=cut

sub grounding_block {
    my ($self, $snippets) = @_;
    $snippets //= [];
    my $block = "GROUNDING (Grounding Context — cite by id):\n";
    my $n = 1;
    for my $snip (@$snippets) {
        my $id       = $snip->{id} // '';
        my $label    = $snip->{label} // 'CANDIDATE';
        my $label_str = ($label eq 'GOLDEN') ? '[GOLDEN]' : '[CANDIDATE — unverified]';
        my $source   = $snip->{source} // '';
        my $retr     = $snip->{retrieved_at} // '';
        my $title    = $snip->{title} // '';
        my $text     = $snip->{text} // '';
        $block .= "$n. [$id] $label_str source=$source retrieved_at=$retr";
        if ($title) {
            $block .= " title=$title";
        }
        $block .= "\n   $text\n";
        $n++;
    }
    $block .= "END GROUNDING";
    return $block;
}

=head2 empty_miss

Return miss structure for no Golden Data: {grounded => 0, reason => 'no_golden_data', answer => FALLBACK_NO_GOLDEN}.

=cut

sub empty_miss {
    my ($self) = @_;
    return {
        grounded => 0,
        reason   => 'no_golden_data',
        answer   => FALLBACK_NO_GOLDEN,
    };
}

=head2 post_check

Split answer into sentences (on (?<=[.!?])\s+ and newlines as separators). Identify factual assertions (>=5 words or contains digit, not ?, not hedge/unknown/golden data phrases, not pure markdown). Check for valid [G:..] or [C:..] citations against snippet ids. 'strip' removes uncited factual sentences; 'flag' appends ' [uncited — unverified]'. Return {answer, flagged_count, cited_ids, uncited}. If stripped result empty, use FALLBACK_NO_GOLDEN and set emptied => 1.

=cut

sub post_check {
    my ($self, $answer, $snippets, %args) = @_;
    my $action = $args{action} // 'strip';
    my @snippet_ids = map { $_->{id} } @$snippets;
    my %id_set = map { $_ => 1 } @snippet_ids;

    my $flagged_count = 0;
    my @cited_ids;
    my @uncited;
    my @kept;

    my @lines = split /\n+/, ($answer // '');
    for my $line (@lines) {
        my @sents = split /(?<=[.!?])\s+/, $line;
        for my $sent (@sents) {
            $sent =~ s/^\s+|\s+$//g;
            next unless $sent;

            my $is_factual = 0;
            my $word_count = scalar(split /\s+/, $sent);
            if ($word_count >= 5 || $sent =~ /\d/) {
                $is_factual = 1;
            }
            if ($sent =~ /\?$/) {
                $is_factual = 0;
            }
            # Explicit 'unknown' policy statements are not claims (Glossary: Hallucination).
            if ($sent =~ /(don't|do not|can't|cannot|can not) (have|give|verify|find|confirm)|not sure|\bunknown\b/i) {
                $is_factual = 0;
            }
            # Headings are not claims; list items ARE checked (marker ignored).
            if ($sent =~ /^#{1,6}\s/) {
                $is_factual = 0;
            }

            if (!$is_factual) {
                push @kept, $sent;
                next;
            }

            # factual assertion
            my @cites = ($sent =~ /\[((?:G|C):[\w\-]+)\]/g);
            my $is_cited = 0;
            for my $cid (@cites) {
                if ($id_set{$cid}) {
                    $is_cited = 1;
                    push @cited_ids, $cid;
                    last;
                }
            }

            if ($is_cited) {
                push @kept, $sent;
            }
            else {
                $flagged_count++;
                push @uncited, $sent;
                if ($action eq 'flag') {
                    push @kept, $sent . ' [uncited — unverified]';
                }
                # else strip: omit
            }
        }
    }

    my $new_answer = join(' ', @kept);

    my %seen;
    my @unique_cited = grep { !$seen{$_}++ } @cited_ids;

    my $result = {
        answer       => $new_answer,
        flagged_count => $flagged_count,
        cited_ids    => \@unique_cited,
        uncited      => \@uncited,
    };

    if ($new_answer =~ /^\s*$/) {
        $result->{answer}  = FALLBACK_NO_GOLDEN;
        $result->{emptied} = 1;
    }

    return $result;
}

=head2 label_answer

If no Golden Data hits but Candidate Data hits and answer is not FALLBACK, prefix with CANDIDATE_ONLY_PREFIX (unless already present). Return the (possibly prefixed) string.

=cut

sub label_answer {
    my ($self, $answer, $golden_hit_count, $candidate_hit_count) = @_;
    if ($golden_hit_count == 0 && $candidate_hit_count > 0 && $answer ne FALLBACK_NO_GOLDEN) {
        unless (index($answer, CANDIDATE_ONLY_PREFIX) == 0) {
            $answer = CANDIDATE_ONLY_PREFIX . $answer;
        }
    }
    return $answer;
}

=head2 ledger_fields

Return Ledger hashref with grounded (from snippet_count), golden_hit_count, candidate_hit_count, snippet_ids (joined, truncated 1000 chars), flagged_count, grounding_mode, factual_intent, feature, and optional reason.

=cut

sub ledger_fields {
    my ($self, %h) = @_;
    my $ledger = {
        grounded            => ($h{snippet_count} ? 1 : 0),
        golden_hit_count    => int($h{golden_hit_count} // 0),
        candidate_hit_count => int($h{candidate_hit_count} // 0),
        snippet_ids         => substr(join(',', @{$h{snippet_ids} || []}), 0, 1000),
        flagged_count       => int($h{flagged_count} // 0),
        grounding_mode      => $h{mode} // 'shadow',
        factual_intent      => $h{factual} ? 1 : 0,
        feature             => $h{feature} // 'ai2_chat',
    };
    if (defined $h{reason}) {
        $ledger->{reason} = $h{reason};
    }
    return $ledger;
}

=head2 log_line

Format Ledger string: "Ledger grounding: grounded=... golden_hit_count=... candidate_hit_count=... flagged_count=... mode=... factual=... feature=... snippet_ids=..." (+ " reason=..." if present).

=cut

sub log_line {
    my ($self, $ledger) = @_;
    $ledger //= {};
    my $line = sprintf(
        "Ledger grounding: grounded=%d golden_hit_count=%d candidate_hit_count=%d flagged_count=%d mode=%s factual=%d feature=%s snippet_ids=%s",
        $ledger->{grounded} // 0,
        $ledger->{golden_hit_count} // 0,
        $ledger->{candidate_hit_count} // 0,
        $ledger->{flagged_count} // 0,
        $ledger->{grounding_mode} // 'shadow',
        $ledger->{factual_intent} // 0,
        $ledger->{feature} // 'ai2_chat',
        $ledger->{snippet_ids} // '',
    );
    if (defined $ledger->{reason}) {
        $line .= " reason=" . $ledger->{reason};
    }
    return $line;
}

=head2 prepare_turn

Main hook called before model call. Resolve mode and factual intent. For 'off': return minimal hash (no ledger). For non-enforce (shadow or non-factual): no retrieval, ledger with reason, log "Grounding shadow: ...". For enforce: retrieve (web_search from config), build messages or empty_miss. On any exception in enforce: log error, return fallback with reason 'grounding_error' (enforce=0). Push progress to thinking. All errors caught.

=cut

sub prepare_turn {
    my ($self, $c, %args) = @_;
    my $prompt    = $args{prompt} // '';
    my $argshash  = $args{args} // {};
    my $thinking  = $args{thinking} // [];
    my $sub_name  = 'prepare_turn';

    my $mode    = $self->resolve_mode($c, %$argshash);
    my $factual = $self->is_factual_intent($prompt, %$argshash);

    if ($mode eq 'off') {
        return {
            mode    => 'off',
            enforce => 0,
            factual => $factual,
        };
    }

    my $enforce = ($mode eq 'enforce' && $factual) ? 1 : 0;

    if (!$enforce) {
        my $reason = $factual ? 'shadow_not_enforced' : 'not_factual';
        my $ledger = $self->ledger_fields(
            mode         => $mode,
            factual      => $factual,
            snippet_count => 0,
            reason       => $reason,
            feature      => $argshash->{feature} // 'ai2_chat',
        );
        my $logmsg = "Grounding shadow: " . $self->log_line($ledger);
        $self->logger->log_with_details($c, 'info', __FILE__, __LINE__, $sub_name, $logmsg);
        return {
            mode    => $mode,
            enforce => 0,
            factual => $factual,
            ledger  => $ledger,
        };
    }

    # enforce path
    my $turn;
    try {
        my $cfg       = $self->load_config($c);
        my $web_search = $cfg->{web_search} // 1;
        my $ret       = $self->retrieve($c, query => $prompt, web_search => $web_search, thinking => $thinking);
        my $snippets  = $ret->{snippets} // [];
        my $g_count   = $ret->{golden_hit_count} // 0;
        my $c_count   = $ret->{candidate_hit_count} // 0;
        my $table_missing = $ret->{golden_table_missing} // 0;

        if (@$snippets == 0) {
            my $miss = $self->empty_miss();
            my $ledger = $self->ledger_fields(
                mode              => $mode,
                factual           => $factual,
                snippet_count     => 0,
                golden_hit_count  => $g_count,
                candidate_hit_count => $c_count,
                reason            => 'no_golden_data',
                feature           => $argshash->{feature} // 'ai2_chat',
            );
            if ($table_missing) {
                $ledger->{golden_table_missing} = 1;
            }
            my $logmsg = $self->log_line($ledger);
            $self->logger->log_with_details($c, 'info', __FILE__, __LINE__, $sub_name, "Grounding enforce miss: $logmsg");
            $turn = {
                mode                => $mode,
                enforce             => 1,
                factual             => $factual,
                snippets            => $snippets,
                miss                => $miss,
                ledger              => $ledger,
            };
        }
        else {
            my $messages = $self->build_payload(
                snippets => $snippets,
                question => $prompt,
                history  => $argshash->{history},
            );
            my @ids = map { $_->{id} } @$snippets;
            my $ledger = $self->ledger_fields(
                mode                => $mode,
                factual             => $factual,
                snippet_count       => scalar(@$snippets),
                golden_hit_count    => $g_count,
                candidate_hit_count => $c_count,
                snippet_ids         => \@ids,
                feature             => $argshash->{feature} // 'ai2_chat',
            );
            my $logmsg = $self->log_line($ledger);
            $self->logger->log_with_details($c, 'info', __FILE__, __LINE__, $sub_name, "Grounding enforce: $logmsg");
            $turn = {
                mode                => $mode,
                enforce             => 1,
                factual             => $factual,
                snippets            => $snippets,
                messages            => $messages,
                golden_hit_count    => $g_count,
                candidate_hit_count => $c_count,
                ledger              => $ledger,
            };
        }
    }
    catch {
        $self->logger->log_with_details($c, 'error', __FILE__, __LINE__, $sub_name, "Grounding enforce error: $_");
        my $ledger = $self->ledger_fields(
            mode          => $mode,
            factual       => $factual,
            snippet_count => 0,
            reason        => 'grounding_error',
            feature       => $argshash->{feature} // 'ai2_chat',
        );
        $turn = {
            mode    => $mode,
            enforce => 0,
            factual => $factual,
            ledger  => $ledger,
        };
    };

    return $turn;
}

=head2 finish_turn

If not enforce or no snippets, return $answer unchanged. Otherwise run post_check (using config postcheck_action), label_answer, update turn ledger flagged_count and cited_ids, push note to thinking, log "Grounding finish: ...", return processed answer.

=cut

sub finish_turn {
    my ($self, $c, $turn, $answer, $thinking) = @_;
    $thinking //= [];

    if (!$turn || !$turn->{enforce} || !exists $turn->{snippets} || !@{$turn->{snippets}}) {
        return $answer;
    }

    my $cfg    = $self->load_config($c);
    my $action = $cfg->{postcheck_action} // 'strip';

    my $pc = $self->post_check($answer, $turn->{snippets}, action => $action);
    my $a2 = $self->label_answer($pc->{answer}, $turn->{golden_hit_count} // 0, $turn->{candidate_hit_count} // 0);

    $turn->{ledger}{flagged_count} = $pc->{flagged_count} // 0;
    $turn->{ledger}{cited_ids}     = join(',', @{$pc->{cited_ids} // []});
    # Model failover (AISYSTEM plan §5e): a strip that leaves nothing means
    # this model gave no usable grounded answer; the Router may try the next
    # chain step. The returned text is still the honest fixed fallback.
    $turn->{postcheck_emptied} = $pc->{emptied} ? 1 : 0;

    push @$thinking, "Post-check: flagged=" . ($pc->{flagged_count} // 0) . " cited=" . scalar(@{$pc->{cited_ids} // []});

    my $logmsg = $self->log_line($turn->{ledger});
    $self->logger->log_with_details($c, 'info', __FILE__, __LINE__, 'finish_turn', "Grounding finish: $logmsg");

    return $a2;
}

=head2 summary

Return small summary hash for JSON response: mode, factual, grounded, golden_hit_count, candidate_hit_count, flagged_count, reason, snippets (id/label/source/retrieved_at/title only). Tolerates missing keys.

=cut

sub summary {
    my ($self, $turn) = @_;
    $turn //= {};
    my $ledger = $turn->{ledger} // {};
    my $snips  = $turn->{snippets} // [];

    my $mapped = [ map {
        {
            id            => $_->{id},
            label         => $_->{label},
            source        => $_->{source},
            retrieved_at  => $_->{retrieved_at},
            title         => $_->{title},
        }
    } @$snips ];

    return {
        mode                => $turn->{mode} // '',
        factual             => $turn->{factual} // 0,
        grounded            => $ledger->{grounded} // 0,
        golden_hit_count    => $ledger->{golden_hit_count} // 0,
        candidate_hit_count => $ledger->{candidate_hit_count} // 0,
        flagged_count       => $ledger->{flagged_count} // 0,
        reason              => $ledger->{reason} // '',
        snippets            => $mapped,
    };
}

=head2 miss_reply($c, $turn, args => \%args, duration_ms => $ms, thinking => $aref)

Enforce-mode empty Grounding Context: do NOT call the model for invented
facts. Records a Ledger row (provider ai2-grounding, 0 tokens, grounded=0,
reason=no_golden_data) and returns the Chat result hash whose response is
exactly FALLBACK_NO_GOLDEN.

=cut

sub miss_reply {
    my ($self, $c, $turn, %a) = @_;
    my $miss     = ($turn && $turn->{miss}) || $self->empty_miss;
    my $thinking = $a{thinking} || [];
    my $args     = $a{args} || {};
    push @$thinking, 'Grounding: no Golden Data / Candidate Data retrieved - fixed fallback, no model call';
    eval {
        $c->model('AI')->log_usage($c,
            provider          => 'ai2-grounding',
            model             => '(no-model-call)',
            prompt_tokens     => 0,
            completion_tokens => 0,
            total_tokens      => 0,
            request_type      => 'chat',
            status            => 'success',
            duration_ms       => $a{duration_ms},
            metadata          => {
                surface        => ($args->{surface} // 'chat'),
                agent_id       => ($args->{agent_id} // ''),
                grounding_miss => 1,
            },
            grounding         => ($turn ? $turn->{ledger} : undef),
        );
    };
    if ($@) {
        $self->logger->log_with_details($c, 'warn', __FILE__, __LINE__, 'miss_reply',
            "Ledger write failed for grounding miss: $@");
    }
    return {
        success   => 1,
        response  => $miss->{answer},
        model     => '(no-model-call)',
        provider  => 'ai2-grounding',
        grounded  => 0,
        reason    => $miss->{reason},
        grounding => $self->summary($turn),
        thinking  => $thinking,
        citations => [],
    };
}

# Private helpers

sub _extract_keywords {
    my ($self, $query) = @_;
    my $p = lc($query // '');
    my @stopwords = qw(the and or for with from about that this which what when where who how many much is are was were be been being have has had do does did can could will would shall should may might must a an to in on of by at
        used uses using tell know info information please give show find search look like good best there their them they your ours some into also just more most);
    my %stop = map { $_ => 1 } @stopwords;
    my @words = grep { length($_) >= 4 && !$stop{$_} } ($p =~ /\b(\w+)\b/g);
    splice(@words, 5) if @words > 5;
    return @words;
}

sub _trim_text {
    my ($self, $text) = @_;
    $text = $text // '';
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;
    if (length($text) > MAX_SNIPPET_CHARS) {
        $text = substr($text, 0, MAX_SNIPPET_CHARS - 3) . '...';
    }
    return $text;
}

sub _now_iso {
    my ($self) = @_;
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
}

sub _add_snippet {
    my ($self, $snippets_ref, $snippet, $max_snips, $max_total) = @_;
    return 0 if @$snippets_ref >= $max_snips;
    my $current = 0;
    $current += length($_->{text} // '') for @$snippets_ref;
    my $new_len = length($snippet->{text} // '');
    if ($current + $new_len > $max_total) {
        my $remaining = $max_total - $current;
        if ($remaining > 200) {
            $snippet->{text} = substr($snippet->{text} // '', 0, $remaining - 3) . '...';
            push @$snippets_ref, $snippet;
            return 1;
        }
        return 0;
    }
    push @$snippets_ref, $snippet;
    return 1;
}

__PACKAGE__->meta->make_immutable;
1;

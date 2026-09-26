package Comserv::Model::AI2::EvalReports;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON ();
use Digest::SHA qw(sha256_hex);
use Comserv::Util::AppTime;
use Comserv::Util::AI::EvalAllowList;

extends 'Catalyst::Model';

# ===================================================================
# AI2::EvalReports — Daily AI Eval Reports (AISYSTEM plan §5d).
# Extension of the AI usage monitor (/ai/usage -> /ai/eval).
#
#  - ingest(): upsert ai_eval_report by (report_date, source); proposals in
#    the payload are created as status=proposed, de-duplicated by title
#    within the report. Re-posting a report never duplicates proposals and
#    never touches admin_notes or a proposal's review status.
#  - Review-first, like Golden Data: NOTHING auto-applies. apply() only runs
#    for status=approved + change_type=config + target in
#    Comserv::Util::AI::EvalAllowList. revert() restores before_value.
#  - Approving code / workstation / other proposals creates a Todo in the
#    AISYSTEM project via the existing AI2::TodoCreate insert path.
#  - Degrades gracefully before schema-compare creates the tables:
#    reads return table_missing=1, ingest returns error=table_missing (503).
# All DB access is DBIx::Class. No raw SQL.
# ===================================================================

has 'logger' => (
    is      => 'rw',
    lazy    => 1,
    default => sub { require Comserv::Util::Logging; Comserv::Util::Logging->instance },
);
has 'schema_override'     => ( is => 'rw', default => undef );   # tests / scripts
has 'config_dir_override' => ( is => 'rw', default => undef );   # tests: temp copy of root/config
has 'inbox_dir_override'  => ( is => 'rw', default => undef );
has 'todo_creator'        => ( is => 'rw', default => undef );   # coderef($c, %args) -> {ok, todo_id|error}
has 'token_override'      => ( is => 'rw', default => undef );   # tests: expected ingest token ('' = none)

use constant STATUSES      => qw(proposed approved rejected applied reverted);
use constant CHANGE_TYPES  => qw(config code workstation other);
use constant DEFAULT_SOURCE    => 'AI usage monitor';
use constant TODO_PROJECT_CODE => 'AISYSTEM';
use constant MAX_PROPOSALS     => 50;
use constant MAX_MARKDOWN      => 1_000_000;
use constant MIN_TOKEN_LEN     => 16;
use constant TOKEN_ENV         => 'AI_EVAL_INGEST_TOKEN';
use constant TOKEN_FILE_NAME   => 'ai_eval_ingest_token';

my %TRANSITION = (
    approve => { from => [qw(proposed rejected reverted)], to => 'approved' },
    reject  => { from => [qw(proposed approved)],          to => 'rejected' },
    apply   => { from => [qw(approved)],                   to => 'applied'  },
    revert  => { from => [qw(applied)],                    to => 'reverted' },
);

sub _json { JSON->new->utf8(0)->canonical->allow_nonref }

sub _schema {
    my ($self, $c) = @_;
    return $self->schema_override if $self->schema_override;
    return $c->model('DBEncy')->schema;
}

sub _log {
    my ($self, $c, $level, $sub, $msg) = @_;
    eval { $self->logger->log_with_details($c, $level, __FILE__, __LINE__, $sub, $msg) };
}

sub _is_missing_error {
    my ($self, $err) = @_;
    $err = "$err";
    return ($err =~ /doesn't exist|does not exist|no such table|Unknown table|Can't find source|No such source/i) ? 1 : 0;
}

sub _now { Comserv::Util::AppTime->now_utc }

sub config_dir {
    my ($self, $c) = @_;
    return $self->config_dir_override if $self->config_dir_override;
    return $c->path_to('root', 'config') . '';
}

sub inbox_dir {
    my ($self, $c) = @_;
    return $self->inbox_dir_override if $self->inbox_dir_override;
    return $c->path_to('data', 'ai_eval_inbox') . '';
}

sub allow_list {
    my ($self, $c) = @_;
    return Comserv::Util::AI::EvalAllowList->new(config_dir => $self->config_dir($c));
}

# -------------------------------------------------------------------
# Ingest token: env AI_EVAL_INGEST_TOKEN, else the first line of
# ~/.comserv/secrets/ai_eval_ingest_token (outside the repo, same place as
# other Comserv secrets). Never hard-coded. Shorter than 16 chars = not set.
# -------------------------------------------------------------------
sub expected_token {
    my ($self, $c) = @_;
    if (defined $self->token_override) {
        my $t = $self->token_override;
        return (length $t >= MIN_TOKEN_LEN) ? $t : undef;
    }
    my $t = $ENV{+TOKEN_ENV};
    unless (defined $t && length $t) {
        my @dirs = grep { defined && length } ($ENV{HOME} ? "$ENV{HOME}/.comserv/secrets" : undef),
                                              '/home/comserv/.comserv/secrets';
        for my $d (@dirs) {
            my $f = "$d/" . TOKEN_FILE_NAME;
            next unless -f $f && -r _;
            if (open my $fh, '<', $f) { $t = <$fh>; close $fh; last }
        }
    }
    return undef unless defined $t;
    $t =~ s/^\s+|\s+$//g;
    return (length $t >= MIN_TOKEN_LEN) ? $t : undef;
}

# check_token($c, $presented) -> 'ok' | 'not_configured' | 'bad_token'
sub check_token {
    my ($self, $c, $presented) = @_;
    my $want = $self->expected_token($c);
    return 'not_configured' unless defined $want;
    return 'bad_token' unless defined $presented && length $presented;
    return (sha256_hex($presented) eq sha256_hex($want)) ? 'ok' : 'bad_token';
}

# -------------------------------------------------------------------
# Validation
# -------------------------------------------------------------------
sub _title_key {
    my ($t) = @_;
    $t = lc($t // '');
    $t =~ s/\s+/ /g;
    $t =~ s/^ | $//g;
    return $t;
}

sub _valid_date {
    my ($d) = @_;
    return 0 unless defined $d && $d =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my ($y, $m, $dd) = ($1, $2, $3);
    return 0 if $m < 1 || $m > 12 || $dd < 1;
    my @dim = (31, (($y % 4 == 0 && $y % 100 != 0) || $y % 400 == 0) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
    return $dd <= $dim[$m - 1] ? 1 : 0;
}

=head2 validate_payload($data)

Returns C<($clean, \@errors, \@warnings)>. See the ingest contract in
AISYSTEMPlan §5d.

=cut

sub validate_payload {
    my ($self, $data) = @_;
    my (@err, @warn);
    return (undef, ['body must be a JSON object'], []) unless ref $data eq 'HASH';

    my %r;
    $r{report_date} = $data->{report_date};
    push @err, 'report_date is required (YYYY-MM-DD)' unless _valid_date($r{report_date});

    $r{source} = defined $data->{source} && !ref $data->{source} && length $data->{source}
        ? $data->{source} : DEFAULT_SOURCE;
    push @err, 'source must be at most 100 characters' if length $r{source} > 100;

    for my $f (qw(summary markdown created_by)) {
        next unless defined $data->{$f};
        if (ref $data->{$f}) { push @err, "$f must be a string"; next }
        $r{$f} = $data->{$f};
    }
    push @err, 'markdown is too large (max ' . MAX_MARKDOWN . ' chars)'
        if defined $r{markdown} && length $r{markdown} > MAX_MARKDOWN;
    push @err, 'summary is too large (max 65000 chars)' if defined $r{summary} && length $r{summary} > 65000;
    $r{created_by} = substr($r{created_by}, 0, 100) if defined $r{created_by};

    my $metrics = $data->{metrics};
    if (!defined $metrics && defined $data->{metrics_json}) {
        $metrics = ref $data->{metrics_json} ? $data->{metrics_json}
                 : eval { JSON->new->decode($data->{metrics_json}) };
        push @err, 'metrics_json is not valid JSON' unless defined $metrics;
    }
    if (defined $metrics) {
        if (ref $metrics eq 'HASH') {
            $r{metrics_json} = _json()->encode($metrics);
            push @err, 'metrics too large (max 65000 chars as JSON)' if length $r{metrics_json} > 65000;
        } else {
            push @err, 'metrics must be a JSON object';
        }
    }

    my @props;
    if (defined $data->{proposals}) {
        if (ref $data->{proposals} ne 'ARRAY') {
            push @err, 'proposals must be an array';
        } elsif (@{ $data->{proposals} } > MAX_PROPOSALS) {
            push @err, 'too many proposals (max ' . MAX_PROPOSALS . ')';
        } else {
            my $al = Comserv::Util::AI::EvalAllowList->new;   # validation only, no file access
            my %seen;
            my $i = 0;
            for my $p (@{ $data->{proposals} }) {
                $i++;
                my $where = "proposals[$i]";
                unless (ref $p eq 'HASH') { push @err, "$where must be an object"; next }
                my $title = $p->{title};
                unless (defined $title && !ref $title && $title =~ /\S/) { push @err, "$where.title is required"; next }
                $title =~ s/^\s+|\s+$//g;
                if (length $title > 255) { push @err, "$where.title must be at most 255 characters"; next }
                my $ct = lc($p->{change_type} // 'other');
                unless (grep { $_ eq $ct } CHANGE_TYPES) {
                    push @err, "$where.change_type must be one of: " . join('|', CHANGE_TYPES); next;
                }
                my $target = $p->{target};
                if (defined $target && (ref $target || length $target > 255)) { push @err, "$where.target must be a string (max 255)"; next }
                if (defined $p->{rationale} && ref $p->{rationale}) { push @err, "$where.rationale must be a string"; next }
                my $payload = exists $p->{payload} ? $p->{payload} : undef;
                my $payload_json = defined $payload ? _json()->encode($payload) : undef;
                if (defined $payload_json && length $payload_json > 65000) { push @err, "$where.payload too large"; next }
                my $note;
                if ($ct eq 'config') {
                    my $v = ref $payload eq 'HASH' ? $payload->{value} : undef;
                    my ($ok, $msg) = $al->validate($target, $v);
                    unless ($ok) {
                        $note = "Not applicable as submitted: $msg";
                        push @warn, "$where ($title): $note";
                    }
                }
                my $key = _title_key($title);
                if ($seen{$key}++) { push @warn, "$where ($title): duplicate title in payload, ignored"; next }
                push @props, {
                    title => $title, title_key => $key, change_type => $ct,
                    target => $target, rationale => $p->{rationale},
                    payload_json => $payload_json, note => $note,
                };
            }
        }
    }
    $r{proposals} = \@props;
    return (\%r, \@err, \@warn);
}

=head2 ingest($c, $data, by => $who)

Upsert by (report_date, source). Returns
C<< { ok=>1, http=>200, report_id, created=>0|1, proposals_created, proposals_skipped, warnings } >>
or C<< { ok=>0, http=>400|503|500, error=>'validation'|'table_missing'|'internal', errors?, detail? } >>.

=cut

sub ingest {
    my ($self, $c, $data, %a) = @_;
    my ($r, $errors, $warnings) = $self->validate_payload($data);
    return { ok => 0, http => 400, error => 'validation', errors => $errors } if @$errors;

    my $by  = $a{by} // $r->{created_by} // 'unknown';
    my $now = $self->_now;
    my $out;
    try {
        my $schema = $self->_schema($c);
        $schema->txn_do(sub {
            my $rs = $schema->resultset('AiEvalReport');
            my $rep = $rs->search({ report_date => $r->{report_date}, source => $r->{source} }, { rows => 1 })->single;
            my $created = 0;
            my %cols = map { exists $r->{$_} ? ($_ => $r->{$_}) : () } qw(summary markdown metrics_json);
            if ($rep) {
                $rep->update({ %cols, updated_at => $now });
            } else {
                $rep = $rs->create({
                    report_date => $r->{report_date},
                    source      => $r->{source},
                    %cols,
                    created_by  => substr($r->{created_by} // $by, 0, 100),
                    created_at  => $now,
                    updated_at  => $now,
                });
                $created = 1;
            }
            my $prs = $schema->resultset('AiEvalProposal');
            my %have = map { _title_key($_->title) => 1 }
                       $prs->search({ report_id => $rep->id }, { columns => [qw(id title)] })->all;
            my ($made, $skipped) = (0, 0);
            for my $p (@{ $r->{proposals} }) {
                if ($have{ $p->{title_key} }++) { $skipped++; next }
                $prs->create({
                    report_id    => $rep->id,
                    title        => $p->{title},
                    rationale    => $p->{rationale},
                    change_type  => $p->{change_type},
                    target       => $p->{target},
                    payload_json => $p->{payload_json},
                    status       => 'proposed',
                    result       => (defined $p->{note} ? "[$now UTC] $p->{note}" : undef),
                    created_at   => $now,
                });
                $made++;
            }
            $out = { ok => 1, http => 200, report_id => 0 + $rep->id, created => $created,
                     proposals_created => $made, proposals_skipped => $skipped, warnings => $warnings };
        });
        $self->_log($c, 'info', 'ingest', sprintf('AI eval report %s/%s report_id=%d created=%d proposals +%d (skipped %d) by=%s',
            $r->{report_date}, $r->{source}, $out->{report_id}, $out->{created}, $out->{proposals_created}, $out->{proposals_skipped}, $by));
    } catch {
        my $e = "$_";
        if ($self->_is_missing_error($e)) {
            $out = { ok => 0, http => 503, error => 'table_missing',
                     detail => 'ai_eval_report / ai_eval_proposal not created yet - run /admin/schema_compare' };
            $self->_log($c, 'info', 'ingest', "AI eval ingest refused: tables pending schema-compare ($e)");
        } else {
            $out = { ok => 0, http => 500, error => 'internal', detail => $e };
            $self->_log($c, 'error', 'ingest', "AI eval ingest failed: $e");
        }
    };
    return $out;
}

# -------------------------------------------------------------------
# Reads
# -------------------------------------------------------------------
sub _metrics {
    my ($self, $json) = @_;
    return {} unless defined $json && length $json;
    my $m = eval { JSON->new->decode($json) };
    return ref $m eq 'HASH' ? $m : {};
}

# Flatten nested metrics to [ [ 'openrouter.caps.day_usd', '1.65' ], ... ].
sub flatten_metrics {
    my ($self, $m, $prefix, $out) = @_;
    $out ||= [];
    $prefix //= '';
    if (ref $m eq 'HASH') {
        $self->flatten_metrics($m->{$_}, length $prefix ? "$prefix.$_" : $_, $out) for sort keys %$m;
    } elsif (ref $m eq 'ARRAY') {
        if (!grep { ref } @$m) { push @$out, [ $prefix, join(', ', map { $_ // '' } @$m) ] }
        else { $self->flatten_metrics($m->[$_], "$prefix\[$_\]", $out) for 0 .. $#$m }
    } else {
        my $v = JSON::is_bool($m) ? ($m ? 'true' : 'false') : $m;
        push @$out, [ $prefix, defined $v ? "$v" : '' ];
    }
    return $out;
}

sub _dig { my ($h, @p) = @_; for (@p) { return undef unless ref $h eq 'HASH'; $h = $h->{$_} } return $h }

# A few headline numbers for the list view / usage card.
sub key_metrics {
    my ($self, $m) = @_;
    return {
        bot_pct_left       => _dig($m, qw(bot percent_left)),
        openrouter_balance => _dig($m, qw(openrouter balance_usd)),
        openrouter_month   => _dig($m, qw(openrouter month_usd)),
        chat_calls         => _dig($m, qw(chat calls)),
        chat_usable        => _dig($m, qw(chat usable)),
        chat_zero_token    => _dig($m, qw(chat zero_token_ok)),
        chat_404           => _dig($m, qw(chat http_404)),
        hermes_sessions    => _dig($m, qw(hermes sessions)),
    };
}

sub _report_hash {
    my ($self, $r, %a) = @_;
    my $m = $self->_metrics($r->get_column('metrics_json'));
    my $h = {
        id          => $r->id,
        report_date => '' . ($r->get_column('report_date') // ''),
        source      => $r->source,
        summary     => $r->summary,
        created_by  => $r->created_by,
        created_at  => '' . ($r->get_column('created_at') // ''),
        updated_at  => '' . ($r->get_column('updated_at') // ''),
        key         => $self->key_metrics($m),
    };
    if ($a{full}) {
        $h->{markdown}      = $r->markdown;
        $h->{markdown_html} = $self->render_markdown($r->markdown);
        $h->{admin_notes}   = $r->admin_notes;
        $h->{metrics}       = $m;
        $h->{metrics_flat}  = $self->flatten_metrics($m);
    }
    return $h;
}

sub _proposal_hash {
    my ($self, $p, $al) = @_;
    my $payload = defined $p->payload_json ? eval { JSON->new->allow_nonref->decode($p->payload_json) } : undef;
    my $ct = $p->change_type // 'other';
    my $st = $p->status // 'proposed';
    my $allowed = ($ct eq 'config' && $al) ? $al->is_allowed($p->target) : 0;
    return {
        id           => $p->id,
        report_id    => $p->get_column('report_id'),
        title        => $p->title,
        rationale    => $p->rationale,
        change_type  => $ct,
        target       => $p->target,
        payload_json => $p->payload_json,
        payload_pretty => defined $payload ? JSON->new->pretty->canonical->allow_nonref->encode($payload) : '',
        status       => $st,
        approved_by  => $p->approved_by,
        approved_at  => '' . ($p->get_column('approved_at') // ''),
        applied_by   => $p->applied_by,
        applied_at   => '' . ($p->get_column('applied_at') // ''),
        before_value => $p->before_value,
        result       => $p->result,
        todo_id      => $p->todo_id,
        created_at   => '' . ($p->get_column('created_at') // ''),
        target_allowed => $allowed,
        can_approve  => (grep { $_ eq $st } @{ $TRANSITION{approve}{from} }) ? 1 : 0,
        can_reject   => (grep { $_ eq $st } @{ $TRANSITION{reject}{from} })  ? 1 : 0,
        can_apply    => ($st eq 'approved' && $ct eq 'config' && $allowed) ? 1 : 0,
        can_revert   => ($st eq 'applied' && $ct eq 'config') ? 1 : 0,
    };
}

sub _counts_for {
    my ($self, $schema, $ids) = @_;
    my %c;
    return \%c unless $ids && @$ids;
    my $rs = $schema->resultset('AiEvalProposal')->search({ report_id => { -in => $ids } }, {
        select   => [ 'report_id', 'status', { count => 'id', -as => 'n' } ],
        as       => [qw(report_id status n)],
        group_by => [qw(report_id status)],
    });
    while (my $r = $rs->next) {
        $c{ $r->get_column('report_id') }{ $r->get_column('status') } = $r->get_column('n') || 0;
    }
    return \%c;
}

=head2 list_reports($c, limit => 60)

Newest first. C<< { rows => [...], table_missing => 0|1, error? } >>.

=cut

sub list_reports {
    my ($self, $c, %a) = @_;
    my $limit = ($a{limit} && $a{limit} =~ /^\d+$/ && $a{limit} <= 365) ? $a{limit} : 60;
    my $out = { rows => [], table_missing => 0 };
    try {
        my $schema = $self->_schema($c);
        my @reps = $schema->resultset('AiEvalReport')->search({}, {
            order_by => [ { -desc => 'report_date' }, { -desc => 'id' } ], rows => $limit,
        })->all;
        my @rows = map { $self->_report_hash($_) } @reps;
        my $counts = try { $self->_counts_for($schema, [ map { $_->{id} } @rows ]) }
                     catch { $out->{proposal_table_missing} = 1 if $self->_is_missing_error($_); +{} };
        for my $r (@rows) {
            my $cc = $counts->{ $r->{id} } || {};
            $r->{counts} = { map { $_ => ($cc->{$_} || 0) } STATUSES };
            $r->{counts}{total} = 0; $r->{counts}{total} += $cc->{$_} || 0 for STATUSES;
        }
        $out->{rows} = \@rows;
    } catch {
        my $e = "$_";
        if ($self->_is_missing_error($e)) { $out->{table_missing} = 1 }
        else { $out->{error} = $e; $self->_log($c, 'warn', 'list_reports', "AI eval list failed: $e") }
    };
    return $out;
}

=head2 get_report($c, $id)

C<< { report => {...}, proposals => [...], table_missing, not_found?, error? } >>.

=cut

sub get_report {
    my ($self, $c, $id) = @_;
    my $out = { report => undef, proposals => [], table_missing => 0 };
    return { %$out, not_found => 1 } unless defined $id && $id =~ /^\d+$/;
    try {
        my $schema = $self->_schema($c);
        my $r = $schema->resultset('AiEvalReport')->find($id);
        unless ($r) { $out->{not_found} = 1; return }
        $out->{report} = $self->_report_hash($r, full => 1);
        my $al = $self->allow_list($c);
        $out->{proposals} = [ map { $self->_proposal_hash($_, $al) }
            $schema->resultset('AiEvalProposal')->search({ report_id => $id }, { order_by => 'id' })->all ];
    } catch {
        my $e = "$_";
        if ($self->_is_missing_error($e)) { $out->{table_missing} = 1 }
        else { $out->{error} = $e; $self->_log($c, 'warn', 'get_report', "AI eval get_report($id) failed: $e") }
    };
    return $out;
}

=head2 latest_summary($c)

For the card on /ai/usage: C<< { table_missing, latest => {...}|undef, open => n, total_reports => n } >>.

=cut

sub latest_summary {
    my ($self, $c) = @_;
    my $out = { table_missing => 0, latest => undef, open => 0, total_reports => 0 };
    try {
        my $schema = $self->_schema($c);
        my $rs = $schema->resultset('AiEvalReport');
        $out->{total_reports} = $rs->count;
        my $r = $rs->search({}, { order_by => [ { -desc => 'report_date' }, { -desc => 'id' } ], rows => 1 })->single;
        $out->{latest} = $self->_report_hash($r) if $r;
        $out->{open} = try { $schema->resultset('AiEvalProposal')->search({ status => { -in => [qw(proposed approved)] } })->count } catch { 0 };
    } catch {
        my $e = "$_";
        if ($self->_is_missing_error($e)) { $out->{table_missing} = 1 }
        else { $out->{error} = $e; $self->_log($c, 'warn', 'latest_summary', "AI eval summary failed: $e") }
    };
    return $out;
}

sub save_notes {
    my ($self, $c, $id, $notes, $by) = @_;
    return { ok => 0, error => 'bad report id' } unless defined $id && $id =~ /^\d+$/;
    $notes //= '';
    return { ok => 0, error => 'notes too long (max 65000)' } if length $notes > 65000;
    my $out;
    try {
        my $r = $self->_schema($c)->resultset('AiEvalReport')->find($id);
        unless ($r) { $out = { ok => 0, error => 'report not found' }; return }
        $r->update({ admin_notes => $notes, updated_at => $self->_now });
        $self->_log($c, 'info', 'save_notes', "AI eval report $id admin notes saved by " . ($by // '?'));
        $out = { ok => 1, message => 'Notes saved' };
    } catch {
        my $e = "$_";
        $out = { ok => 0, error => ($self->_is_missing_error($e) ? 'table_missing' : $e) };
    };
    return $out;
}

# -------------------------------------------------------------------
# Status transitions
# -------------------------------------------------------------------
sub _append_result {
    my ($self, $p, $line) = @_;
    my $old = $p->result;
    return (defined $old && length $old ? "$old\n" : '') . '[' . $self->_now . " UTC] $line";
}

sub _find_proposal {
    my ($self, $c, $pid) = @_;
    return undef unless defined $pid && $pid =~ /^\d+$/;
    return $self->_schema($c)->resultset('AiEvalProposal')->find($pid);
}

sub transition {
    my ($self, $c, $action, $pid, $by) = @_;
    return { ok => 0, error => "unknown action '$action'" } unless $TRANSITION{$action};
    $by = (defined $by && length $by) ? substr($by, 0, 100) : 'unknown';
    my $out;
    try {
        my $p = $self->_find_proposal($c, $pid);
        unless ($p) { $out = { ok => 0, error => 'proposal not found' }; return }
        my $st = $p->status // 'proposed';
        unless (grep { $_ eq $st } @{ $TRANSITION{$action}{from} }) {
            $out = { ok => 0, error => "cannot $action a proposal with status '$st'" };
            return;
        }
        my $m = "_do_$action";
        $out = $self->$m($c, $p, $by);
    } catch {
        my $e = "$_";
        $out = { ok => 0, error => ($self->_is_missing_error($e) ? 'table_missing' : "failed: $e") };
        $self->_log($c, 'error', 'transition', "AI eval $action proposal " . ($pid // '?') . " failed: $e");
    };
    return $out;
}

sub approve { my ($s, $c, $pid, $by) = @_; $s->transition($c, 'approve', $pid, $by) }
sub reject  { my ($s, $c, $pid, $by) = @_; $s->transition($c, 'reject',  $pid, $by) }
sub apply   { my ($s, $c, $pid, $by) = @_; $s->transition($c, 'apply',   $pid, $by) }
sub revert  { my ($s, $c, $pid, $by) = @_; $s->transition($c, 'revert',  $pid, $by) }

sub _do_approve {
    my ($self, $c, $p, $by) = @_;
    my $now = $self->_now;
    my %upd = (status => 'approved', approved_by => $by, approved_at => $now);
    my $line = "approved by $by";
    my $msg  = 'Proposal approved';
    if (($p->change_type // '') eq 'config') {
        $msg .= ' - press Apply to write it (allow-listed targets only)';
    } elsif ($p->todo_id) {
        $line .= '; existing todo #' . $p->todo_id . ' kept';
    } else {
        # Code / workstation / other: never applied from the page -> Todo.
        my $t = try { $self->_create_todo($c, $p, $by) } catch { +{ ok => 0, error => "$_" } };
        if ($t && $t->{ok} && $t->{todo_id}) {
            $upd{todo_id} = $t->{todo_id};
            $line .= "; todo #$t->{todo_id} created in project " . TODO_PROJECT_CODE;
            $msg  .= " - todo #$t->{todo_id} created";
        } else {
            my $why = ($t && $t->{error}) || 'unknown error';
            $line .= "; todo NOT created: $why";
            $msg  .= " - todo NOT created ($why)";
        }
    }
    $upd{result} = $self->_append_result($p, $line);
    $p->update(\%upd);
    $self->_log($c, 'info', 'approve', 'AI eval proposal ' . $p->id . ": $line");
    return { ok => 1, message => $msg, todo_id => $upd{todo_id} };
}

sub _do_reject {
    my ($self, $c, $p, $by) = @_;
    my $line = "rejected by $by";
    $p->update({ status => 'rejected', result => $self->_append_result($p, $line) });
    $self->_log($c, 'info', 'reject', 'AI eval proposal ' . $p->id . ": $line");
    return { ok => 1, message => 'Proposal rejected' };
}

sub _payload_value {
    my ($self, $p) = @_;
    my $payload = defined $p->payload_json ? eval { JSON->new->allow_nonref->decode($p->payload_json) } : undef;
    return (ref $payload eq 'HASH' && exists $payload->{value}) ? (1, $payload->{value}) : (0, undef);
}

sub _do_apply {
    my ($self, $c, $p, $by) = @_;
    return { ok => 0, error => 'only change_type=config proposals can be applied; code/workstation/other become todos' }
        unless ($p->change_type // '') eq 'config';
    my $al = $self->allow_list($c);
    my $target = $p->target;
    return { ok => 0, error => 'target is not allow-listed: ' . ($target // '(none)') } unless $al->is_allowed($target);
    my ($has, $value) = $self->_payload_value($p);
    return { ok => 0, error => 'payload must be {"value": ...}' } unless $has;

    my $r = $al->apply($target, $value);
    unless ($r->{ok}) {
        my $line = "apply by $by FAILED for $target: $r->{error}";
        $p->update({ result => $self->_append_result($p, $line) });
        $self->_log($c, 'warn', 'apply', 'AI eval proposal ' . $p->id . ": $line");
        return { ok => 0, error => $r->{error} };
    }
    my $enc = _json();
    my $before_json = $enc->encode($r->{before});
    my $line = sprintf('applied by %s: %s %s -> %s', $by, $target,
        ($r->{before}{present} ? $enc->encode($r->{before}{value}) : '(absent)'), $enc->encode($r->{after}));
    $p->update({
        status       => 'applied',
        applied_by   => $by,
        applied_at   => $self->_now,
        before_value => $before_json,
        result       => $self->_append_result($p, $line),
    });
    $self->_log($c, 'info', 'apply', 'AI eval proposal ' . $p->id . ": $line");
    return { ok => 1, message => "Applied: $target", before => $r->{before}, after => $r->{after} };
}

sub _do_revert {
    my ($self, $c, $p, $by) = @_;
    my $al = $self->allow_list($c);
    my $target = $p->target;
    my $before = defined $p->before_value ? eval { JSON->new->allow_nonref->decode($p->before_value) } : undef;
    return { ok => 0, error => 'no before_value recorded; cannot revert' } unless ref $before eq 'HASH';
    my $r = $al->restore($target, $before);
    my $enc = _json();
    unless ($r->{ok}) {
        my $line = "revert by $by FAILED for " . ($target // '?') . ": $r->{error}";
        $p->update({ result => $self->_append_result($p, $line) });
        $self->_log($c, 'warn', 'revert', 'AI eval proposal ' . $p->id . ": $line");
        return { ok => 0, error => $r->{error} };
    }
    my ($has, $applied) = $self->_payload_value($p);
    my $cur = $r->{replaced};
    my $drift = ($has && (!$cur->{present} || $enc->encode($cur->{value}) ne $enc->encode($applied)))
        ? ' (note: value had drifted since apply; it was ' . ($cur->{present} ? $enc->encode($cur->{value}) : '(absent)') . ')'
        : '';
    my $line = sprintf('reverted by %s: %s restored to %s%s', $by, $target,
        ($before->{present} ? $enc->encode($before->{value}) : '(absent - key removed)'), $drift);
    $p->update({ status => 'reverted', result => $self->_append_result($p, $line) });
    $self->_log($c, 'info', 'revert', 'AI eval proposal ' . $p->id . ": $line");
    return { ok => 1, message => "Reverted: $target" };
}

# Todo for code / workstation / other proposals, via the existing
# AI2::TodoCreate insert path (no LLM rank handoff - approval must not spend).
sub _create_todo {
    my ($self, $c, $p, $by) = @_;
    my $report = eval { $p->report };
    my %args = (
        subject     => '[AI eval] ' . $p->title,
        description => join("\n\n", grep { defined && length }
            ($p->rationale),
            'Change type: ' . ($p->change_type // 'other') . (defined $p->target ? '  Target: ' . $p->target : ''),
            (defined $p->payload_json ? 'Payload: ' . $p->payload_json : undef),
            'From Daily AI Eval Report' . ($report ? ' ' . $report->get_column('report_date') . ' (' . $report->source . ')' : '')
              . ' proposal #' . $p->id . ' - review on /ai/eval/report/' . $p->get_column('report_id') . '. Approved by ' . $by . '.'),
        comments    => 'Created from /ai/eval proposal #' . $p->id,
        user        => $by,
        project_code => TODO_PROJECT_CODE,
        proposal_id => $p->id,
    );
    return $self->todo_creator->($c, %args) if $self->todo_creator;

    my $tc = eval { $c->model('AI2::TodoCreate') };
    return { ok => 0, error => 'AI2::TodoCreate model not available' } unless $tc;
    my $proj = $self->_schema($c)->resultset('Project')->search(
        { project_code => TODO_PROJECT_CODE }, { order_by => 'id', rows => 1 })->single;
    return { ok => 0, error => 'no project with project_code ' . TODO_PROJECT_CODE } unless $proj;
    my $ph = $tc->_project_row_hash($proj);
    my ($row, $err) = $tc->_insert_todo($c,
        sitename    => ($ph->{sitename} || $tc->sitename($c)),
        subject     => $args{subject},
        description => $args{description},
        comments    => $args{comments},
        priority    => 3,
        status      => 1,
        project     => $ph,
        user        => $by,
    );
    return { ok => 0, error => $err || 'Todo creation failed' } unless $row;
    my $id = eval { $row->record_id } // $row->id;
    return { ok => 1, todo_id => $id };
}

# -------------------------------------------------------------------
# Drop-folder import (data/ai_eval_inbox/*.json - not web-served).
# Same JSON shape and same ingest() as POST /ai/eval/ingest. Files are left
# in place; re-importing is an idempotent upsert.
# -------------------------------------------------------------------
sub import_inbox {
    my ($self, $c, %a) = @_;
    my $dir = $self->inbox_dir($c);
    my @files = -d $dir ? sort glob("$dir/*.json") : ();
    my @res;
    for my $f (@files) {
        (my $name = $f) =~ s{.*/}{};
        my $data = eval {
            open my $fh, '<:raw', $f or die "cannot read: $!\n";
            my $raw = do { local $/; <$fh> };
            close $fh;
            JSON->new->utf8->decode($raw);
        };
        unless ($data) {
            my $e = $@ || 'bad JSON'; chomp $e;
            push @res, { file => $name, ok => 0, error => "bad_json: $e" };
            next;
        }
        my $r = $self->ingest($c, $data, by => $a{by});
        push @res, { file => $name, %$r };
        last if !$r->{ok} && ($r->{error} // '') eq 'table_missing';
    }
    return { ok => 1, dir => $dir, files => \@res, count => scalar(@files) };
}

# -------------------------------------------------------------------
# Markdown: HTML-escape first (no raw HTML from reports), then
# Text::Markdown (already used by Controller::Documentation), then drop any
# link/image URL that is not http(s), mailto, relative or #anchor.
# -------------------------------------------------------------------
sub render_markdown {
    my ($self, $md) = @_;
    return '' unless defined $md && length $md;
    my $esc = $md;
    $esc =~ s/&/&amp;/g; $esc =~ s/</&lt;/g; $esc =~ s/>/&gt;/g; $esc =~ s/"/&quot;/g;
    my $html = eval { require Text::Markdown; Text::Markdown->new->markdown($esc) };
    unless (defined $html) {
        return '<pre class="ai-eval-markdown">' . $esc . '</pre>';
    }
    $html =~ s{\b(href|src)\s*=\s*"([^"]*)"}{ my ($a, $u) = ($1, $2);
        ($u =~ m{^(?:https?://|mailto:|/(?!/)|#)}i) ? qq{$a="$u"} : qq{$a="#"} }gie;
    $html =~ s{<a }{<a rel="nofollow noopener" }g;
    return $html;
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Comserv::Model::AI2::EvalReports - Daily AI Eval Reports + review-first proposals (/ai/eval)

=head1 DESCRIPTION

Stores the daily AI eval report (ai_eval_report) and its proposals
(ai_eval_proposal), renders data for the admin review pages, and applies
approved allow-listed config proposals (Comserv::Util::AI::EvalAllowList).
Code / workstation proposals become Todos in project AISYSTEM. Nothing is
applied automatically. See AISYSTEMPlan §5d for the ingest contract.

=cut

package Comserv::Controller::AI::Eval;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON ();
use Digest::SHA qw(sha256_hex);
use Comserv::Util::Logging;
use Comserv::Model::AI2::EvalReports;

BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => 'ai/eval');

# ===================================================================
# /ai/eval — Daily AI Eval Reports (AISYSTEM plan §5d). Admin-only sibling
# of the AI usage monitor (/ai/usage, Controller::AI::usage). Same admin
# check as the usage action (session roles contain "admin").
#
#   GET  /ai/eval                          list (newest first)
#   GET  /ai/eval/report/<id>              detail + proposals
#   POST /ai/eval/report/<id>/notes        admin notes / tuning
#   POST /ai/eval/proposal/<id>/<action>   approve | reject | apply | revert
#   POST /ai/eval/import_inbox             ingest data/ai_eval_inbox/*.json
#   POST /ai/eval/ingest                   JSON ingest (Bearer token or admin session)
#
# All state changes are POST + admin + per-session CSRF token. Nothing is
# applied automatically; see Model::AI2::EvalReports.
# ===================================================================

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

use constant MAX_INGEST_BYTES => 2_000_000;

sub _model { Comserv::Model::AI2::EvalReports->new }

# Same rule as Controller::AI::usage.
sub _is_admin {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} || [];
    $roles = [ split /,/, $roles ] unless ref $roles eq 'ARRAY';
    return (grep { /^admin$/i } @$roles) ? 1 : 0;
}

sub _username { my ($self, $c) = @_; return $c->session->{username} || 'unknown' }

# HTML gate: anonymous -> login redirect; logged-in non-admin -> 403.
sub _require_admin {
    my ($self, $c) = @_;
    return 1 if $self->_is_admin($c);
    my $user = $c->session->{username};
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'require_admin',
        'AI eval access denied for ' . ($user // 'anonymous') . ' path=' . $c->req->path);
    if (!$user || lc $user eq 'guest') {
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
    } else {
        $c->response->status(403);
        $c->response->content_type('text/plain; charset=utf-8');
        $c->response->body('403 Forbidden - AI eval reports are admin only.');
    }
    return 0;
}

sub _csrf_token {
    my ($self, $c) = @_;
    $c->session->{ai_eval_csrf} ||= sha256_hex(time() . rand() . ($c->sessionid || '') . $$);
    return $c->session->{ai_eval_csrf};
}

sub _csrf_ok {
    my ($self, $c) = @_;
    my $want = $c->session->{ai_eval_csrf};
    my $got  = $c->req->body_params->{csrf_token} // $c->req->header('X-CSRF-Token') // '';
    return 0 unless defined $want && length $want && length $got;
    return sha256_hex($got) eq sha256_hex($want) ? 1 : 0;
}

sub _post_guard {
    my ($self, $c, $back) = @_;
    return 0 unless $self->_require_admin($c);
    unless ($c->req->method eq 'POST') {
        $c->response->status(405);
        $c->response->header(Allow => 'POST');
        $c->response->body('405 Method Not Allowed - use the buttons on /ai/eval.');
        return 0;
    }
    unless ($self->_csrf_ok($c)) {
        $c->flash->{ai_eval_err} = 'Security token expired - reload the page and try again.';
        $c->response->redirect($back || $c->uri_for('/ai/eval'));
        return 0;
    }
    return 1;
}

sub _json_out {
    my ($self, $c, $status, $data) = @_;
    $c->response->status($status);
    $c->response->content_type('application/json; charset=utf-8');
    $c->response->body(JSON->new->utf8->canonical->encode($data));
    return;
}

sub _flash_to_stash {
    my ($self, $c) = @_;
    $c->stash->{ai_eval_msg} = delete $c->flash->{ai_eval_msg};
    $c->stash->{ai_eval_err} = delete $c->flash->{ai_eval_err};
}

=head2 index

GET /ai/eval — list of reports, newest first.

=cut

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);
    $self->_flash_to_stash($c);
    my $m = $self->_model;
    my $list = $m->list_reports($c, limit => 60);
    my $inbox = $m->inbox_dir($c);
    my @inbox_files = -d $inbox ? map { (my $n = $_) =~ s{.*/}{}; $n } sort glob("$inbox/*.json") : ();
    $c->stash(
        template    => 'ai/eval/list.tt',
        page_title  => 'Daily AI Eval Reports',
        eval_list   => $list,
        inbox_files => \@inbox_files,
        csrf_token  => $self->_csrf_token($c),
        is_admin    => 1,
        allow_list  => $m->allow_list($c)->describe,
    );
}

=head2 report

GET /ai/eval/report/<id> — metrics, summary/markdown, proposals, notes.

=cut

sub report :Local :Args(1) {
    my ($self, $c, $id) = @_;
    return unless $self->_require_admin($c);
    $self->_flash_to_stash($c);
    my $m = $self->_model;
    my $d = $m->get_report($c, $id);
    $c->response->status(404) if $d->{not_found};
    $c->stash(
        template   => 'ai/eval/detail.tt',
        page_title => 'Daily AI Eval Report' . ($d->{report} ? ' ' . $d->{report}{report_date} : ''),
        eval_detail => $d,
        csrf_token => $self->_csrf_token($c),
        is_admin   => 1,
        allow_list => $m->allow_list($c)->describe,
    );
}

=head2 report_notes

POST /ai/eval/report/<id>/notes

=cut

sub report_notes :Path('report') :Args(2) {
    my ($self, $c, $id, $what) = @_;
    my $back = $c->uri_for('/ai/eval/report', $id);
    unless (($what // '') eq 'notes' && ($id // '') =~ /^\d+$/) {
        $c->response->status(404); $c->response->body('Not found'); return;
    }
    return unless $self->_post_guard($c, $back);
    my $r = $self->_model->save_notes($c, $id, $c->req->body_params->{admin_notes}, $self->_username($c));
    $c->flash->{ $r->{ok} ? 'ai_eval_msg' : 'ai_eval_err' } = $r->{ok} ? $r->{message} : "Notes not saved: $r->{error}";
    $c->response->redirect($back . '#notes');
}

=head2 proposal

POST /ai/eval/proposal/<id>/<approve|reject|apply|revert>

=cut

sub proposal :Local :Args(2) {
    my ($self, $c, $pid, $action) = @_;
    my $rid  = $c->req->body_params->{report_id} // '';
    my $back = ($rid =~ /^\d+$/) ? $c->uri_for('/ai/eval/report', $rid) : $c->uri_for('/ai/eval');
    unless (($pid // '') =~ /^\d+$/ && ($action // '') =~ /^(?:approve|reject|apply|revert)$/) {
        $c->response->status(404); $c->response->body('Not found'); return;
    }
    return unless $self->_post_guard($c, $back);
    my $r = $self->_model->transition($c, $action, $pid, $self->_username($c));
    $c->flash->{ $r->{ok} ? 'ai_eval_msg' : 'ai_eval_err' } =
        $r->{ok} ? "#$pid: $r->{message}" : "#$pid: $action refused - $r->{error}";
    $c->response->redirect($back . "#proposal-$pid");
}

=head2 import_inbox

POST /ai/eval/import_inbox — ingest every data/ai_eval_inbox/*.json via the
same model code as /ai/eval/ingest (idempotent upsert; files stay).

=cut

sub import_inbox :Local :Args(0) {
    my ($self, $c) = @_;
    my $back = $c->uri_for('/ai/eval');
    return unless $self->_post_guard($c, $back);
    my $r = $self->_model->import_inbox($c, by => $self->_username($c));
    my @lines = map {
        $_->{ok}
          ? "$_->{file}: report #$_->{report_id} " . ($_->{created} ? 'created' : 'updated')
            . ", proposals +$_->{proposals_created} (existing $_->{proposals_skipped})"
          : "$_->{file}: " . ($_->{error} // 'failed')
            . ($_->{errors} ? ' - ' . join('; ', @{ $_->{errors} }) : '')
            . ($_->{error} && $_->{error} eq 'table_missing' ? ' - run schema compare first' : '')
    } @{ $r->{files} };
    @lines = ('No *.json files in data/ai_eval_inbox') unless @lines;
    my $failed = grep { !$_->{ok} } @{ $r->{files} };
    $c->flash->{ $failed ? 'ai_eval_err' : 'ai_eval_msg' } = 'Inbox import: ' . join(' | ', @lines);
    $c->response->redirect($back);
}

=head2 ingest

POST /ai/eval/ingest (application/json). Auth: C<Authorization: Bearer
$AI_EVAL_INGEST_TOKEN> (env, or ~/.comserv/secrets/ai_eval_ingest_token), or a
logged-in admin session plus C<X-CSRF-Token>. No token configured and no admin
session -> 403. Contract: AISYSTEMPlan §5d.

=cut

sub ingest :Local :Args(0) {
    my ($self, $c) = @_;
    my $m = $self->_model;

    unless ($c->req->method eq 'POST') {
        $c->response->header(Allow => 'POST');
        return $self->_json_out($c, 405, { ok => 0, error => 'method_not_allowed' });
    }

    my $auth = $c->req->header('Authorization') // '';
    my $by;
    if ($auth =~ /^Bearer\s+(\S+)\s*$/i) {
        my $chk = $m->check_token($c, $1);
        if ($chk ne 'ok') {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'ingest',
                "AI eval ingest refused ($chk) from " . ($c->req->address // '?'));
            return $self->_json_out($c, 403, { ok => 0,
                error => ($chk eq 'not_configured' ? 'ingest_token_not_configured' : 'forbidden') });
        }
        $by = 'ingest-token';
    } elsif ($self->_is_admin($c)) {
        return $self->_json_out($c, 403, { ok => 0, error => 'csrf', detail => 'admin session ingest needs X-CSRF-Token' })
            unless $self->_csrf_ok($c);
        $by = $self->_username($c);
    } else {
        my $configured = defined $m->expected_token($c) ? 1 : 0;
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'ingest',
            'AI eval ingest refused (no credentials) from ' . ($c->req->address // '?'));
        return $self->_json_out($c, 403, { ok => 0,
            error => ($configured ? 'forbidden' : 'ingest_token_not_configured') });
    }

    my $ct = $c->req->content_type // '';
    return $self->_json_out($c, 415, { ok => 0, error => 'unsupported_media_type', detail => 'Content-Type must be application/json' })
        unless $ct =~ m{^application/json}i;
    my $len = $c->req->content_length // 0;
    return $self->_json_out($c, 413, { ok => 0, error => 'too_large', detail => 'max ' . MAX_INGEST_BYTES . ' bytes' })
        if $len > MAX_INGEST_BYTES;

    my $data = try {
        my $body = $c->req->body;
        my $raw = ref $body ? do { local $/; seek($body, 0, 0); <$body> } : ($body // '');
        die "empty body\n" unless defined $raw && length $raw;
        die "too large\n" if length $raw > MAX_INGEST_BYTES;
        JSON->new->utf8->decode($raw);
    } catch { undef };
    return $self->_json_out($c, 400, { ok => 0, error => 'bad_json' }) unless defined $data;

    my $r = $m->ingest($c, $data, by => $by);
    my $status = delete $r->{http} || ($r->{ok} ? 200 : 500);
    delete $r->{detail} if $status == 500;   # internals stay in the app log
    return $self->_json_out($c, $status, $r);
}

__PACKAGE__->meta->make_immutable;

1;

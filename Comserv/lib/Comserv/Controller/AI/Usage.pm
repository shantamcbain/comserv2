package Comserv::Controller::AI::Usage;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use JSON qw(encode_json decode_json);
use Comserv::Util::Logging;
use Comserv::Model::AI2::UsageMonitor;

BEGIN { extends 'Catalyst::Controller' }

# namespace ai so Local names stay under /ai/*. Absolute Path() still used
# because the huge Controller::AI.pm already owns some of those names.
__PACKAGE__->config(namespace => 'ai');

# Explicit /ai/usage_* Paths so they register even when Controller::AI.pm
# (600k) failed to reload under -r. Do not duplicate these actions in AI.pm.
# Live JSON is also bridged from Controller::AI2::usage_live (/ai2/usage_live)
# because this file is new and the current :4006 process never loaded it.

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

sub _is_operator {
    my ($self, $c) = @_;
    my $address  = $c->req->address // '';
    my $is_local = ($address eq '127.0.0.1' || $address eq '::1' || $address =~ /^192\.168\.1\./);
    my $roles    = $c->session->{roles} || [];
    $roles = [ split /,/, $roles ] unless ref $roles eq 'ARRAY';
    my $is_admin = grep { /^(admin|developer)$/i } @$roles;
    return ($is_local || $is_admin) ? 1 : 0;
}

sub _org {
    my ($self, $c) = @_;
    my $days    = $c->req->param('days') || 14;
    my $prov_f  = $c->req->param('provider') || '';
    my $site_f  = $c->req->param('site_id')  || '';
    my $model_f = $c->req->param('model') || '';
    return Comserv::Model::AI2::UsageMonitor->new->org_summary($c,
        days => $days, provider => $prov_f, site_id => $site_f, model => $model_f);
}

=head2 live

GET /ai/usage_live — JSON org summary (Hermes state.db + app ledger + agents).

=cut

sub live :Path('/ai/usage_live') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json; charset=utf-8');
    unless ($self->_is_operator($c) || $c->session->{user_id}) {
        $c->response->body(encode_json({ success => JSON::false, error => 'login required' }));
        return;
    }
    my $org = eval { $self->_org($c) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'live', "$@");
        $c->response->body(encode_json({ success => JSON::false, error => 'summary failed' }));
        return;
    }
    $c->response->body(encode_json({ success => JSON::true, org => $org }));
}

=head2 ingest

POST /ai/usage_ingest — LAN/operator ingest (grok_bot / daily_eval / hermes).

=cut

sub ingest :Path('/ai/usage_ingest') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json; charset=utf-8');
    unless ($self->_is_operator($c)) {
        $c->response->body(encode_json({ success => JSON::false, error => 'operator / LAN only' }));
        return;
    }
    my $body = {};
    if (($c->req->content_type || '') =~ /json/i) {
        if (ref $c->req->body_data eq 'HASH') {
            $body = $c->req->body_data;
        }
        else {
            $body = eval { decode_json($c->req->body || '{}') } || {};
        }
    }
    $body = {} unless ref $body eq 'HASH';
    my %args;
    for my $k (qw(source request_type provider model prompt_tokens completion_tokens
                  total_tokens estimated_cost_usd status error_message user_id site_id evaluation)) {
        $args{$k} = $body->{$k} // $c->req->param($k);
    }
    $args{metadata} = $body->{metadata} if ref $body->{metadata} eq 'HASH';
    my $r = Comserv::Model::AI2::UsageMonitor->new->ingest($c, %args);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ingest',
        "source=" . ($args{source}||'?') . " model=" . ($args{model}||'?') . " ok=" . ($r->{ok} ? 1 : 0));
    $c->response->body(encode_json({
        success => $r->{ok} ? JSON::true : JSON::false,
        error   => $r->{error},
        source  => $r->{source},
    }));
}

=head2 kill

POST /ai/usage_kill — kill/unkill a model (operator).

=cut

sub kill :Path('/ai/usage_kill') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json; charset=utf-8');
    unless ($self->_is_operator($c)) {
        $c->response->body(encode_json({ success => JSON::false, error => 'operator only' }));
        return;
    }
    require Comserv::Model::AI2::KillSwitch;
    my $ks = Comserv::Model::AI2::KillSwitch->new;
    my $action   = $c->req->param('action') || 'kill';
    my $provider = $c->req->param('provider') || '';
    my $model    = $c->req->param('model') || '';
    my $result;
    if ($action eq 'unkill') {
        $result = $ks->unkill($c, provider => $provider, model => $model);
    }
    else {
        $result = $ks->kill($c,
            provider => $provider,
            model    => $model,
            reason   => $c->req->param('reason') || 'other',
            notes    => $c->req->param('notes') || '',
            by       => $c->session->{username} || 'operator',
        );
    }
    $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'kill',
        "action=$action $provider/$model ok=" . ($result->{ok} ? 1 : 0));
    $c->response->body(encode_json({
        success => $result->{ok} ? JSON::true : JSON::false,
        error   => $result->{error},
        killed  => $result->{killed} || [],
    }));
}

=head2 page

GET /ai/usage_org — HTML monitor on the satellite controller (not the 600k AI.pm).
/ai/usage stays on Controller::AI until that process is replaced; this path is
the migrated home.

=cut

sub page :Path('/ai/usage_org') :Args(0) {
    my ($self, $c) = @_;
    my $username = $c->session->{username} || 'Guest';
    my $site_id  = $c->session->{SiteID};
    my $roles    = $c->session->{roles} || [];
    $roles = [ split /,/, $roles ] unless ref $roles eq 'ARRAY';
    my $is_admin = grep { /^admin$/i } @$roles;
    my $days   = $c->req->param('days') || 14;
    my $prov_f = $c->req->param('provider') || '';
    my $site_f = $c->req->param('site_id')  || ($is_admin ? '' : $site_id);
    my $model_f= $c->req->param('model') || '';
    my $org = eval { $self->_org($c) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'page', "$@");
        $org = { errors => ['summary failed'], totals => {}, hermes => {}, agents => [] };
    }
    my $ledger_monitor;
    my $eval_summary;
    if ($is_admin) {
        $ledger_monitor = eval {
            Comserv::Model::AI2::UsageMonitor->new->ledger_summary($c, days => 14);
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'page',
            "Ledger monitor failed: $@") if $@;
        $eval_summary = eval {
            require Comserv::Model::AI2::EvalReports;
            Comserv::Model::AI2::EvalReports->new->latest_summary($c);
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'page',
            "Eval summary failed: $@") if $@;
    }
    my @providers = qw(ollama grok supergrok openrouter openai hermes xai-oauth opencode-free);
    my @sites;
    if ($is_admin) {
        eval {
            @sites = map { { id => $_->id, name => $_->name || 'Site '.$_->id } }
                     $c->model('DBEncy')->schema->resultset('Site')->search({}, { rows => 50, order_by => 'name' })->all;
        };
    }
    $c->stash(
        template         => 'ai/usage.tt',
        page_title       => 'AI Usage & Activity Monitor',
        org              => $org,
        provider_status  => {},
        filters          => { days => $days, provider => $prov_f, site_id => $site_f, model => $model_f },
        providers        => \@providers,
        sites            => \@sites,
        is_admin         => $is_admin ? 1 : 0,
        current_site     => $site_id,
        username         => $username,
        ledger_monitor   => $ledger_monitor,
        eval_summary     => $eval_summary,
    );
}

__PACKAGE__->meta->make_immutable;
1;

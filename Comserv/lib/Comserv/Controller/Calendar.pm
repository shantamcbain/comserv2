package Comserv::Controller::Calendar;

# Calendar phase 1 (Nov 2026)
#   GET  /calendar/feed/<token>.ics   read-only ICS feed (token = security boundary)
#   GET  /calendar/subscribe          subscribe URL, regenerate / revoke (session)
#   POST /calendar/subscribe          action=regenerate|revoke
#   POST /calendar/visible_sites      save the subset of my SiteNames to show
#   GET/POST /calendar/clients        my mail readers / calendars / devices list
# All access checks: Comserv::Util::AccessCheck. See root/Documentation/CalendarFeed.md.

use Moose;
use namespace::autoclean;
use Encode qw(encode_utf8);
use JSON::MaybeXS;
use Comserv::Util::AppTime;
use Comserv::Util::AccessCheck;
use Comserv::Util::CalendarFeed;
use Comserv::Util::Logging;
use Comserv::Util::UserPreferences;
use Comserv::Model::Schema::Ency::Result::UserCalendarClient ();
BEGIN { extends 'Catalyst::Controller'; }

sub logging { Comserv::Util::Logging->instance }
my $CF = 'Comserv::Util::CalendarFeed';

sub _deny_feed {
    my ($self, $c, $status) = @_;
    $c->res->status($status || 403);
    $c->res->headers->header('Cache-Control' => 'private, no-store');
    $c->res->headers->header('Referrer-Policy' => 'no-referrer');
    $c->res->content_type('text/plain; charset=utf-8');
    $c->res->body($status && $status == 429 ? "Too many requests\n" : "Forbidden\n");
    $c->detach;
}

# ------------------------------------------------------------------ feed ----

sub feed :Path('/calendar/feed') :Args(1) {
    my ($self, $c, $arg) = @_;
    my $token = $arg // ''; $token =~ s/\.ics$//i;
    my $fwd = $c->req->header('X-Forwarded-Proto') // '';
    unless ($CF->transport_ok(host => ($c->req->uri->host // ''), secure => $c->req->secure, forwarded_proto => $fwd,
                              remote => $c->req->address)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'feed', 'feed refused: plain http on a public host');
        $self->_deny_feed($c, 403);
    }
    # Rate limit per token (hash, so the plain token is not kept in memory keys).
    $self->_deny_feed($c, 429) unless $CF->rate_ok('t:' . $CF->hash_token($token));
    my $schema = $c->model('DBEncy');
    my $v = eval { $CF->validate_token($schema, $token, Comserv::Util::AppTime->now_dt) } || { ok => 0, code => 'error' };
    unless ($v->{ok}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'feed', "feed token refused ($v->{code})");
        $self->_deny_feed($c, 403);
    }
    my $u = eval { $schema->resultset('User')->find($v->{user_id}) };
    $self->_deny_feed($c, 403) unless $u;
    my $user = { user_id => $u->id, username => scalar(eval { $u->get_column('username') }) // '',
                 roles => scalar(eval { $u->get_column('roles') }) // '' };
    my $visible = eval { Comserv::Util::UserPreferences->new->get($c, $u->id, 'calendar.visible_sites') };
    my $sites = $CF->feed_sites($schema, $user, $v->{scope}, $visible);
    my $today = Comserv::Util::AppTime->now_dt;
    my $from = $today->clone->subtract(days => $Comserv::Util::CalendarFeed::PAST_DAYS)->ymd;
    my $to   = $today->clone->add(days => $Comserv::Util::CalendarFeed::FUTURE_DAYS)->ymd;
    my $base = '' . $c->uri_for('/'); $base =~ s{/+$}{};
    my $events = eval { $CF->feed_events($schema, user => $user, sites => $sites, from => $from, to => $to, app_base => $base) };
    unless ($events) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'feed', "feed build failed for token id $v->{token_id}");
        $self->_deny_feed($c, 403);       # fail closed
    }
    eval {
        $v->{row}->update({ last_used_at => Comserv::Util::AppTime->now_utc });
        $v->{row}->update({ last_used_ip => substr($c->req->address // '', 0, 45) });   # needs Schema Compare
        1;
    };
    my $ics = $CF->build_ics(name => 'Comserv - ' . ($user->{username} || 'me'), events => $events,
        now => Comserv::Util::AppTime->now_utc);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'feed',
        "feed served token id $v->{token_id}: " . scalar(@$events) . ' events, sites ' . join(',', @$sites));
    $c->res->headers->header('Cache-Control' => 'private, no-store');
    $c->res->headers->header('Referrer-Policy' => 'no-referrer');
    $c->res->headers->header('X-Content-Type-Options' => 'nosniff');
    $c->res->headers->header('Content-Disposition' => 'inline; filename="comserv.ics"');
    $c->res->content_type('text/calendar; charset=utf-8');
    $c->res->body(utf8::is_utf8($ics) ? encode_utf8($ics) : $ics);
}

# ------------------------------------------------------------ session pages ----

sub _require_user {
    my ($self, $c, $json) = @_;
    my $uid = $c->session->{user_id};
    my $acc = $uid ? Comserv::Util::AccessCheck->check_session($c, module => 'calendar', action => 'read',
        legacy_roles => [qw(admin developer)]) : { ok => 0, error => 'Please log in' };
    return $uid if $acc->{ok};
    if ($json) {
        $c->res->status(403);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ ok => 0, error => $acc->{error} || 'Not allowed' }));
    } else {
        $c->flash->{error_msg} = $acc->{error} || 'You do not have calendar access.';
        $c->res->redirect($c->uri_for($uid ? '/' : '/user/login'));
    }
    $c->detach;
}

# POSTs must come from our own pages: scheme + host + effective port of every
# Origin/Referer must match the request (shared helper Comserv::Util::OriginCheck).
sub _same_origin {
    my ($self, $c) = @_;
    require Comserv::Util::OriginCheck;
    return Comserv::Util::OriginCheck->request_ok($c);
}

sub _feed_tokens {
    my ($self, $c, $uid) = @_;
    return [ eval { $c->model('DBEncy')->resultset('ApiToken')->search(
        { user_id => $uid, token_name => $Comserv::Util::CalendarFeed::TOKEN_NAME, is_active => 1, revoked_at => undef },
        { order_by => { -desc => 'id' } })->all } ];
}

sub _revoke_all {
    my ($self, $c, $uid) = @_;
    my $now = Comserv::Util::AppTime->now_utc;
    for my $t (@{ $self->_feed_tokens($c, $uid) }) { $t->update({ is_active => 0, revoked_at => $now }) }
}

sub subscribe :Path('/calendar/subscribe') :Args(0) {
    my ($self, $c) = @_;
    my $uid = $self->_require_user($c);
    my ($plain, $msg, $err);
    if ($c->req->method eq 'POST') {
        my $action = $c->req->params->{action} // '';
        if (!$self->_same_origin($c)) { $err = 'Request refused (cross-site).' }
        elsif ($action eq 'revoke') {
            eval { $self->_revoke_all($c, $uid); 1 } ? ($msg = 'Feed link revoked. Calendars using it stop updating now.')
                                                     : ($err = 'Could not revoke; try again.');
        } elsif ($action eq 'regenerate') {
            my $ok = eval {
                my $schema = $c->model('DBEncy');
                $schema->txn_do(sub {
                    $self->_revoke_all($c, $uid);
                    $plain = $CF->new_token;
                    $schema->resultset('ApiToken')->create({
                        user_id => $uid, token_hash => $CF->hash_token($plain),
                        token_name => $Comserv::Util::CalendarFeed::TOKEN_NAME, is_active => 1,
                        created_at => Comserv::Util::AppTime->now_utc,
                        scope_modules => $Comserv::Util::CalendarFeed::SCOPE_MODULES,
                        scope_actions => $Comserv::Util::CalendarFeed::SCOPE_ACTIONS, own_only => 1,
                    });
                });
                1;
            };
            unless ($ok) {
                undef $plain;
                $err = 'Could not create a feed link. If this is new, ask an admin to run Schema Compare (api_tokens scope columns).';
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'subscribe', 'feed token create failed');
            } else { $msg = 'New feed link created. Copy it now: it is shown only once. Any older link stopped working.' }
        }
    }
    my $tokens = $self->_feed_tokens($c, $uid);
    my $base = '' . $c->uri_for('/calendar/feed/'); $base =~ s{/+$}{/};
    my $fwd = $c->req->header('X-Forwarded-Proto') // '';
    require Comserv::Util::ClientIP;
    $base =~ s{^http://}{https://} if lc($fwd) eq 'https' && Comserv::Util::ClientIP->is_trusted_proxy($c->req->address);
    $c->res->headers->header('Cache-Control' => 'private, no-store');
    $c->res->headers->header('Referrer-Policy' => 'no-referrer');
    $c->stash(
        template      => 'calendar/subscribe.tt',
        feed_url      => ($plain ? $base . $plain . '.ics' : undef),
        has_token     => scalar(@$tokens),
        token_info    => [ map { { id => $_->id, created_at => '' . ($_->created_at // ''),
                                   last_used_at => '' . ($_->last_used_at // '') } } @$tokens ],
        status_msg    => $msg, error_msg => $err,
        transport_note => ($CF->transport_ok(host => ($c->req->uri->host // ''), secure => $c->req->secure, forwarded_proto => $fwd, remote => $c->req->address)
            ? '' : 'This site is being viewed over plain http; the feed only works over https on public domains.'),
    );
}

sub visible_sites :Path('/calendar/visible_sites') :Args(0) {
    my ($self, $c) = @_;
    my $uid = $self->_require_user($c, 1);
    my $out = sub { $c->res->content_type('application/json'); $c->res->body(encode_json($_[0])) };
    return $out->({ ok => 0, error => 'POST only' }) unless $c->req->method eq 'POST' && $self->_same_origin($c);
    my @want = $c->req->param('sites');
    @want = map { split /,/ } @want;
    my $mine = eval { $c->controller('Todo')->_get_user_accessible_sites($c) } || [];
    my %ok = map { $_ => 1 } @$mine;
    my @keep = grep { $ok{$_} } @want;              # only SiteNames the user really has
    my $res = Comserv::Util::UserPreferences->new->set_many($c, $uid, { 'calendar.visible_sites' => \@keep });
    delete $c->session->{cal_filter_site} if $res->{ok};   # show the saved subset
    return $out->($res->{ok} ? { ok => 1, sites => \@keep } : { ok => 0, error => $res->{error} || 'Could not save' });
}

sub clients :Path('/calendar/clients') :Args(0) {
    my ($self, $c) = @_;
    my $uid = $self->_require_user($c);
    my $schema = $c->model('DBEncy');
    my $rs = eval { $schema->resultset('UserCalendarClient') };
    my ($msg, $err);
    my %types = map { $_ => 1 } @Comserv::Model::Schema::Ency::Result::UserCalendarClient::CLIENT_TYPES;
    if ($c->req->method eq 'POST') {
        my $p = $c->req->params;
        my $act = $p->{action} // '';
        my $ok = $self->_same_origin($c) && eval {
            my $now = Comserv::Util::AppTime->now_utc;
            if ($act eq 'add') {
                my $type = $types{ $p->{client_type} // '' } ? $p->{client_type} : 'other';
                my %row = (user_id => $uid, client_type => $type, label => substr($p->{label} // '', 0, 100),
                    enabled => 1, may_read => ($p->{may_read} ? 1 : 0), may_alert => ($p->{may_alert} ? 1 : 0),
                    sweep_order => ($Comserv::Model::Schema::Ency::Result::UserCalendarClient::DEFAULT_ORDER{$type} // 50),
                    ua_hint => substr($p->{ua_hint} // '', 0, 100) || undef, created_at => $now, updated_at => $now);
                if (length($p->{push_endpoint} // '')) {
                    require Comserv::Util::Encryption;
                    $row{push_endpoint_enc} = Comserv::Util::Encryption->encrypt($p->{push_endpoint}, 'calendar_push');
                    $row{push_key_enc} = Comserv::Util::Encryption->encrypt($p->{push_key}, 'calendar_push') if length($p->{push_key} // '');
                }
                $rs->create(\%row);
            } elsif ($act =~ /^(toggle|delete)$/ && ($p->{id} // '') =~ /^\d+$/) {
                my $row = $rs->search({ id => $p->{id}, user_id => $uid })->single or die "not yours\n";   # own_only
                if ($act eq 'delete') { $row->delete }
                else {
                    my $f = ($p->{field} // '') =~ /^(enabled|may_read|may_alert)$/ ? $1 : die "bad field\n";
                    $row->update({ $f => ($row->get_column($f) ? 0 : 1), updated_at => $now });
                }
            }
            1;
        };
        $ok ? ($msg = 'Saved.') : ($err = 'Could not save (if this is new, ask an admin to run Schema Compare for user_calendar_clients).');
    }
    my @rows = eval { $rs->search({ user_id => $uid }, { order_by => ['sweep_order', 'id'],
        columns => [qw(id client_type label enabled may_read may_alert sweep_order ua_hint last_seen_at push_endpoint_enc)] })->all };
    $err //= 'Calendar clients table not available yet (Schema Compare).' if $@;
    $c->stash(template => 'calendar/clients.tt', status_msg => $msg, error_msg => $err,
        client_types => [ @Comserv::Model::Schema::Ency::Result::UserCalendarClient::CLIENT_TYPES ],
        clients => [ map { { id => $_->id, client_type => $_->client_type, label => $_->label, enabled => $_->enabled,
            may_read => $_->may_read, may_alert => $_->may_alert, sweep_order => $_->sweep_order, ua_hint => $_->ua_hint,
            has_push => ($_->get_column('push_endpoint_enc') ? 1 : 0) } } @rows ]);
}

__PACKAGE__->meta->make_immutable;
1;

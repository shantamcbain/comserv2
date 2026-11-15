package Comserv::Controller::Admin::ZeroTier;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use Comserv::Util::Logging;
use Comserv::Util::ZeroTier;
use Comserv::Util::ZeroTierCredentials;

BEGIN { extends 'Comserv::Controller::Base'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

sub begin :Private {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} || [];
    if (ref $roles ne 'ARRAY') {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'begin',
            'Invalid or undefined roles in session');
        $c->res->redirect($c->uri_for('/user/login'));
        $c->detach;
    }
    unless (grep { $_ eq 'admin' || $_ eq 'developer' } @$roles) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'begin',
            'Unauthorized ZeroTier page attempt by ' . ($c->session->{username} || 'Guest'));
        $c->res->redirect($c->uri_for('/'));
        $c->detach;
    }
}

sub index :Path('/admin/infrastructure/zerotier') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        'Loading ZeroTier network page');
    my $page = $self->_page($c);
    $c->stash(%$page, template => 'admin/infrastructure/zerotier.tt');
}

sub save_token :Path('/admin/infrastructure/zerotier/token') :Args(0) {
    my ($self, $c) = @_;
    return $self->_reject_get($c) unless $c->req->method eq 'POST';
    my $params = $c->req->body_parameters;
    my $id = $params->{network_id} // '';
    my $token = $params->{api_token} // '';
    my $by = $c->session->{username} || 'zerotier';
    unless (Comserv::Util::ZeroTier::valid_network_id($id)) {
        $c->flash->{error_msg} = 'Network id must be 16 hex characters. Nothing was saved.';
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    my $id_saved = Comserv::Util::ZeroTierCredentials::save_network_id($id, $by);
    unless ($id_saved->{ok}) {
        $c->flash->{error_msg} = $id_saved->{error};
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    if ($token =~ /\S/) {
        my $saved = Comserv::Util::ZeroTierCredentials::save_token($token, $by);
        unless ($saved->{ok}) {
            $c->flash->{error_msg} = $saved->{error};
            $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
            return;
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'save_token',
            "ZeroTier token replaced for network $id by $by");
    } elsif (!Comserv::Util::ZeroTierCredentials::token_is_set()) {
        $c->flash->{error_msg} = 'Network id was saved. A token is still required before the page can read ZeroTier.';
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    delete $c->session->{zerotier_pending};
    $c->flash->{success_msg} = 'ZeroTier connection saved. The token is not shown.';
    $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
}

sub preview :Path('/admin/infrastructure/zerotier/preview') :Args(0) {
    my ($self, $c) = @_;
    return $self->_reject_get($c) unless $c->req->method eq 'POST';
    my $params = $c->req->body_parameters;
    my $parsed = $self->_parse_proposal($params);
    unless ($parsed->{ok}) {
        $c->flash->{error_msg} = $parsed->{error};
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    my $live = $self->_live($c);
    unless ($live->{ok}) {
        $c->flash->{error_msg} = $live->{error};
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    $self->_store_pending($c, 'update', $live, $parsed);
    $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
}

sub undo :Path('/admin/infrastructure/zerotier/undo') :Args(0) {
    my ($self, $c) = @_;
    return $self->_reject_get($c) unless $c->req->method eq 'POST';
    my $snap = Comserv::Util::ZeroTierCredentials::load_undo();
    unless ($snap && ref $snap->{routes} eq 'ARRAY') {
        $c->flash->{error_msg} = 'There is no saved change to undo.';
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    my $live = $self->_live($c);
    unless ($live->{ok}) {
        $c->flash->{error_msg} = $live->{error};
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    $self->_store_pending($c, 'undo', $live, {
        ok     => 1,
        routes => $snap->{routes},
        dns    => $snap->{dns} || { domain => '', servers => [] },
    });
    $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
}

sub confirm :Path('/admin/infrastructure/zerotier/confirm') :Args(0) {
    my ($self, $c) = @_;
    return $self->_reject_get($c) unless $c->req->method eq 'POST';
    my $pending = $c->session->{zerotier_pending};
    my $sha = $c->req->body_parameters->{pending_sha} // '';
    my $now = time;
    unless (Comserv::Util::ZeroTier::pending_ok($pending, $sha, $now)) {
        delete $c->session->{zerotier_pending};
        $c->flash->{error_msg} = 'That confirmation does not match the preview, or it expired. Nothing was changed.';
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    my $network_id = Comserv::Util::ZeroTierCredentials::load_network_id();
    if (($pending->{network_id} // '') ne $network_id) {
        delete $c->session->{zerotier_pending};
        $c->flash->{error_msg} = 'The network id changed after the preview. Nothing was changed.';
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    my $live = $self->_live($c);
    unless ($live->{ok}) {
        $c->flash->{error_msg} = $live->{error} . ' Nothing was changed.';
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    my $base = $pending->{baseline} || {};
    unless (Comserv::Util::ZeroTier::settings_equal(
        $base->{routes}, $base->{dns}, $live->{routes}, $live->{dns}
    )) {
        delete $c->session->{zerotier_pending};
        $c->flash->{error_msg} = 'The network changed after the preview. Nothing was changed. Preview again.';
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    my $by = $c->session->{username} || 'zerotier';
    my $old_routes = Comserv::Util::ZeroTier::format_routes($live->{routes});
    my $old_dns = ($live->{dns}{domain} // '') . ' servers='
        . Comserv::Util::ZeroTier::format_dns_servers($live->{dns});
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'confirm',
        "ZeroTier previous settings for $network_id by $by. routes: $old_routes. dns: $old_dns");
    my $record = Comserv::Util::ZeroTier::undo_record($live->{routes}, $live->{dns}, $by);
    my $undo = Comserv::Util::ZeroTierCredentials::save_undo($record, $by);
    unless ($undo->{ok}) {
        $c->flash->{error_msg} = 'The previous settings could not be saved, so the change was not sent.';
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    my $proposed = $pending->{proposed};
    my $client = $self->_client($c);
    my $wrote = eval {
        $client->update_settings($proposed->{routes}, $proposed->{dns});
    };
    if ($@ || !$wrote) {
        my $err = Comserv::Util::ZeroTier::redact("$@", $client->{token});
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'confirm',
            "ZeroTier update failed: $err");
        $c->flash->{error_msg} = 'ZeroTier update failed before a response. Nothing was confirmed.';
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    delete $c->session->{zerotier_pending};
    unless ($wrote->{ok}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'confirm',
            'ZeroTier update refused: ' . ($wrote->{error} || 'no detail'));
        $c->flash->{error_msg} = $wrote->{error} || 'ZeroTier refused the change.';
        $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
        return;
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'confirm',
        "ZeroTier routes and DNS updated for $network_id by $by ($pending->{op})");
    $c->flash->{success_msg} = 'ZeroTier routes and DNS were updated.';
    $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
}

sub _reject_get {
    my ($self, $c) = @_;
    $c->res->redirect($c->uri_for('/admin/infrastructure/zerotier'));
    return;
}

sub _parse_proposal {
    my ($self, $params) = @_;
    my $routes = Comserv::Util::ZeroTier::parse_routes($params->{routes_text});
    return $routes unless $routes->{ok};
    my $dns = Comserv::Util::ZeroTier::parse_dns($params->{dns_domain}, $params->{dns_servers});
    return $dns unless $dns->{ok};
    return { ok => 1, routes => $routes->{routes}, dns => $dns->{dns} };
}

sub _client {
    my ($self, $c) = @_;
    my $token = Comserv::Util::ZeroTierCredentials::load_token();
    my $id = Comserv::Util::ZeroTierCredentials::load_network_id();
    return Comserv::Util::ZeroTier->new({ token => $token, network_id => $id });
}

sub _live {
    my ($self, $c) = @_;
    unless (Comserv::Util::ZeroTierCredentials::token_is_set()) {
        return { ok => 0, error => 'No token is saved. Nothing was read from ZeroTier.' };
    }
    my $client = $self->_client($c);
    my $net = eval { $client->fetch_network };
    if ($@ || !$net) {
        my $err = Comserv::Util::ZeroTier::redact("$@", $client->{token});
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_live',
            "ZeroTier network read failed: $err");
        return { ok => 0, error => 'Could not read the ZeroTier network.' };
    }
    unless ($net->{ok}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_live',
            'ZeroTier network read failed: ' . ($net->{error} || 'no detail'));
        return { ok => 0, error => $net->{error} || 'Could not read the ZeroTier network.' };
    }
    my $members = eval { $client->fetch_members };
    my $member_rows = [];
    my $member_error = '';
    if ($@ || !$members) {
        my $err = Comserv::Util::ZeroTier::redact("$@", $client->{token});
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_live',
            "ZeroTier member read failed: $err");
        $member_error = 'Device list could not be read, so orphan routes cannot be judged.';
    } elsif (!$members->{ok}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_live',
            'ZeroTier member read failed: ' . ($members->{error} || 'no detail'));
        $member_error = $members->{error} || 'Device list could not be read.';
    } else {
        $member_rows = $members->{json};
    }
    my $cfg = $net->{json}{config} || {};
    return {
        ok            => 1,
        network       => $net->{json},
        members       => $member_rows,
        member_error  => $member_error,
        routes        => $cfg->{routes} || [],
        dns           => $cfg->{dns} || { domain => '', servers => [] },
        network_id    => $client->{network_id},
    };
}

sub _store_pending {
    my ($self, $c, $op, $live, $parsed) = @_;
    my $proposed = Comserv::Util::ZeroTier::normalize_settings($parsed->{routes}, $parsed->{dns});
    my $baseline = Comserv::Util::ZeroTier::normalize_settings($live->{routes}, $live->{dns});
    my $sha = Comserv::Util::ZeroTier::pending_sha($op, $live->{network_id}, $proposed);
    $c->session->{zerotier_pending} = {
        op         => $op,
        sha        => $sha,
        at         => time,
        network_id => $live->{network_id},
        proposed   => $proposed,
        baseline   => $baseline,
    };
    return $sha;
}

sub _page {
    my ($self, $c) = @_;
    my $network_id = eval { Comserv::Util::ZeroTierCredentials::load_network_id() }
        || $Comserv::Util::ZeroTier::DEFAULT_NETWORK_ID;
    my $token_set = eval { Comserv::Util::ZeroTierCredentials::token_is_set() } ? 1 : 0;
    my $undo = eval { Comserv::Util::ZeroTierCredentials::load_undo() };
    # Credential methods log their own database failures. Do not trust $@ here:
    # a caught failure inside those methods leaves it set.
    my $page = {
        zt_network_id => $network_id,
        zt_token_set  => $token_set,
        zt_undo       => ($undo && ref $undo eq 'HASH') ? 1 : 0,
        zt_error      => '',
        zt_view       => undef,
        zt_pending    => undef,
    };
    my $pending = $c->session->{zerotier_pending};
    if ($pending && Comserv::Util::ZeroTier::pending_ok($pending, $pending->{sha}, time)) {
        $page->{zt_pending} = $pending;
    } elsif ($pending) {
        delete $c->session->{zerotier_pending};
    }
    return $page unless $token_set;
    my $live = $self->_live($c);
    unless ($live->{ok}) {
        $page->{zt_error} = $live->{error};
        return $page;
    }
    $page->{zt_view} = Comserv::Util::ZeroTier::view_from_api($live->{network}, $live->{members});
    $page->{zt_member_error} = $live->{member_error};
    if ($page->{zt_pending}) {
        $page->{zt_proposed_routes} = Comserv::Util::ZeroTier::flag_orphan_routes(
            $page->{zt_pending}{proposed}{routes}, $live->{members});
        $page->{zt_current_routes} = Comserv::Util::ZeroTier::flag_orphan_routes(
            $live->{routes}, $live->{members});
    }
    return $page;
}

__PACKAGE__->meta->make_immutable;

1;

package Comserv::Controller::CloudflareAPI;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Util::CloudflareManager;
use Try::Tiny;
use URI::Escape;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'cloudflareapi');

has 'logging'    => (is => 'ro', default => sub { Comserv::Util::Logging->instance });
has 'admin_auth' => (is => 'ro', default => sub { Comserv::Util::AdminAuth->new });

sub auto :Private {
    my ($self, $c) = @_;
    unless ($self->admin_auth->check_admin_access($c, 'dns')) {
        $c->flash->{error_msg} = 'Administrator access required.';
        $c->response->redirect($c->uri_for('/'));
        return 0;
    }
    $c->stash->{is_csc_admin} = $self->admin_auth->is_csc_admin($c);
    $c->stash->{allowed_zones} = $self->_allowed_zones($c);
    return 1;
}

sub _cf {
    my ($self, $c) = @_;
    my $dbh = eval { $c->model('DBEncy')->storage->dbh };
    return Comserv::Util::CloudflareManager->new(dbh => $dbh);
}

sub _allowed_zones {
    my ($self, $c) = @_;
    return undef if $c->stash->{is_csc_admin};

    my $site_name = $c->session->{SiteName} || '';
    return [] unless $site_name;

    my @domains;
    eval {
        my @sitedomains = $c->model('DBEncy')->resultset('SiteDomain')
            ->search(
                { 'site.name' => $site_name },
                { join => 'site' }
            )->all;

        for my $sd (@sitedomains) {
            my $d = $sd->domain || '';
            next unless $d;
            my ($zone) = ($d =~ /([^.]+\.[^.]+)$/);
            next unless $zone;
            push @domains, $zone if $d eq $zone;
        }
    };

    my %seen;
    return [ grep { !$seen{$_}++ } @domains ];
}

sub _can_manage_zone {
    my ($self, $c, $zone_name) = @_;
    return 1 if $c->stash->{is_csc_admin};
    my $allowed = $c->stash->{allowed_zones} || [];
    return grep { $_ eq $zone_name } @$allowed;
}

# Legacy routes from pre-refactor Cloudflare controller (production bookmarks).
sub dns_records :Path('dns_records') :Args(0) {
    my ($self, $c) = @_;
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

sub dns :Path('dns') :Args(1) {
    my ($self, $c, $domain) = @_;
    $domain =~ s/[^A-Za-z0-9._-]//g;
    return $c->response->redirect($c->uri_for($self->action_for('index'))) unless $domain;
    $c->response->redirect($c->uri_for('/cloudflareapi/zone/' . $domain));
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    my (@zones, $cf_error);
    try {
        my $cf  = $self->_cf($c);
        my $raw = $cf->_api_request('GET', '/zones?per_page=50');
        my @all = ref $raw eq 'HASH'  ? @{ $raw->{result} || [] }
                : ref $raw eq 'ARRAY' ? @$raw
                : ();
        my $allowed = $c->stash->{allowed_zones};
        for my $zone (@all) {
            next unless ref $zone eq 'HASH' && $zone->{name};
            if ($allowed) {
                next unless grep { $_ eq $zone->{name} } @$allowed;
            }
            push @zones, {
                id     => $zone->{id},
                name   => $zone->{name},
                status => $zone->{status} || 'unknown',
                plan   => ($zone->{plan} && $zone->{plan}{name}) ? $zone->{plan}{name} : '',
            };
        }
    } catch {
        $cf_error = $_;
    };

    $c->stash(
        template  => 'cloudflare/index.tt',
        zones     => \@zones,
        cf_error  => $cf_error,
    );
}

sub zone :Path('zone') :Args(1) {
    my ($self, $c, $zone_name) = @_;

    unless ($self->_can_manage_zone($c, $zone_name)) {
        $c->flash->{error_msg} = "You do not have permission to manage zone '$zone_name'.";
        return $c->response->redirect($c->uri_for($self->action_for('index')));
    }

    my (@records, $zone_id, $cf_error);
    try {
        my $cf = $self->_cf($c);
        my $zones_resp = $cf->_api_request('GET',
            '/zones?name=' . uri_escape($zone_name) . '&per_page=5');
        my @zones = ref $zones_resp eq 'HASH'  ? @{ $zones_resp->{result} || [] }
                  : ref $zones_resp eq 'ARRAY' ? @$zones_resp
                  : ();
        die "Zone '$zone_name' not found in Cloudflare" unless @zones;
        $zone_id = $zones[0]{id};

        my $recs_resp = $cf->_api_request('GET',
            "/zones/$zone_id/dns_records?per_page=100");
        my @recs = ref $recs_resp eq 'HASH'  ? @{ $recs_resp->{result} || [] }
                 : ref $recs_resp eq 'ARRAY' ? @$recs_resp
                 : ();
        for my $r (@recs) {
            next unless ref $r eq 'HASH';
            push @records, {
                id      => $r->{id},
                type    => $r->{type},
                name    => $r->{name},
                content => $r->{content},
                ttl     => $r->{ttl},
                proxied => $r->{proxied} ? 1 : 0,
            };
        }
    } catch {
        $cf_error = $_;
    };

    my $highlight_host = $c->req->params->{host} || '';
    $highlight_host =~ s/[^A-Za-z0-9._-]//g;

    $c->stash(
        template       => 'cloudflare/zone.tt',
        zone_name      => $zone_name,
        zone_id        => $zone_id,
        records        => \@records,
        cf_error       => $cf_error,
        highlight_host => $highlight_host,
    );
}

sub add_record :Path('add_record') :Args(1) {
    my ($self, $c, $zone_name) = @_;

    unless ($self->_can_manage_zone($c, $zone_name)) {
        $c->flash->{error_msg} = "Permission denied for zone '$zone_name'.";
        return $c->response->redirect($c->uri_for($self->action_for('index')));
    }

    return $c->response->redirect($c->uri_for('/cloudflareapi/zone/' . $zone_name))
        unless $c->req->method eq 'POST';

    my $p = $c->req->params;
    my $type    = uc($p->{type}    || 'A');
    my $name    = $p->{name}    || '';
    my $content = $p->{content} || '';
    my $ttl     = $p->{ttl}     || 1;
    my $proxied = $p->{proxied} ? \1 : \0;

    unless ($name && $content) {
        $c->flash->{error_msg} = 'Name and content are required.';
        return $c->response->redirect($c->uri_for('/cloudflareapi/zone/' . $zone_name));
    }

    try {
        my $cf = $self->_cf($c);
        my $zones_resp = $cf->_api_request('GET',
            '/zones?name=' . uri_escape($zone_name) . '&per_page=5');
        my @zones = ref $zones_resp eq 'HASH'  ? @{ $zones_resp->{result} || [] }
                  : ref $zones_resp eq 'ARRAY' ? @$zones_resp
                  : ();
        die "Zone '$zone_name' not found" unless @zones;
        my $zone_id = $zones[0]{id};

        $cf->_api_request('POST', "/zones/$zone_id/dns_records", {
            type    => $type,
            name    => $name,
            content => $content,
            ttl     => $ttl + 0,
            proxied => ($type eq 'A' || $type eq 'AAAA' || $type eq 'CNAME') ? $proxied : \0,
        });
        $c->flash->{success_msg} = "Record '$name' added.";
    } catch {
        $c->flash->{error_msg} = "Failed to add record: $_";
    };

    $c->response->redirect($c->uri_for('/cloudflareapi/zone/' . $zone_name));
}

sub edit_record :Path('edit_record') :Args(2) {
    my ($self, $c, $zone_name, $record_id) = @_;

    unless ($self->_can_manage_zone($c, $zone_name)) {
        $c->flash->{error_msg} = "Permission denied for zone '$zone_name'.";
        return $c->response->redirect($c->uri_for($self->action_for('index')));
    }

    return $c->response->redirect($c->uri_for('/cloudflareapi/zone/' . $zone_name))
        unless $c->req->method eq 'POST';

    my $p = $c->req->params;

    try {
        my $cf = $self->_cf($c);
        my $zones_resp = $cf->_api_request('GET',
            '/zones?name=' . uri_escape($zone_name) . '&per_page=5');
        my @zones = ref $zones_resp eq 'HASH'  ? @{ $zones_resp->{result} || [] }
                  : ref $zones_resp eq 'ARRAY' ? @$zones_resp
                  : ();
        die "Zone '$zone_name' not found" unless @zones;
        my $zone_id = $zones[0]{id};

        my $type    = uc($p->{type} || 'A');
        my $proxied = $p->{proxied} ? \1 : \0;
        $cf->_api_request('PATCH', "/zones/$zone_id/dns_records/$record_id", {
            type    => $type,
            name    => $p->{name}    || '',
            content => $p->{content} || '',
            ttl     => ($p->{ttl} || 1) + 0,
            proxied => ($type eq 'A' || $type eq 'AAAA' || $type eq 'CNAME') ? $proxied : \0,
        });
        $c->flash->{success_msg} = "Record updated.";
    } catch {
        $c->flash->{error_msg} = "Failed to update record: $_";
    };

    $c->response->redirect($c->uri_for('/cloudflareapi/zone/' . $zone_name));
}

sub delete_record :Path('delete_record') :Args(2) {
    my ($self, $c, $zone_name, $record_id) = @_;

    unless ($self->_can_manage_zone($c, $zone_name)) {
        $c->flash->{error_msg} = "Permission denied for zone '$zone_name'.";
        return $c->response->redirect($c->uri_for($self->action_for('index')));
    }

    try {
        my $cf = $self->_cf($c);
        my $zones_resp = $cf->_api_request('GET',
            '/zones?name=' . uri_escape($zone_name) . '&per_page=5');
        my @zones = ref $zones_resp eq 'HASH'  ? @{ $zones_resp->{result} || [] }
                  : ref $zones_resp eq 'ARRAY' ? @$zones_resp
                  : ();
        die "Zone '$zone_name' not found" unless @zones;
        my $zone_id = $zones[0]{id};

        $cf->_api_request('DELETE', "/zones/$zone_id/dns_records/$record_id");
        $c->flash->{success_msg} = "Record deleted.";
    } catch {
        $c->flash->{error_msg} = "Failed to delete record: $_";
    };

    $c->response->redirect($c->uri_for('/cloudflareapi/zone/' . $zone_name));
}

__PACKAGE__->meta->make_immutable;
1;

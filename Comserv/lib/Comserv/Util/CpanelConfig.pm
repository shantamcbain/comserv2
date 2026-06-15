package Comserv::Util::CpanelConfig;
use strict;
use warnings;
use JSON qw(encode_json decode_json);
use Comserv::Util::Logging;

# Per-site cPanel API settings stored once in site_config.config_key = 'cpanel_api'.
# Falls back to comserv.conf <cPanel> block when site has no row.

sub _log {
    return Comserv::Util::Logging->instance;
}

sub get {
    my ($class, $c, $site_id) = @_;
    $site_id //= _site_id_from_context($c);
    my %cfg;

    if ($site_id) {
        eval {
            my $row = $c->model('DBEncy')->resultset('SiteConfig')->find({
                site_id    => $site_id,
                config_key => 'cpanel_api',
            });
            if ($row && $row->config_value && $row->config_value =~ /\S/) {
                my $parsed = decode_json($row->config_value);
                %cfg = %$parsed if ref $parsed eq 'HASH';
            }
        };
    }

    my $global = $c->config->{cPanel} || {};
    for my $key (qw(host username api_token password port default_domain)) {
        $cfg{$key} //= $global->{$key} if defined $global->{$key} && $global->{$key} =~ /\S/;
    }
    $cfg{port} //= 2083;

    unless ($cfg{default_domain}) {
        $cfg{default_domain} = _guess_default_domain($c, $site_id);
    }

    $cfg{configured} = ($cfg{host} && $cfg{username} && ($cfg{api_token} || $cfg{password})) ? 1 : 0;
    return \%cfg;
}

sub save {
    my ($class, $c, $site_id, $params) = @_;
    return (0, 'site_id required') unless $site_id;
    $params ||= {};

    my $existing = $class->get($c, $site_id);
    my %out = (
        host           => _trim($params->{host}           // $existing->{host}),
        username       => _trim($params->{username}       // $existing->{username}),
        default_domain => _trim($params->{default_domain} // $existing->{default_domain}),
        port           => int($params->{port} // $existing->{port} // 2083),
    );

    my $token = $params->{api_token};
    $token = _trim($token) if defined $token;
    if (defined $token && $token ne '' && $token !~ /^\*+$/) {
        $out{api_token} = $token;
    } elsif ($existing->{api_token}) {
        $out{api_token} = $existing->{api_token};
    }

    my $pass = $params->{password};
    $pass = _trim($pass) if defined $pass;
    if (defined $pass && $pass ne '' && $pass !~ /^\*+$/) {
        $out{password} = $pass;
    } elsif ($existing->{password}) {
        $out{password} = $existing->{password};
    }

    unless ($out{host} && $out{username} && ($out{api_token} || $out{password})) {
        return (0, 'host, username, and api_token (or password) are required');
    }

    eval {
        $c->model('DBEncy')->resultset('SiteConfig')->update_or_create({
            site_id      => $site_id,
            config_key   => 'cpanel_api',
            config_value => encode_json(\%out),
        });
    };
    if ($@) {
        _log()->log_with_details($c, 'error', __FILE__, __LINE__, 'save', "cpanel_api save failed: $@");
        return (0, "$@");
    }
    return (1, undef);
}

sub for_display {
    my ($class, $c, $site_id) = @_;
    my $cfg = $class->get($c, $site_id);
    my %d = %$cfg;
    $d{api_token} = _mask($d{api_token}) if $d{api_token};
    $d{password}  = _mask($d{password})  if $d{password};
    delete $d{configured};
    return \%d;
}

sub list_backend_meta {
    my ($class, $list, $cpanel_cfg) = @_;
    return {} unless $list && ($list->list_backend // '') eq 'cpanel';
    $cpanel_cfg ||= {};

    my %meta;
    if ($list->backend_config && $list->backend_config =~ /^\s*\{/) {
        eval { %meta = %{ decode_json($list->backend_config) } };
    }
    $meta{domain}    //= $cpanel_cfg->{default_domain};
    $meta{list_name} //= '';
    if (!$meta{list_name} && $list->list_email && $list->list_email =~ /^([^\@]+)\@(.+)$/) {
        $meta{list_name} = $1;
        $meta{domain}    //= $2;
    }
    return \%meta;
}

sub list_address {
    my ($class, $list, $cpanel_cfg) = @_;
    return $list->list_email if $list->list_email && $list->list_email =~ /\@/;
    my $meta = $class->list_backend_meta($list, $cpanel_cfg);
    return '' unless $meta->{list_name} && $meta->{domain};
    return lc("$meta->{list_name}\@$meta->{domain}");
}

sub _site_id_from_context {
    my ($c) = @_;
    return $c->session->{site_id} || $c->session->{SiteID} || $c->stash->{site_id};
}

sub _guess_default_domain {
    my ($c, $site_id) = @_;
    my $domain;
    eval {
        if ($site_id) {
            my $site = $c->model('DBEncy')->resultset('Site')->find($site_id);
            if ($site && $site->name) {
                my $sd = $c->model('DBEncy')->resultset('SiteDomain')->search(
                    { site_id => $site_id },
                    { rows => 1, order_by => { -asc => 'id' } },
                )->single;
                $domain = $sd->domain if $sd && $sd->can('domain') && $sd->domain;
            }
        }
        $domain //= $c->req->uri->host if $c->req;
    };
    $domain =~ s/:\d+$// if $domain;
    return $domain // '';
}

sub _trim {
    my ($v) = @_;
    return '' unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    return $v;
}

sub _mask {
    my ($v) = @_;
    return '' unless defined $v && $v =~ /\S/;
    return '********' if length($v) <= 8;
    return substr($v, 0, 4) . '********' . substr($v, -4);
}

1;
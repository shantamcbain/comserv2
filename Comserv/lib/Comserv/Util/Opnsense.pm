package Comserv::Util::Opnsense;

use strict;
use warnings;
use JSON::MaybeXS qw(encode_json decode_json);
use LWP::UserAgent;
use HTTP::Request;
use MIME::Base64 qw(encode_base64);

sub _api_base_url {
    my ($host, $port) = @_;
    $port = int($port) if defined $port && $port ne '';
    $port ||= 8443;
    # OPNsense GUI/API listens on 8443; :443 often 301-redirects and breaks API auth.
    if ($port == 443 || $port == 80) {
        return "https://$host/api";
    }
    return "https://$host:$port/api";
}

sub new {
    my ($class, $config) = @_;
    $config ||= {};
    my $host = $config->{host} or return undef;
    my $port = int($config->{port}) || 8443;
    return bless {
        host       => $host,
        port       => $port,
        key        => $config->{key}    || '',
        secret     => $config->{secret} || '',
        verify_ssl => $config->{verify_ssl} ? 1 : 0,
        base       => _api_base_url($host, $port),
        auth       => 'Basic ' . encode_base64(($config->{key} || '') . ':' . ($config->{secret} || ''), ''),
    }, $class;
}

sub configured {
    my ($self) = @_;
    return $self->{host} && $self->{key} && $self->{secret};
}

sub _ua {
    my ($self) = @_;
    return $self->{ua} if $self->{ua};
    my $ua = LWP::UserAgent->new(timeout => 20);
    $ua->requests_redirectable([ 'GET', 'HEAD', 'POST', 'PUT', 'DELETE' ]);
    $ua->max_redirect(5);
    $ua->ssl_opts(
        verify_hostname => $self->{verify_ssl} ? 1 : 0,
        SSL_verify_mode  => $self->{verify_ssl} ? 1 : 0,
    );
    $self->{ua} = $ua;
    return $ua;
}

# Pick API base URL: 401/200 = reachable API; 301 on :443 usually means use 8443.
sub _ensure_api_base {
    my ($self) = @_;
    return $self->{base} if $self->{base_verified};

    my @ports = ($self->{port});
    push @ports, 8443 unless grep { $_ == 8443 } @ports;
    push @ports, 443   unless grep { $_ == 443 } @ports;

    my %seen;
    @ports = grep { !$seen{$_}++ } @ports;

    for my $port (@ports) {
        my $base = _api_base_url($self->{host}, $port);
        my $url  = "$base/core/firmware/status";
        my $req  = HTTP::Request->new(GET => $url);
        $req->header(Authorization => $self->{auth});
        my $res = $self->_ua->request($req);
        my $code = $res->code || 0;
        if ($code == 200 || $code == 401 || $code == 403) {
            $self->{base}          = $base;
            $self->{port}          = $port;
            $self->{base_verified} = 1;
            return $base;
        }
    }

    $self->{base_verified} = 1;
    return $self->{base};
}

sub api_request {
    my ($self, $method, $path, $body) = @_;
    $self->_ensure_api_base;
    $path =~ s{^/}{};
    my $url = "$self->{base}/$path";
    my $req = HTTP::Request->new(uc($method) => $url);
    $req->header(Authorization => $self->{auth});
    # OPNsense rejects GET with Content-Type: application/json ("Invalid JSON syntax").
    if (defined $body) {
        $req->header('Content-Type' => 'application/json');
        $req->content(encode_json($body));
    }
    my $res = $self->_ua->request($req);
    my $code = $res->code || 0;
    my $ok   = $res->is_success;
    if ($code == 401) {
        $ok = 0;
    }
    my $line = $res->status_line;
    if ($code == 301 || $code == 302) {
        $line .= ' — wrong HTTPS port? Try 8443 in Comserv OPNsense settings (not 443).';
    } elsif ($code == 401) {
        $line = '401 Unauthorized — check API Key and API Secret (not web login password).';
    }
    return {
        ok     => $ok,
        status => $code,
        line   => $line,
        raw    => $res->decoded_content,
        json   => eval { decode_json($res->decoded_content) },
    };
}

sub api_post { my ($s, $p, $b) = @_; return $s->api_request('POST', $p, $b // {}) }
sub api_get  { my ($s, $p) = @_;     return $s->api_request('GET',  $p) }

sub _rows {
    my ($data) = @_;
    return [] unless ref $data eq 'HASH';
    return $data->{rows} if ref $data->{rows} eq 'ARRAY';
    return [];
}

sub fetch_status {
    my ($self) = @_;
    my %status;
    my @reads = (
        [ firmware   => 'core/firmware/info',                       'GET' ],
        [ interfaces => 'interfaces/overview/interfacesInfo',      'GET' ],
        [ dhcp       => 'dhcpv4/leases/searchLease',               'POST', { current => 1, rowCount => 500 } ],
        [ firewall   => 'firewall/filter/searchRule',              'POST', { current => 1, rowCount => 200 } ],
        [ nat        => 'firewall/source_nat/searchRule',         'POST', { current => 1, rowCount => 200 } ],
        [ unbound    => 'unbound/service/status',                   'GET' ],
        [ dns_hosts  => 'unbound/settings/searchHostOverride',      'POST', { current => 1, rowCount => 200 } ],
    );
    for my $r (@reads) {
        my ($key, $path, $method, $body) = @$r;
        my $res = $method eq 'GET'
            ? $self->api_get($path)
            : $self->api_post($path, $body);
        if ($res->{ok} && ref $res->{json} eq 'HASH') {
            my $data = $res->{json};
            if ($key eq 'interfaces') {
                my @rows;
                for my $iface (@{ _rows($data) }) {
                    my $cfg = ref $iface->{config} eq 'HASH' ? $iface->{config} : {};
                    my $ipv4 = $cfg->{ipaddr} // '';
                    if (!$ipv4 && ref $iface->{addresses} eq 'ARRAY' && @{ $iface->{addresses} }) {
                        ($ipv4) = $iface->{addresses}[0]{ipaddr} =~ m{^([^/]+)};
                    }
                    push @rows, {
                        identifier => $iface->{device} // $cfg->{identifier} // '',
                        descr      => $cfg->{descr} // $iface->{device} // '',
                        ipaddr     => $ipv4,
                        ipv6       => $cfg->{ipaddrv6} // '',
                        status     => $iface->{status} // 'unknown',
                    };
                }
                $status{interfaces} = { rows => \@rows, total => scalar @rows };
            } elsif ($key eq 'firmware' && ref $data eq 'HASH' && $data->{product_version}) {
                $status{firmware} = {
                    product_version => $data->{product_version},
                    product_id      => $data->{product_id},
                    rows            => [],
                    raw             => $data,
                };
            } elsif ($key eq 'unbound' && ref $data eq 'HASH' && defined $data->{status}) {
                $status{unbound} = {
                    status => $data->{status},
                    rows   => [],
                    raw    => $data,
                };
            } else {
                $status{$key} = {
                    rows  => _rows($data),
                    total => $data->{total} // scalar(_rows($data)),
                    raw   => $data,
                };
            }
        } else {
            $status{$key} = { error => $res->{line} || 'request failed', rows => [] };
        }
    }
    return \%status;
}

sub search_nat_rules {
    my ($self) = @_;
    my $res = $self->api_post('firewall/source_nat/searchRule', { current => 1, rowCount => 500 });
    return { error => $res->{line} } unless $res->{ok};
    return { rows => _rows($res->{json}), total => $res->{json}{total} };
}

sub add_port_forward {
    my ($self, $opts) = @_;
    $opts ||= {};
    my $rule = {
        enabled          => '1',
        interface        => $opts->{interface}        || 'wan',
        ipprotocol       => 'inet',
        protocol         => $opts->{protocol}          || 'TCP',
        source           => 'any',
        sourceport       => '',
        destination      => $opts->{destination}      || 'wan:ip',
        destinationport  => $opts->{external_port}    || $opts->{local_port} || '3001',
        target           => $opts->{target_ip}        || '192.168.1.199',
        local_port       => $opts->{local_port}        || '3001',
        descr            => $opts->{description}      || 'Comserv dev (API)',
        natreflection    => 'disable',
    };
    my $res = $self->api_post('firewall/source_nat/addRule', { rule => $rule });
    return { success => 0, error => $res->{line} } unless $res->{ok};
    return { success => 1, uuid => $res->{json}{uuid}, result => $res->{json} };
}

sub apply_nat {
    my ($self) = @_;
    my $res = $self->api_post('firewall/source_nat/apply', {});
    return $res->{ok} ? { success => 1 } : { success => 0, error => $res->{line} };
}

sub apply_filter {
    my ($self) = @_;
    my $res = $self->api_post('firewall/filter/apply', {});
    return $res->{ok} ? { success => 1 } : { success => 0, error => $res->{line} };
}

sub add_host_override {
    my ($self, $opts) = @_;
    $opts ||= {};
    my $host = {
        enabled  => '1',
        hostname => $opts->{hostname} || 'workstation',
        domain   => $opts->{domain}   || 'zero.computersystemconsulting.ca',
        server   => $opts->{ip}        || '172.30.131.126',
        descr    => $opts->{description} || 'Comserv dev workstation (API)',
    };
    my $res = $self->api_post('unbound/settings/addHostOverride', { host => $host });
    return { success => 0, error => $res->{line} } unless $res->{ok};
    return { success => 1, uuid => $res->{json}{uuid}, result => $res->{json} };
}

sub reconfigure_unbound {
    my ($self) = @_;
    my $res = $self->api_post('unbound/service/reconfigure', {});
    return $res->{ok} ? { success => 1 } : { success => 0, error => $res->{line} };
}

sub set_nat_rule_enabled {
    my ($self, $uuid, $enabled) = @_;
    return { success => 0, error => 'uuid required' } unless $uuid;
    # OPNsense 26.x: enable/disable via del/add or edit in UI; setRule not exposed on source_nat.
    my $res = $self->api_post('firewall/source_nat/setRule', {
        uuid => $uuid,
        rule => { enabled => $enabled ? '1' : '0' },
    });
    return $res->{ok} ? { success => 1 } : { success => 0, error => $res->{line} };
}

sub _haproxy_search {
    my ($self, $endpoint) = @_;
    my $res = $self->api_post("haproxy/settings/$endpoint", { current => 1, rowCount => 500 });
    return { error => $res->{line} } unless $res->{ok};
    return { rows => _rows($res->{json}), total => $res->{json}{total} };
}

sub _haproxy_find_row {
    my ($rows, $name) = @_;
    return unless defined $name && $name ne '';
    for my $r (@{ $rows || [] }) {
        return $r if ref $r eq 'HASH' && ($r->{name} // '') eq $name;
    }
    return;
}

sub _haproxy_post_named {
    my ($self, $action, $entity_key, $payload, $name) = @_;
    my $search_map = {
        add_server    => 'search_servers',
        set_server    => 'search_servers',
        add_backend   => 'search_backends',
        set_backend   => 'search_backends',
        add_acl       => 'searchAcls',
        set_acl       => 'searchAcls',
        add_action    => 'searchActions',
        set_action    => 'searchActions',
        add_frontend  => 'search_frontends',
        set_frontend  => 'search_frontends',
    };
    my $search_ep = $search_map->{$action};
    if ($action =~ /^set_/ && $search_ep) {
        my $found = $self->_haproxy_search($search_ep);
        my $row   = _haproxy_find_row($found->{rows}, $name);
        if ($row && $row->{uuid}) {
            my $res = $self->api_post("haproxy/settings/$action/$row->{uuid}", { $entity_key => $payload });
            return $res->{ok}
                ? { success => 1, uuid => $row->{uuid}, updated => 1, result => $res->{json} }
                : { success => 0, error => $res->{line} };
        }
    }
    my $res = $self->api_post("haproxy/settings/$action", { $entity_key => $payload });
    return $res->{ok}
        ? { success => 1, uuid => $res->{json}{uuid}, created => 1, result => $res->{json} }
        : { success => 0, error => $res->{line} };
}

sub reconfigure_haproxy {
    my ($self) = @_;
    my $res = $self->api_post('haproxy/service/reconfigure', {});
    return $res->{ok} ? { success => 1 } : { success => 0, error => $res->{line} };
}

sub fetch_haproxy_status {
    my ($self) = @_;
    my %out;
    my $svc = $self->api_get('haproxy/service/status');
    $out{service} = $svc->{ok} ? ($svc->{json} || {}) : { error => $svc->{line} };
    for my $key (qw(servers backends frontends acls actions)) {
        my $ep = {
            servers    => 'search_servers',
            backends   => 'search_backends',
            frontends  => 'search_frontends',
            acls       => 'searchAcls',
            actions    => 'searchActions',
        }->{$key};
        my $data = $self->_haproxy_search($ep);
        $out{$key} = $data->{error} ? { error => $data->{error}, rows => [] } : $data;
    }
    return \%out;
}

sub _ensure_firewall_alias {
    my ($self, $name, $type, $content, $descr) = @_;
    my $res = $self->api_post('firewall/alias/searchItem', { current => 1, rowCount => 500 });
    return { success => 0, error => $res->{line} } unless $res->{ok};
    my ($existing) = grep { ($_->{name} // '') eq $name } @{ _rows($res->{json}) };
    if ($existing && ($existing->{content} // '') eq $content) {
        return { success => 1, uuid => $existing->{uuid}, unchanged => 1 };
    }
    if ($existing) {
        my $set = $self->api_post("firewall/alias/setItem/$existing->{uuid}", {
            alias => {
                enabled     => '1',
                name        => $name,
                type        => $type,
                content     => $content,
                description => $descr,
            },
        });
        return $set->{ok}
            ? { success => 1, uuid => $existing->{uuid}, updated => 1 }
            : { success => 0, error => $set->{line} };
    }
    my $add = $self->api_post('firewall/alias/addItem', {
        alias => {
            enabled     => '1',
            name        => $name,
            type        => $type,
            content     => $content,
            description => $descr,
        },
    });
    return $add->{ok}
        ? { success => 1, uuid => $add->{json}{uuid}, created => 1 }
        : { success => 0, error => $add->{line} };
}

sub _ensure_firewall_pass_rule {
    my ($self, $descr, $rule) = @_;
    my $res = $self->api_post('firewall/filter/searchRule', { current => 1, rowCount => 500 });
    return { success => 0, error => $res->{line} } unless $res->{ok};
    my ($existing) = grep { ($_->{descr} // '') eq $descr } @{ _rows($res->{json}) };
    if ($existing && ($existing->{enabled} // '') eq '1') {
        return { success => 1, uuid => $existing->{uuid}, unchanged => 1 };
    }
    if ($existing) {
        my $set = $self->api_post("firewall/filter/setRule/$existing->{uuid}", { rule => { %$rule, enabled => '1' } });
        return $set->{ok}
            ? { success => 1, uuid => $existing->{uuid}, updated => 1 }
            : { success => 0, error => $set->{line} };
    }
    my $add = $self->api_post('firewall/filter/addRule', { rule => { %$rule, enabled => '1', descr => $descr } });
    return $add->{ok}
        ? { success => 1, uuid => $add->{json}{uuid}, created => 1 }
        : { success => 0, error => $add->{line} };
}

sub set_host_override_ip {
    my ($self, $opts) = @_;
    $opts ||= {};
    my $host   = $opts->{hostname} || '';
    my $domain = $opts->{domain}   || '';
    my $ip     = $opts->{ip}       || '';
    return { success => 0, error => 'hostname, domain, and ip required' }
        unless length $host && $domain && $ip;

    my $status = $self->fetch_status;
    my @rows = ref $status->{dns_hosts} eq 'HASH'
        ? @{ $status->{dns_hosts}{rows} || [] } : ();
    my ($existing) = grep {
        ($_->{hostname} // '') eq $host && ($_->{domain} // '') eq $domain
    } @rows;

    if ($existing && ($existing->{server} // '') eq $ip) {
        return { success => 1, unchanged => 1, uuid => $existing->{uuid} };
    }
    if ($existing && $existing->{uuid}) {
        my $res = $self->api_post("unbound/settings/setHostOverride/$existing->{uuid}", {
            host => {
                enabled  => '1',
                hostname => $host,
                domain   => $domain,
                server   => $ip,
                descr    => $opts->{description} || "Comserv gateway: $host.$domain",
            },
        });
        if ($res->{ok}) {
            $self->reconfigure_unbound;
            return { success => 1, updated => 1, uuid => $existing->{uuid} };
        }
        return { success => 0, error => $res->{line} };
    }
    return $self->add_host_override($opts);
}

# dev.csc: Unbound → gateway :80, HAProxy → workstation :3001 (no port in browser URL).
sub ensure_dev_csc_gateway {
    my ($self, $opts) = @_;
    $opts ||= {};
    my $gateway_ip   = $opts->{gateway_ip}   || '192.168.1.1';
    my $backend_ip   = $opts->{backend_ip}   || '192.168.1.199';
    my $backend_port = $opts->{backend_port} || 3001;
    my $fqdn         = $opts->{fqdn}         || 'dev.computersystemconsulting.ca';
    my $domain       = $opts->{domain}       || 'computersystemconsulting.ca';
    my @steps;

    my $names = {
        server    => 'WorkstationDev3001',
        backend   => 'Comserv_Dev_Backend',
        acl       => 'DevCSC_host',
        action    => 'DevCSC_use_backend',
        frontend  => 'Comserv_Dev_HTTP',
        port_alias => 'ComservDevPort3001',
    };

    my $alias = $self->_ensure_firewall_alias(
        $names->{port_alias}, 'port', "$backend_port",
        'Comserv dev Starman (HAProxy backend)',
    );
    push @steps, $alias->{unchanged}
        ? 'Firewall alias ComservDevPort3001 already present.'
        : ($alias->{success} ? 'Firewall alias ComservDevPort3001 saved.' : "Firewall alias failed: $alias->{error}");
    return { success => 0, error => $alias->{error}, steps => \@steps } unless $alias->{success};

    for my $spec (
        {
            descr => 'Comserv HAProxy → workstation :3001',
            rule  => {
                action           => 'pass',
                quick            => '1',
                interface        => 'lan',
                direction        => 'out',
                ipprotocol       => 'inet',
                protocol         => 'TCP',
                source_net       => '(self)',
                destination_net  => 'workstation',
                destination_port => $names->{port_alias},
            },
        },
        {
            descr => 'LAN → workstation Comserv dev :3001',
            rule  => {
                action           => 'pass',
                quick            => '1',
                interface        => 'lan',
                direction        => 'in',
                ipprotocol       => 'inet',
                protocol         => 'TCP',
                source_net       => 'any',
                destination_net  => 'workstation',
                destination_port => $names->{port_alias},
            },
        },
    ) {
        my $fw = $self->_ensure_firewall_pass_rule($spec->{descr}, $spec->{rule});
        push @steps, $fw->{unchanged}
            ? "Firewall rule \"$spec->{descr}\" already present."
            : ($fw->{success} ? "Firewall rule \"$spec->{descr}\" saved." : "Firewall rule failed: $fw->{error}");
        return { success => 0, error => $fw->{error}, steps => \@steps } unless $fw->{success};
    }
    my $apply_fw = $self->apply_filter;
    push @steps, $apply_fw->{success} ? 'Firewall rules applied.' : "Firewall apply: $apply_fw->{error}";

    my $srv = $self->_haproxy_post_named(set_server => 'server', {
        enabled     => '1',
        name        => $names->{server},
        description => "Comserv dev Starman :$backend_port",
        address     => $backend_ip,
        port        => "$backend_port",
        mode        => 'active',
        type        => 'static',
    }, $names->{server});
    push @steps, $srv->{success}
        ? "HAProxy server $names->{server} → $backend_ip:$backend_port."
        : "HAProxy server failed: $srv->{error}";
    return { success => 0, error => $srv->{error}, steps => \@steps } unless $srv->{success};
    my $server_uuid = $srv->{uuid};

    my $be = $self->_haproxy_post_named(set_backend => 'backend', {
        enabled            => '1',
        name               => $names->{backend},
        description        => "$fqdn → workstation :$backend_port",
        mode               => 'http',
        algorithm          => 'roundrobin',
        linkedServers      => $server_uuid,
        healthCheckEnabled => '0',
        forwardFor         => '1',
        persistence        => '',
    }, $names->{backend});
    push @steps, $be->{success}
        ? "HAProxy backend $names->{backend} linked to $names->{server}."
        : "HAProxy backend failed: $be->{error}";
    return { success => 0, error => $be->{error}, steps => \@steps } unless $be->{success};
    my $backend_uuid = $be->{uuid};

    my $acl = $self->_haproxy_post_named(set_acl => 'acl', {
        name        => $names->{acl},
        description => $fqdn,
        expression  => 'hdr',
        hdr         => $fqdn,
        caseSensitive => '0',
    }, $names->{acl});
    push @steps, $acl->{success}
        ? "HAProxy ACL $names->{acl} for Host $fqdn."
        : "HAProxy ACL failed: $acl->{error}";
    return { success => 0, error => $acl->{error}, steps => \@steps } unless $acl->{success};
    my $acl_uuid = $acl->{uuid};

    my $act = $self->_haproxy_post_named(set_action => 'action', {
        enabled     => '1',
        name        => $names->{action},
        description => "Route $fqdn to workstation :$backend_port",
        testType    => 'if',
        operator    => 'and',
        type        => 'use_backend',
        linkedAcls  => $acl_uuid,
        use_backend => $backend_uuid,
    }, $names->{action});
    push @steps, $act->{success}
        ? "HAProxy action $names->{action} (use_backend)."
        : "HAProxy action failed: $act->{error}";
    return { success => 0, error => $act->{error}, steps => \@steps } unless $act->{success};
    my $action_uuid = $act->{uuid};

    my $fe = $self->_haproxy_post_named(set_frontend => 'frontend', {
        enabled       => '1',
        name          => $names->{frontend},
        description   => "LAN HTTP for $fqdn (no :$backend_port in URL)",
        bind          => "$gateway_ip:80,0.0.0.0:80",
        mode          => 'http',
        defaultBackend => '',
        forwardFor    => '1',
        linkedActions => $action_uuid,
    }, $names->{frontend});
    push @steps, $fe->{success}
        ? "HAProxy frontend $names->{frontend} on $gateway_ip:80."
        : "HAProxy frontend failed: $fe->{error}";
    return { success => 0, error => $fe->{error}, steps => \@steps } unless $fe->{success};

    my $hap = $self->reconfigure_haproxy;
    push @steps, $hap->{success} ? 'HAProxy reconfigured.' : "HAProxy reconfigure: $hap->{error}";
    return { success => 0, error => $hap->{error}, steps => \@steps } unless $hap->{success};

    my $dns = $self->set_host_override_ip({
        hostname    => 'dev',
        domain      => $domain,
        ip          => $gateway_ip,
        description => 'Comserv dev via gateway HAProxy → workstation :3001',
    });
    push @steps, $dns->{unchanged}
        ? "Unbound dev.$domain already → $gateway_ip."
        : ($dns->{success} ? "Unbound dev.$domain → $gateway_ip (gateway HAProxy)." : "Unbound failed: $dns->{error}");
    return { success => 0, error => $dns->{error}, steps => \@steps } unless $dns->{success};

    return {
        success      => 1,
        steps        => \@steps,
        gateway_url  => "http://$fqdn/",
        backend_url  => "http://$backend_ip:$backend_port/",
        note         => 'Workstation must allow TCP :3001 from the gateway (192.168.1.1). '
                      . 'On the workstation run: sudo script/open_dev3001_for_gateway.sh',
    };
}

1;
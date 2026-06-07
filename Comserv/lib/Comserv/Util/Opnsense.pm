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

1;
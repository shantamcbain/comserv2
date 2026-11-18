package Comserv::Util::ZeroTier;

use strict;
use warnings;
use JSON::MaybeXS qw(encode_json decode_json);
use Digest::SHA qw(sha256_hex);

# ZeroTier Central (legacy v1). Auth header is "Authorization: token <secret>".
# https://docs.zerotier.com/api/central/legacy/
our $DEFAULT_NETWORK_ID = 'af78bf943680bfeb';
our $API_BASE           = 'https://api.zerotier.com/api/v1';
our $PENDING_TTL        = 900;

sub redact {
    my ($text, $secret) = @_;
    $text = '' unless defined $text;
    return $text unless defined $secret && length $secret;
    $text =~ s/\Q$secret\E/[redacted]/g;
    return $text;
}

sub valid_ipv4 {
    my ($ip) = @_;
    return 0 unless defined $ip && $ip =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
    for my $n ($1, $2, $3, $4) {
        return 0 if $n > 255;
    }
    return 1;
}

sub valid_cidr {
    my ($cidr) = @_;
    return 0 unless defined $cidr && $cidr =~ m{^(.+)/(\d+)$};
    return 0 if $2 > 32;
    return valid_ipv4($1);
}

sub valid_network_id {
    my ($id) = @_;
    return defined $id && $id =~ /^[0-9a-fA-F]{16}$/;
}

sub _via {
    my ($v) = @_;
    return '' unless defined $v && $v ne '';
    return $v;
}

sub parse_routes {
    my ($text) = @_;
    $text = '' unless defined $text;
    my @routes;
    my $n = 0;
    for my $line (split /\r?\n/, $text) {
        $n++;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;
        my ($target, $via) = ($line, '');
        if ($line =~ /^(\S+)\s+via\s+(\S+)\s*$/i) {
            ($target, $via) = ($1, $2);
        } elsif ($line =~ /^(\S+)\s*$/) {
            $target = $1;
        } else {
            return { ok => 0, error => "Route line $n is not 'target' or 'target via address'." };
        }
        return { ok => 0, error => "Route line $n target is not an IPv4 CIDR." }
            unless valid_cidr($target);
        return { ok => 0, error => "Route line $n via is not an IPv4 address." }
            if $via ne '' && !valid_ipv4($via);
        push @routes, { target => $target, via => $via };
    }
    return { ok => 0, error => 'At least one route is required. An empty list would wipe the network routes.' }
        unless @routes;
    return { ok => 1, routes => \@routes };
}

sub parse_dns {
    my ($domain, $servers_text) = @_;
    $domain = '' unless defined $domain;
    $domain =~ s/^\s+|\s+$//g;
    return { ok => 0, error => 'DNS domain has unexpected characters.' }
        if $domain ne '' && $domain !~ /^[A-Za-z0-9._-]+$/;
    $servers_text = '' unless defined $servers_text;
    my @servers;
    my $n = 0;
    for my $line (split /\r?\n/, $servers_text) {
        $n++;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;
        return { ok => 0, error => "DNS server line $n is not an IPv4 address." }
            unless valid_ipv4($line);
        push @servers, $line;
    }
    return { ok => 1, dns => { domain => $domain, servers => \@servers } };
}

sub format_routes {
    my ($routes) = @_;
    my @lines;
    for my $r (@{ $routes || [] }) {
        my $via = _via($r->{via});
        push @lines, $via ne '' ? "$r->{target} via $via" : $r->{target};
    }
    return join("\n", @lines);
}

sub format_dns_servers {
    my ($dns) = @_;
    return '' unless ref $dns eq 'HASH' && ref $dns->{servers} eq 'ARRAY';
    return join("\n", @{ $dns->{servers} });
}

sub assigned_addresses {
    my ($members) = @_;
    my %seen;
    my @ips;
    for my $m (@{ $members || [] }) {
        next unless ref $m eq 'HASH';
        my $cfg = ref $m->{config} eq 'HASH' ? $m->{config} : {};
        my $list = ref $cfg->{ipAssignments} eq 'ARRAY' ? $cfg->{ipAssignments}
                 : ref $m->{ipAssignments} eq 'ARRAY'   ? $m->{ipAssignments}
                 : [];
        for my $ip (@$list) {
            next unless defined $ip && $ip ne '' && !$seen{$ip}++;
            push @ips, $ip;
        }
    }
    return \@ips;
}

# A route is orphaned when its via is set and no device has that address.
# An empty via is a route owned by the network itself, not an orphan.
sub flag_orphan_routes {
    my ($routes, $members) = @_;
    my %have = map { $_ => 1 } @{ assigned_addresses($members) };
    my @out;
    for my $r (@{ $routes || [] }) {
        next unless ref $r eq 'HASH';
        my $via = _via($r->{via});
        push @out, {
            target => $r->{target} // '',
            via    => $via,
            orphan => ($via ne '' && !$have{$via}) ? 1 : 0,
        };
    }
    return \@out;
}

sub normalize_settings {
    my ($routes, $dns) = @_;
    my @routes = map {
        { target => $_->{target} // '', via => _via($_->{via}) }
    } @{ $routes || [] };
    my $domain = ref $dns eq 'HASH' ? ($dns->{domain} // '') : '';
    my @servers = ref $dns eq 'HASH' && ref $dns->{servers} eq 'ARRAY'
        ? @{ $dns->{servers} } : ();
    return { routes => \@routes, dns => { domain => $domain, servers => \@servers } };
}

sub canonical_settings {
    my ($routes, $dns) = @_;
    my $n = normalize_settings($routes, $dns);
    return encode_json($n);
}

sub settings_equal {
    my ($a_routes, $a_dns, $b_routes, $b_dns) = @_;
    return canonical_settings($a_routes, $a_dns) eq canonical_settings($b_routes, $b_dns);
}

sub update_body {
    my ($routes, $dns) = @_;
    my $n = normalize_settings($routes, $dns);
    my @routes = map {
        my $row = { target => $_->{target} };
        $row->{via} = $_->{via} ne '' ? $_->{via} : undef;
        $row;
    } @{ $n->{routes} };
    return {
        config => {
            routes => \@routes,
            dns    => $n->{dns},
        },
    };
}

sub pending_sha {
    my ($op, $network_id, $proposed) = @_;
    $proposed = {} unless ref $proposed eq 'HASH';
    my $payload = canonical_settings($proposed->{routes}, $proposed->{dns});
    return sha256_hex(join("\n", $op // '', $network_id // '', $payload));
}

sub pending_ok {
    my ($pending, $sha, $now) = @_;
    return 0 unless ref $pending eq 'HASH';
    return 0 unless defined $sha && $sha ne '' && $sha eq ($pending->{sha} // '');
    return 0 unless defined $pending->{at} && $pending->{at} =~ /^\d+$/;
    return 0 if ($now // 0) - $pending->{at} > $PENDING_TTL;
    return 0 unless ref $pending->{proposed} eq 'HASH';
    return 0 unless ($pending->{op} // '') =~ /^(update|undo)$/;
    return 1;
}

sub undo_record {
    my ($routes, $dns, $by) = @_;
    my $n = normalize_settings($routes, $dns);
    return {
        routes   => $n->{routes},
        dns      => $n->{dns},
        saved_by => $by // '',
    };
}

sub _epoch_text {
    my ($ms) = @_;
    return '' unless defined $ms && $ms =~ /^\d+$/ && $ms > 0;
    my $sec = $ms > 1_000_000_000_000 ? int($ms / 1000) : int($ms);
    return scalar localtime($sec);
}

sub view_from_api {
    my ($network, $members) = @_;
    my $cfg = ref $network eq 'HASH' && ref $network->{config} eq 'HASH' ? $network->{config} : {};
    my $routes = flag_orphan_routes($cfg->{routes} || [], $members);
    my $dns = ref $cfg->{dns} eq 'HASH' ? $cfg->{dns} : { domain => '', servers => [] };
    my @pools;
    for my $p (@{ $cfg->{ipAssignmentPools} || [] }) {
        next unless ref $p eq 'HASH';
        push @pools, {
            start => $p->{ipRangeStart} // '',
            end   => $p->{ipRangeEnd} // '',
        };
    }
    my @devices;
    for my $m (@{ $members || [] }) {
        next unless ref $m eq 'HASH';
        my $mcfg = ref $m->{config} eq 'HASH' ? $m->{config} : {};
        my $ips = ref $mcfg->{ipAssignments} eq 'ARRAY' ? $mcfg->{ipAssignments} : [];
        push @devices, {
            name       => $m->{name} // '',
            node_id    => $m->{nodeId} // '',
            authorized => $mcfg->{authorized} ? 1 : 0,
            ips        => join(', ', @$ips),
            last_seen  => _epoch_text($m->{lastSeen}),
        };
    }
    my $private = $cfg->{private};
    return {
        id      => $network->{id} // '',
        name    => $cfg->{name} // '',
        private => $private ? 1 : 0,
        routes  => $routes,
        dns     => {
            domain  => $dns->{domain} // '',
            servers => $dns->{servers} || [],
        },
        pools   => \@pools,
        devices => \@devices,
        orphan_count => scalar(grep { $_->{orphan} } @$routes),
    };
}

sub new {
    my ($class, $args) = @_;
    $args ||= {};
    return bless {
        token      => $args->{token} // '',
        network_id => $args->{network_id} || $DEFAULT_NETWORK_ID,
        transport  => $args->{transport},
        api_base   => $args->{api_base} || $API_BASE,
    }, $class;
}

sub _request {
    my ($self, $method, $path, $body) = @_;
    my $url = $self->{api_base} . $path;
    my $json = defined $body ? encode_json($body) : undef;
    my $res;
    if ($self->{transport}) {
        $res = eval { $self->{transport}->($method, $url, $json) };
        if ($@) {
            return { ok => 0, status => 0, error => redact("$@", $self->{token}) };
        }
    } else {
        # Live call. Tests pass a transport and never reach this branch.
        require LWP::UserAgent;
        require HTTP::Request;
        my $ua = LWP::UserAgent->new(timeout => 20);
        my $req = HTTP::Request->new(uc($method) => $url);
        $req->header(Authorization => 'token ' . $self->{token});
        if (defined $json) {
            $req->header('Content-Type' => 'application/json');
            $req->content($json);
        }
        my $http = eval { $ua->request($req) };
        if ($@) {
            return { ok => 0, status => 0, error => redact("$@", $self->{token}) };
        }
        $res = { status => $http->code || 0, body => $http->decoded_content // '' };
    }
    $res = {} unless ref $res eq 'HASH';
    my $status = $res->{status} || 0;
    my $raw = redact($res->{body} // '', $self->{token});
    my $decoded;
    $decoded = eval { decode_json($res->{body}) } if defined $res->{body} && $res->{body} =~ /\S/;
    my $ok = $status >= 200 && $status < 300;
    my $error = '';
    unless ($ok) {
        $error = "ZeroTier API $method $path failed: HTTP $status";
        $error .= ' ' . substr($raw, 0, 240) if $raw =~ /\S/;
        $error = redact($error, $self->{token});
    }
    return { ok => $ok, status => $status, error => $error, json => $decoded };
}

sub fetch_network {
    my ($self) = @_;
    return { ok => 0, error => 'ZeroTier network id is not a 16-character id.' }
        unless valid_network_id($self->{network_id});
    my $res = $self->_request('GET', '/network/' . $self->{network_id});
    return $res unless $res->{ok};
    return { ok => 0, error => 'ZeroTier network response was not an object.' }
        unless ref $res->{json} eq 'HASH';
    return $res;
}

sub fetch_members {
    my ($self) = @_;
    return { ok => 0, error => 'ZeroTier network id is not a 16-character id.' }
        unless valid_network_id($self->{network_id});
    my $res = $self->_request('GET', '/network/' . $self->{network_id} . '/member');
    return $res unless $res->{ok};
    return { ok => 0, error => 'ZeroTier member response was not a list.' }
        unless ref $res->{json} eq 'ARRAY';
    return $res;
}

sub update_settings {
    my ($self, $routes, $dns) = @_;
    return { ok => 0, error => 'ZeroTier network id is not a 16-character id.' }
        unless valid_network_id($self->{network_id});
    my $body = update_body($routes, $dns);
    return $self->_request('POST', '/network/' . $self->{network_id}, $body);
}

1;

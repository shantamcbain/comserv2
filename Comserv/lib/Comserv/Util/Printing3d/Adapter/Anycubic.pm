package Comserv::Util::Printing3d::Adapter::Anycubic;

use strict;
use warnings;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use HTTP::Tiny;
use IO::Socket::INET;
use Digest::MD5 qw(md5_hex);
use MIME::Base64 qw(decode_base64);
use JSON qw(encode_json decode_json);
use Time::HiRes qw(time);
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::Printing3d::Adapter::Anycubic

=head1 DESCRIPTION

Stock Anycubic Kobra 3 family LAN Mode (not cloud, not Moonraker).
GET http://HOST:18910/info then signed POST /ctrl then MQTTS :9883.
Do not log token, password, cert, or upload secrets.
Do not send a print job from here.

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub sanitize_host {
    my ($self, $host) = @_;
    $host = '' unless defined $host;
    $host =~ s/^\s+|\s+$//g;
    return unless $host =~ /\A(?:\d{1,3}(?:\.\d{1,3}){3}|[A-Za-z0-9][A-Za-z0-9.\-]{0,253})\z/;
    return if $host =~ m{[:@/\\]};
    return $host;
}

sub ping {
    my ($self, $c, $host, $port) = @_;
    my $st = $self->fetch_info($c, $host, $port);
    return {
        ok      => $st->{ok} ? 1 : 0,
        status  => $st->{http_status},
        url     => $st->{url},
        snippet => $st->{model_name} || $st->{error},
        error   => $st->{ok} ? undef : $st->{error},
    };
}

sub fetch_info {
    my ($self, $c, $host, $port) = @_;
    my $safe = $self->sanitize_host($host);
    return { ok => 0, error => 'Invalid host' } unless $safe;
    $port = 18910 unless $port && $port =~ /\A\d{2,5}\z/ && $port > 0 && $port < 65536;
    my $url = "http://$safe:$port/info";
    my $res;
    my $fail;
    try {
        my $ua = HTTP::Tiny->new(timeout => 4, max_redirect => 0);
        $res = $ua->get($url);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'fetch_info',
            "exception host=$safe: $_");
        $fail = { ok => 0, error => "GET /info failed: $_", url => $url, host => $safe };
    };
    return $fail if $fail;
    unless ($res && $res->{success}) {
        my $status = $res ? ($res->{status} || 0) : 0;
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'fetch_info',
            "host=$safe http=$status");
        return {
            ok          => 0,
            error       => 'HTTP ' . $status,
            url         => $url,
            host        => $safe,
            http_status => $status,
        };
    }
    my $raw = $res->{content} || '';
    my $j;
    try { $j = decode_json($raw) } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'fetch_info',
            "JSON parse failed host=$safe: $_");
    };
    unless ($j && ref($j) eq 'HASH') {
        return { ok => 0, error => 'GET /info was not JSON', url => $url, host => $safe };
    }
    my $cam = $j->{rtspUrl} || '';
    $cam = '' unless $cam =~ m{\Ahttps?://[\w.:/-]+\z};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_info',
        "host=$safe model=" . ($j->{modelName} || '') . " ctrl=" . ($j->{ctrlType} || ''));
    return {
        ok           => 1,
        host         => $safe,
        url          => $url,
        http_status  => $res->{status},
        model_name   => $j->{modelName} || '',
        model_id     => $j->{modelId} || '',
        device_name  => $j->{deviceName} || '',
        device_type  => $j->{deviceType} || '',
        serial       => $j->{cn} || '',
        ctrl_type    => $j->{ctrlType} || '',
        camera_url   => $cam,
        has_upload   => ($j->{fileUploadurl} ? 1 : 0),
        has_token    => ($j->{token} ? 1 : 0),
        ctrl_info_url => $j->{ctrlInfoUrl} || '',
        _token       => $j->{token} || '',
        _info        => $j,
    };
}

# Signed POST /ctrl. Caller must not stash password/cert.
sub handshake {
    my ($self, $c, $host, $port) = @_;
    my $info = $self->fetch_info($c, $host, $port);
    return $info unless $info->{ok};
    if (($info->{ctrl_type} || '') eq 'cloud') {
        return { ok => 0, error => 'Printer is in cloud mode — enable LAN Mode', %$info };
    }
    my $token = $info->{_token} || '';
    my $ctrl_url = $info->{ctrl_info_url} || '';
    unless (length($token) >= 32 && $ctrl_url =~ m{\Ahttp://}) {
        return { ok => 0, error => 'Printer did not offer a signed LAN handshake', %$info };
    }
    my $ts = int(time() * 1000);
    my $nonce = _rand_alnum(6);
    my $did = _rand_did(32);
    my $first = md5_hex(substr($token, 0, 16));
    my $sign = md5_hex($first . $ts . $nonce);
    my $url = $ctrl_url . "?ts=$ts&nonce=$nonce&sign=$sign&did=$did";
    my $res;
    my $fail;
    try {
        my $ua = HTTP::Tiny->new(timeout => 6, max_redirect => 0);
        $res = $ua->post($url);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'handshake',
            "POST /ctrl exception host=$info->{host}: $_");
        $fail = { ok => 0, error => "POST /ctrl failed: $_" };
    };
    return $fail if $fail;
    unless ($res && $res->{success}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'handshake',
            "POST /ctrl http=" . ($res ? ($res->{status} || 0) : 0));
        return { ok => 0, error => 'POST /ctrl HTTP ' . ($res ? ($res->{status} || '?') : 'none') };
    }
    my $ctrl;
    try { $ctrl = decode_json($res->{content} || '{}') } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'handshake',
            "ctrl JSON: $_");
    };
    unless ($ctrl && ($ctrl->{code} || 0) == 200 && $ctrl->{data} && $ctrl->{data}{info}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'handshake',
            "ctrl code=" . ($ctrl ? ($ctrl->{code} || '?') : 'parse'));
        return { ok => 0, error => 'LAN handshake rejected by printer' };
    }
    my $plain;
    try {
        $plain = _decrypt_ctrl($ctrl->{data}{info}, $token, $ctrl->{data}{token} || '');
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'handshake',
            "AES decrypt failed: $_");
    };
    unless ($plain && $plain->{broker} && $plain->{username} && $plain->{password}) {
        return { ok => 0, error => 'Handshake decrypt did not yield MQTT broker' };
    }
    my ($bhost, $bport) = ($plain->{broker} =~ m{mqtts?://([^:/]+):(\d+)});
    unless ($bhost && $bport) {
        return { ok => 0, error => 'Broker URL was not mqtts://host:port' };
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'handshake',
        "MQTT broker=$bhost port=$bport device_id_len=" . length($plain->{deviceId} || ''));
    return {
        ok          => 1,
        host        => $info->{host},
        model_name  => $info->{model_name},
        model_id    => $info->{model_id} || $plain->{modeId} || '',
        serial      => $info->{serial},
        ctrl_type   => $info->{ctrl_type},
        camera_url  => $info->{camera_url},
        has_upload  => $info->{has_upload},
        broker_host => $bhost,
        broker_port => $bport,
        device_id   => $plain->{deviceId} || '',
        _user       => $plain->{username},
        _pass       => $plain->{password},
    };
}

sub fetch_state {
    my ($self, $c, $host, $port) = @_;
    my $hs = $self->handshake($c, $host, $port);
    my $out = {
        ok          => $hs->{ok} ? 1 : 0,
        error       => $hs->{error},
        host        => $hs->{host} || $host,
        model_name  => $hs->{model_name} || '',
        model_id    => $hs->{model_id} || '',
        serial      => $hs->{serial} || '',
        ctrl_type   => $hs->{ctrl_type} || '',
        camera_url  => $hs->{camera_url} || '',
        mqtt_ok     => 0,
    };
    return $out unless $hs->{ok};
    my $reports = $self->_mqtt_roundtrip($c, $hs, [
        { type => 'info',      action => 'query' },
        { type => 'tempature', action => 'query' },
        { type => 'print',     action => 'query' },
    ], 4);
    $out->{mqtt_ok} = $reports->{ok} ? 1 : 0;
    $out->{error} = $reports->{error} if $reports->{error};
    my $info = $reports->{by_type}{info} || {};
    my $temp = $reports->{by_type}{tempature} || $info->{temp} || {};
    my $proj = $info->{project} || {};
    $out->{print_state}    = $info->{state} || '';
    $out->{firmware}       = $info->{version} || '';
    $out->{filename}       = $proj->{filename} || '';
    $out->{progress}       = defined $proj->{progress} ? $proj->{progress} : '';
    $out->{curr_layer}     = $proj->{curr_layer};
    $out->{total_layers}   = $proj->{total_layers};
    $out->{print_time_min} = $proj->{print_time};
    $out->{remain_time_min}= $proj->{remain_time};
    $out->{pause}          = $proj->{pause};
    $out->{nozzle_temp}    = _first_defined($temp->{curr_nozzle_temp}, $info->{temp}{curr_nozzle_temp});
    $out->{bed_temp}       = _first_defined($temp->{curr_hotbed_temp}, $info->{temp}{curr_hotbed_temp});
    $out->{target_nozzle}  = _first_defined($temp->{target_nozzle_temp}, $info->{temp}{target_nozzle_temp});
    $out->{target_bed}     = _first_defined($temp->{target_hotbed_temp}, $info->{temp}{target_hotbed_temp});
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_state',
        "host=$out->{host} mqtt_ok=$out->{mqtt_ok} state=" . ($out->{print_state} || '')
        . " progress=" . ($out->{progress} eq '' ? '-' : $out->{progress}));
    return $out;
}

sub send_command {
    my ($self, $c, $host, $port, $cmd) = @_;
    $cmd = lc($cmd || '');
    unless ($cmd =~ /\A(pause|resume|stop)\z/) {
        return { ok => 0, error => 'Unknown command' };
    }
    my $hs = $self->handshake($c, $host, $port);
    return $hs unless $hs->{ok};
    my $payload = {
        type      => 'print',
        action    => $cmd,
        timestamp => int(time() * 1000),
        msgid     => _rand_alnum(16),
        data      => { taskid => '-1' },
    };
    my $reports = $self->_mqtt_roundtrip($c, $hs, [$payload], 3);
    $self->logging->log_with_details($c, $reports->{ok} ? 'info' : 'error', __FILE__, __LINE__,
        'send_command', "cmd=$cmd mqtt_ok=" . ($reports->{ok} ? 1 : 0)
        . ($reports->{error} ? " err=$reports->{error}" : ''));
    return {
        ok    => $reports->{ok} ? 1 : 0,
        error => $reports->{error},
        cmd   => $cmd,
    };
}

# Probe TCP 18910 then GET /info. subnet e.g. 192.168.2.0/24 (caller may override).
sub discover {
    my ($self, $c, $subnet) = @_;
    $subnet ||= '192.168.2.0/24';

    my $base;
    if ($subnet =~ /\A(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}\/\d+\z/) {
        $base = $1;
    }
    elsif ($subnet =~ /\A(\d{1,3}\.\d{1,3}\.\d{1,3})\z/) {
        $base = $1;
    }
    unless ($base) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'discover',
            "Bad subnet '$subnet'");
        return [];
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'discover',
        "Scanning $base.1-254 tcp/18910 then GET /info");

    my @found;
    my $ua = HTTP::Tiny->new(timeout => 1, max_redirect => 0);
    for my $i (1 .. 254) {
        my $ip = "$base.$i";
        my $sock = IO::Socket::INET->new(
            PeerAddr => $ip,
            PeerPort => 18910,
            Proto    => 'tcp',
            Timeout  => 0.15,
        );
        next unless $sock;
        close $sock;

        my $url = "http://$ip:18910/info";
        my $res = eval { $ua->get($url) };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'discover',
                "GET $url: $@");
        }
        my $content = ($res && $res->{content}) ? $res->{content} : '';
        my $status  = $res ? ($res->{status} || 0) : 0;
        my $model = 'LAN device :18910';
        if ($content =~ /kobra\s*3/i) {
            $model = 'Kobra 3';
        }
        elsif ($content =~ /anycubic/i) {
            $model = 'Anycubic';
        }
        elsif ($content =~ /kobra/i) {
            $model = 'Kobra';
        }
        push @found, {
            ip     => $ip,
            port   => 18910,
            model  => $model,
            status => ($res && $res->{success}) ? 'online' : 'port-open',
            info   => substr($content, 0, 120),
            http   => $status,
        };
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'discover',
            "Found $ip:18910 http=$status model=$model");
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'discover',
        "Scan done subnet=$base.0 found=" . scalar(@found));
    return \@found;
}

sub _mqtt_roundtrip {
    my ($self, $c, $hs, $messages, $wait_s) = @_;
    $wait_s ||= 4;
    unless (eval { require IO::Socket::SSL; 1 }) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_mqtt_roundtrip',
            "IO::Socket::SSL missing: $@");
        return { ok => 0, error => 'IO::Socket::SSL is not installed' };
    }
    my $sock;
    my $fail;
    try {
        $sock = IO::Socket::SSL->new(
            PeerHost        => $hs->{broker_host},
            PeerPort        => $hs->{broker_port},
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            Timeout         => 5,
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_mqtt_roundtrip',
            "TLS connect: $_");
        $fail = { ok => 0, error => "MQTT TLS connect failed: $_" };
    };
    return $fail if $fail;
    unless ($sock) {
        my $err = IO::Socket::SSL->errstr || $!;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_mqtt_roundtrip',
            "TLS connect failed: $err");
        return { ok => 0, error => "MQTT TLS connect failed: $err" };
    }
    $sock->autoflush(1);
    my $cid = 'cs' . _rand_alnum(8);
    my $ok_conn = eval {
        _mqtt_send($sock, 0x10, _mqtt_connect_payload($cid, $hs->{_user}, $hs->{_pass}));
        my ($type, $pl) = _mqtt_read($sock, 5);
        die "no CONNACK\n" unless defined $type && ($type >> 4) == 2 && length($pl) >= 2;
        my $rc = ord(substr($pl, 1, 1));
        die "CONNACK rc=$rc\n" unless $rc == 0;
        1;
    };
    if (!$ok_conn) {
        my $err = $@ || 'connect';
        chomp $err;
        close $sock;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_mqtt_roundtrip',
            "MQTT CONNECT: $err");
        return { ok => 0, error => "MQTT CONNECT failed: $err" };
    }
    my $mid = $hs->{model_id};
    my $did = $hs->{device_id};
    my $sub_topic = "anycubic/anycubicCloud/v1/printer/public/$mid/$did/#";
    eval {
        _mqtt_send($sock, 0x82, pack('n', 1) . _mqtt_str($sub_topic) . chr(0));
        _mqtt_read($sock, 3);
        1;
    } or do {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_mqtt_roundtrip',
            "SUBSCRIBE: $@");
    };
    for my $m (@$messages) {
        my $mtype = $m->{type} || 'info';
        my $topic = "anycubic/anycubicCloud/v1/web/printer/$mid/$did/$mtype";
        my $body = encode_json({
            type      => $mtype,
            action    => $m->{action} || 'query',
            timestamp => $m->{timestamp} || int(time() * 1000),
            msgid     => $m->{msgid} || _rand_alnum(16),
            data      => exists $m->{data} ? $m->{data} : undef,
        });
        eval {
            _mqtt_send($sock, 0x30, _mqtt_str($topic) . $body);
            1;
        } or do {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_mqtt_roundtrip',
                "PUBLISH $mtype: $@");
        };
    }
    my %by_type;
    my $deadline = time() + $wait_s;
    while (time() < $deadline) {
        my ($type, $pl) = _mqtt_read($sock, $deadline - time());
        last unless defined $type;
        next unless ($type >> 4) == 3;
        next unless length($pl) >= 2;
        my $tlen = unpack('n', substr($pl, 0, 2));
        next unless length($pl) >= 2 + $tlen;
        my $payload = substr($pl, 2 + $tlen);
        my $obj;
        try { $obj = decode_json($payload) } catch {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_mqtt_roundtrip',
                "report JSON: $_");
        };
        next unless $obj && ref($obj) eq 'HASH';
        next if (($obj->{action} || '') eq 'query' && !defined $obj->{data} && !exists $obj->{state});
        my $mt = $obj->{type} || '';
        if (defined $obj->{data}) {
            $by_type{$mt} = $obj->{data} if $mt;
        }
        elsif ($mt eq 'print' || $mt eq 'info') {
            $by_type{$mt} ||= $obj;
        }
        last if $by_type{info};
    }
    eval { _mqtt_send($sock, 0xE0, ''); 1 };
    close $sock;
    unless (keys %by_type) {
        return { ok => 1, by_type => {}, error => undef, empty => 1 };
    }
    return { ok => 1, by_type => \%by_type };
}

sub _decrypt_ctrl {
    my ($info_b64, $token, $local_token) = @_;
    require Crypt::CBC;
    my $key = substr($token, 16, 16);
    my $iv  = substr(($local_token || '') . ("\0" x 16), 0, 16);
    my $cipher = Crypt::CBC->new(
        -key         => $key,
        -cipher      => 'Rijndael',
        -iv          => $iv,
        -header      => 'none',
        -padding     => 'standard',
        -literal_key => 1,
        -keysize     => 16,
    );
    my $plain = $cipher->decrypt(decode_base64($info_b64));
    return decode_json($plain);
}

sub _mqtt_connect_payload {
    my ($cid, $user, $pass) = @_;
    my $flags = 0xC2;    # username + password + clean session
    my $vh = _mqtt_str('MQTT') . chr(4) . chr($flags) . pack('n', 60);
    return $vh . _mqtt_str($cid) . _mqtt_str($user) . _mqtt_str($pass);
}

sub _mqtt_str {
    my ($s) = @_;
    $s = '' unless defined $s;
    return pack('n', length($s)) . $s;
}

sub _mqtt_send {
    my ($sock, $hdr, $payload) = @_;
    $payload = '' unless defined $payload;
    my $n = length($payload);
    my $rl = '';
    do {
        my $d = $n % 128;
        $n = int($n / 128);
        $d |= 0x80 if $n;
        $rl .= chr($d);
    } while $n;
    my $buf = chr($hdr) . $rl . $payload;
    my $off = 0;
    while ($off < length($buf)) {
        my $w = $sock->syswrite($buf, length($buf) - $off, $off);
        die "MQTT write failed: $!\n" unless defined $w && $w > 0;
        $off += $w;
    }
}

sub _mqtt_read {
    my ($sock, $timeout) = @_;
    $timeout = 1 if !defined $timeout || $timeout <= 0;
    my $hdr = _ssl_read_n($sock, 1, $timeout);
    return unless defined $hdr && length($hdr) == 1;
    my $mul = 1;
    my $len = 0;
    for (1 .. 4) {
        my $b = _ssl_read_n($sock, 1, 3);
        return unless defined $b && length($b) == 1;
        my $n = ord($b);
        $len += ($n & 0x7f) * $mul;
        last unless $n & 0x80;
        $mul *= 128;
    }
    my $pl = $len ? _ssl_read_n($sock, $len, 5) : '';
    return unless defined $pl && length($pl) == $len;
    return (ord($hdr), $pl);
}

# IO::Select on SSL sockets is a lie (readable TLS records ≠ app data).
sub _ssl_read_n {
    my ($sock, $n, $timeout) = @_;
    my $buf = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm int($timeout + 1);
        while (length($buf) < $n) {
            my $chunk;
            my $got = $sock->sysread($chunk, $n - length($buf));
            die "eof\n" unless defined $got && $got > 0;
            $buf .= $chunk;
        }
        alarm 0;
        1;
    } or do {
        alarm 0;
    };
    return $buf if length($buf) == $n;
    return;
}

sub _rand_alnum {
    my ($n) = @_;
    my @c = ('a'..'z', 'A'..'Z', 0..9);
    return join '', map { $c[int(rand @c)] } 1 .. $n;
}

sub _rand_did {
    my ($n) = @_;
    my @c = ('A'..'Z', 0..9);
    return join '', map { $c[int(rand @c)] } 1 .. $n;
}

sub _first_defined {
    for my $v (@_) {
        return $v if defined $v;
    }
    return;
}

__PACKAGE__->meta->make_immutable;
1;

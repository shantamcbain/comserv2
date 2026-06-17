package Comserv::Util::DevPreview;

use strict;
use warnings;
use Digest::SHA qw(hmac_sha256);
use MIME::Base64 qw(encode_base64url decode_base64url);
use JSON::MaybeXS qw(encode_json decode_json);
use Comserv::Util::AdminAuth;
use Comserv::Util::GatewayOrchestrator;

# Authenticated preview of the dev workstation stack from production (no hosts / ZT).
# Site admins and CSC helpdesk workflows: production /admin/dev-preview → workstation :3001.

sub PREFIX { '/admin/dev-preview/site' }

sub _finish {
    my $c = _c(@_);
    $c->detach() if $c && $c->can('detach');
}

# Catalyst context from Class->method($c) or plain method($c).
sub _arg_off {
    return 1 if @_ >= 2 && ref( $_[1] ) && eval { $_[1]->can('req') };
    return 0;
}

sub _c {
    my $off = _arg_off(@_);
    return $_[$off] if @_ > $off && ref( $_[$off] ) && eval { $_[$off]->can('req') };
    return;
}

sub config {
    my $c = _c(@_);
    my $tgt = Comserv::Util::GatewayOrchestrator->targets;
    return {
        secret => $ENV{DEV_PREVIEW_SECRET}
            || ( $c && $c->config->{dev_preview_secret} )
            || 'comserv-dev-preview-change-in-production',
        backend_lan  => $ENV{DEV_PREVIEW_BACKEND}
            || ( $c && $c->config->{dev_preview_backend} )
            || "http://$tgt->{dev_workstation_lan}:$tgt->{dev_port}",
        backend_zt   => $ENV{DEV_PREVIEW_BACKEND_ZT}
            || ( $c && $c->config->{dev_preview_backend_zt} )
            || "http://$tgt->{dev_workstation_zt}:$tgt->{dev_port}",
        backend_host => $ENV{DEV_PREVIEW_BACKEND_HOST}
            || ( $c && $c->config->{dev_preview_backend_host} )
            || 'dev.computersystemconsulting.ca',
        ttl          => $ENV{DEV_PREVIEW_TTL} || 7200,
    };
}

sub is_workstation_host {
    my $c = _c(@_);
    return 0 unless $c;
    return 1 if ($ENV{SYSTEM_IDENTIFIER} || '') =~ /workstation/i;
    return 1 if $c && $c->config->{remote_code_editor};
    my $host = lc( _req_host($c) );
    return 1 if $host =~ /^(127\.0\.0\.1|localhost|192\.168\.1\.199)$/;
    return 1 if $host =~ /^workstation(?:\.local)?$/;
    return 1 if $host eq '172.30.131.126';
    return 1 if $host =~ /^dev\./;
    return 0;
}

sub _req_host {
    my $c = _c(@_);
    return '' unless $c && $c->can('req') && $c->req;
    my $host = $c->req->uri ? $c->req->uri->host : '';
    $host =~ s/:\d+\z// if defined $host;
    return lc( $host // '' );
}

sub preview_sitename {
    my $c = _c(@_);
    return '' unless $c;
    my $auth = Comserv::Util::AdminAuth->new;
    if ( $auth->is_csc_admin($c) ) {
        my $want = $c->req->param('site') || $c->req->param('SiteName') || '';
        $want =~ s/^\s+|\s+$//g;
        return $want if $want ne '';
    }
    return $c->stash->{SiteName} || $c->session->{SiteName} || '';
}

sub can_preview {
    my $c = _c(@_);
    return 0 unless $c && $c->user;

    my $auth     = Comserv::Util::AdminAuth->new;
    my $sitename = preview_sitename($c);
    return 0 unless $sitename && lc($sitename) ne 'none';

    return 1 if $auth->is_csc_admin($c);
    return 1 if $auth->check_admin_access( $c, 'dev_preview' );

    return 0;
}

sub _session_roles {
    my $c = _c(@_);
    return () unless $c;
    my $roles = $c->session->{roles} || [];
    return @$roles if ref $roles eq 'ARRAY';
    return ($roles) if $roles && !ref $roles;
    return ();
}

sub issue_token {
    my $c = _c(@_);
    return '' unless $c;
    return '' unless can_preview($c);

    my $cfg  = config($c);
    my $user = $c->session->{username} || ( $c->user ? $c->user->username : '' ) || '';
    return '' unless $user ne '';

    my $payload = {
        u => $user,
        s => preview_sitename($c),
        r => [ _session_roles($c) ],
        e => time() + $cfg->{ttl},
        v => 1,
    };
    return '' unless $payload->{s};

    my $body = encode_json($payload);
    my $sig  = hmac_sha256( $body, $cfg->{secret} );
    return encode_base64url($body) . '.' . encode_base64url($sig);
}

sub verify_token {
    my $off   = _arg_off(@_);
    my $c     = $_[$off];
    my $token = $_[ $off + 1 ];
    return unless $c;
    $token =~ s/^\s+|\s+$//g;
    return unless $token && $token =~ /^([^.]+)\.([^.]+)$/;

    my ( $body_b64, $sig_b64 ) = ($1, $2);
    my $cfg  = config($c);
    my $body = eval { decode_base64url($body_b64) };
    return if $@ || !defined $body;
    my $sig = eval { decode_base64url($sig_b64) };
    return if $@ || !defined $sig;
    return if $sig ne hmac_sha256( $body, $cfg->{secret} );

    my $payload = eval { decode_json($body) };
    return if $@ || ref $payload ne 'HASH';
    return if ( $payload->{v} // 0 ) != 1;
    return if ( $payload->{e} // 0 ) < time();
    return $payload;
}

sub maybe_apply_preview_session {
    my $c = _c(@_);
    return 0 unless $c;
    return 0 if $c->session->{dev_preview_active};

    my $token = $c->req->header('X-Comserv-Dev-Preview') || $c->req->param('_dvpt') || '';
    my $payload = verify_token( $c, $token );
    return 0 unless $payload;

    $c->session->{username}           = $payload->{u};
    $c->session->{SiteName}           = $payload->{s};
    $c->session->{roles}              = $payload->{r} || ['admin'];
    $c->session->{dev_preview}       = 1;
    $c->session->{dev_preview_active} = 1;
    $c->stash->{SiteName}             = $payload->{s};
    $c->stash->{dev_preview}          = 1;
    return 1;
}

sub _upstream_open {
    my $c = _c(@_);
    return unless $c;
    require IO::Socket::INET;
    my $cfg = config($c);
    for my $base ( $cfg->{backend_lan}, $cfg->{backend_zt} ) {
        next unless $base =~ m{^https?://([^:/]+)(?::(\d+))?};
        my ( $host, $port ) = ( $1, $2 || 3001 );
        my $sock = IO::Socket::INET->new(
            PeerAddr => $host,
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 4,
        );
        return ( $sock, $host, $port ) if $sock;
    }
    return;
}

sub _hop_by_hop {
    return map { lc($_) => 1 } qw(
        connection keep-alive proxy-authentication proxy-connection
        proxy-authorization te trailers transfer-encoding upgrade
    );
}

sub _rewrite_html {
    my ( $html, $prefix ) = @_;
    return $html unless defined $html && $html =~ /<html/i;

    unless ( $html =~ /<base\s/i ) {
        $html =~ s{<head(\s[^>]*)?>}{<head$1><base href="$prefix/">}i;
    }
    $html =~ s{(href|src|action)="/}{$1="$prefix/}g;
    return $html;
}

sub _rewrite_location {
    my ( $loc, $prefix ) = @_;
    return $loc unless defined $loc && $loc ne '';
    if ( $loc =~ m{^/} && $loc !~ m{^//} ) {
        return $prefix . $loc;
    }
    return $loc;
}

sub proxy_dispatch {
    my $c = _c(@_);
    return unless $c;
    my $prefix = PREFIX();

    unless ( can_preview($c) ) {
        $c->response->status(403);
        $c->response->content_type('text/plain; charset=UTF-8');
        $c->response->body('Access denied: administrator login required for dev preview.');
        _finish($c);
        return;
    }

    if ( is_workstation_host($c) ) {
        my $token = issue_token($c);
        my $dest  = $c->uri_for('/') . ( $token ? "?_dvpt=$token" : '' );
        $c->response->redirect($dest);
        _finish($c);
        return;
    }

    my $opened = _upstream_open($c);
    unless ($opened) {
        $c->response->status(502);
        $c->response->content_type('text/plain; charset=UTF-8');
        $c->response->body(
            "Dev workstation unreachable. Check $ENV{DEV_PREVIEW_BACKEND} or ZeroTier backend.\n"
        );
        _finish($c);
        return;
    }
    my ( $upstream, $up_host, $up_port ) = @$opened;

    my $path = $c->req->path || '';
    $path =~ s{\A/?admin/dev-preview/site}{};
    $path = '/' if $path eq '' || $path eq '/';
    $path = "/$path" unless $path =~ m{\A/};
    # Prevent filesystem paths from being used as routes
    if ($path =~ m{^/home/} || $path =~ m{^/[a-zA-Z]:/}) {
        $path = '/';
    }

    my $qs = $c->req->uri->query;
    my $uri = $path . ( defined $qs && $qs ne '' ? "?$qs" : '' );

    my $env    = $c->req->env || {};
    my $method = $c->req->method || 'GET';
    my %skip   = _hop_by_hop;
    my $req    = "$method $uri HTTP/1.1\r\n";

    for my $key ( sort keys %$env ) {
        next unless $key =~ /^HTTP_(.+)$/;
        my $name = $1;
        $name =~ s/_/-/g;
        next if $skip{ lc $name };
        next if lc $name eq 'host';
        my $val = $env->{$key};
        next unless defined $val && $val ne '';
        $req .= "$name: $val\r\n";
    }

    my $cfg = config($c);
    $req .= 'Host: ' . $cfg->{backend_host} . "\r\n";
    my $token = issue_token($c);
    $req .= "X-Comserv-Dev-Preview: $token\r\n" if $token;
    $req .= "X-Forwarded-For: " . ( $c->req->address || '' ) . "\r\n";
    $req .= "X-Forwarded-Proto: " . ( $c->req->secure ? 'https' : 'http' ) . "\r\n";
    $req .= "X-Forwarded-Prefix: $prefix\r\n";
    $req .= "Connection: close\r\n";

    my $body = $c->req->body;
    if ( defined $body && length $body ) {
        $req .= 'Content-Length: ' . length($body) . "\r\n";
    }
    $req .= "\r\n";
    $req .= $body if defined $body && length $body;

    print {$upstream} $req;
    $upstream->flush if $upstream->can('flush');

    my $header = '';
    while ( my $line = <$upstream> ) {
        $header .= $line;
        last if $header =~ /\r\n\r\n/;
    }

    unless ( $header =~ /^HTTP\/[\d.]+ (\d+)/ ) {
        $c->response->status(502);
        $c->response->body('Invalid response from dev workstation');
        close $upstream;
        _finish($c);
        return;
    }
    $c->response->status($1);

    my ( $hdr_block) = $header =~ /\AHTTP\/[\d.]+\s+\d+\s[^\r\n]*\r\n(.*)\r\n\r\n/s;
    my %resp_skip = _hop_by_hop;
    my $ctype     = '';
    if ($hdr_block) {
        for my $line ( split /\r\n/, $hdr_block ) {
            my ( $name, $val ) = split /:\s*/, $line, 2;
            next unless defined $name && defined $val;
            my $lname = lc $name;
            next if $resp_skip{$lname};
            if ( $lname eq 'location' ) {
                $val = _rewrite_location( $val, $prefix );
            }
            $ctype = $val if $lname eq 'content-type';
            $c->response->header( $name => $val );
        }
    }

    my $resp_body = '';
    if ( $header =~ /\r\n\r\n/s ) {
        ($resp_body) = $header =~ /\r\n\r\n(.*)/s;
    }
    my $buf;
    while ( my $n = read( $upstream, $buf, 65536 ) ) {
        $resp_body .= $buf;
    }
    close $upstream;

    if ( $ctype =~ /text\/html/i ) {
        $resp_body = _rewrite_html( $resp_body, $prefix );
    }

    $c->response->body($resp_body);
    _finish($c);
}

1;

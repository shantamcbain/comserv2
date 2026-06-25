
package Comserv::Controller::Admin;


use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::DeployStatus;
use Comserv::Util::AdminAuth;
use Comserv::Util::UserVerification;
use Comserv::Util::BackupManager;
use Comserv::Util::DiskStats;
use Comserv::Util::HardwareAgent;
use Comserv::Util::CodingAccess;
use DateTime;
use Data::Dumper;
use JSON qw(decode_json encode_json);
use Try::Tiny;
use MIME::Base64;
use File::Slurp qw(read_file write_file);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Copy;
use File::Spec;
use Digest::SHA qw(sha256_hex);
use File::Find;
use Module::Load;
use POSIX qw(_exit);
use DBI;

BEGIN { extends 'Catalyst::Controller'; }

# Returns an instance of the logging utility
sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->instance();
}
# adding code to force restart
# Begin method to check if the user has admin role
sub begin : Private {
    my ($self, $c) = @_;
    
    # Add detailed logging
    my $username = ($c->user_exists && $c->user) ? $c->user->username : ($c->session->{username} || 'Guest');
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', 
        "Admin controller begin method called by user: $username");
     # Initialize debug_msg array if it doesn't exist and debug mode is enabled
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        
        # Add the debug message to the array
        push @{$c->stash->{debug_msg}}, "Admin controller loaded successfully";
    }
    
    return 1; # Allow the request to proceed
}

# Base method for chained actions
sub base :Chained('/') :PathPart('admin') :CaptureArgs(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Starting Admin base action");
    
    # Common setup for all admin pages
    $c->stash(section => 'admin');
    
    # TEMPORARY FIX: Allow specific users direct access
    if ($c->session->{username} && $c->session->{username} eq 'Shanta') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
            "Admin access granted to user Shanta (bypass role check)");
        return 1;
    }
    
    # Check if the user has admin role
    my $has_admin_role = 0;
    
    # First check if user exists
    if ($c->user_exists) {
        # Get roles from session
        my $roles = $c->session->{roles};
        
        # Log the roles for debugging
        my $roles_debug = 'none';
        if (defined $roles) {
            if (ref($roles) eq 'ARRAY') {
                $roles_debug = join(', ', @$roles);
                
                # Check if 'admin' is in the roles array
                foreach my $role (@$roles) {
                    if (lc($role) eq 'admin') {
                        $has_admin_role = 1;
                        last;
                    }
                }
            } elsif (!ref($roles)) {
                $roles_debug = $roles;
                # Check if roles string contains 'admin'
                if ($roles =~ /\badmin\b/i) {
                    $has_admin_role = 1;
                }
            }
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
            "Admin access check - User: " . $c->session->{username} . ", Roles: $roles_debug, Has admin: " . ($has_admin_role ? 'Yes' : 'No'));
    }
    
    unless ($has_admin_role) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'base', 
            "Access denied: User does not have admin role");
        
        # Set error message in flash
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        
        # Redirect to login page with destination parameter
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return 0;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Completed Admin base action");
    
    return 1;
}

# Admin dashboard

sub ssh_terminal :Path('/admin/ssh_terminal') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ssh_terminal',
        "Starting SSH terminal action for user: " . ($c->session->{username} // 'Guest'));

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'ssh_terminal')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }

    my $start_result;
    if ($c->request->params->{start_ttyd}) {
        $start_result = $self->_start_comserv_ttyd($c);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ssh_terminal',
            'start_ttyd requested: ' . ($start_result->{success} ? 'ok' : ($start_result->{error} // 'failed')));
    }

    my $ttyd = $self->_ttyd_resolve_endpoint($c);
    $c->stash(
        template                => 'admin/ssh_terminal.tt',
        show_code_editor_widget => 0,
        ttyd_url                => $ttyd->{url},
        ttyd_direct_url         => $self->_ttyd_direct_client_url($c, $ttyd->{port}),
        ttyd_proxied            => 1,
        ttyd_local_url          => $ttyd->{local_url},
        ttyd_port               => $ttyd->{port},
        ttyd_reachable          => $ttyd->{reachable},
        ttyd_writable           => $ttyd->{writable},
        ttyd_host_mode          => $ttyd->{host_mode} ? 1 : 0,
        ttyd_start_cmd          => 'script/ttyd_comserv_start.sh',
        ttyd_watcher_cmd        => 'script/ttyd_host_watcher.sh',
        ttyd_start_url          => $c->uri_for('/admin/ssh_terminal', { start_ttyd => 1 }),
        ttyd_start_result       => $start_result,
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ssh_terminal',
        "Completed SSH terminal action");
}

sub _is_docker_container {
    my ($self) = @_;
    return 1 if -f '/.dockerenv';
    return 1 if ($ENV{SYSTEM_IDENTIFIER} || '') =~ /docker|workstation-dev/i;
    return 0;
}

sub _ttyd_port_reachable_on {
    my ($self, $host, $port) = @_;
    return 0 unless $host && $port;
    return 0 unless eval { require IO::Socket::INET; 1 };
    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 1,
    );
    return $sock ? do { close $sock; 1 } : 0;
}

sub _ttyd_port_reachable {
    my ($self, $port) = @_;
    return $self->_ttyd_port_reachable_on('127.0.0.1', $port);
}

sub _ttyd_status_from_host_log {
    my ($self, $home) = @_;
    $home ||= '.';
    my $logf = "$home/var/ttyd-comserv.log";
    return unless -f $logf;

    open my $fh, '<', $logf or return;
    my @lines = <$fh>;
    close $fh;
    return unless @lines;

    my $tail = join '', @lines[-60 .. -1];
    return unless $tail =~ /Listening on port:\s*7682/;
    my $writable = ($tail !~ /readonly mode/i) ? 1 : 0;
    return { reachable => 1, writable => $writable };
}

sub _ttyd_process_flags {
    my ($self, $port) = @_;
    $port //= 7681;
    my %flags = (
        writable     => 0,
        check_origin => 0,
        command      => '',
        port         => $port,
    );
    open my $ps, '-|', 'ps', 'aux' or return \%flags;
    while (my $line = <$ps>) {
        next unless $line =~ m{/usr/bin/ttyd\b|(?:^|\s)ttyd\s};
        next unless $line =~ /(?:^|\s)-p\s+\Q$port\E(?:\s|$)/;
        $flags{writable}     = 1 if $line =~ /(?:^|\s)-W(?:\s|$)/;
        $flags{check_origin} = 1 if $line =~ /(?:^|\s)-O(?:\s|$)/;
        if ($line =~ /ttyd\s+(.*)$/) {
            my $args = $1;
            if ($args =~ /(?:^|\s)(\S+)\s*$/) {
                my $cmd = $1;
                $flags{command} = $cmd unless $cmd =~ /^-/;
            }
        }
        last;
    }
    close $ps;
    return \%flags;
}

sub _ttyd_client_url {
    my ($self, $c, $port) = @_;
    $port //= 7682;

    # Native dev: browser talks to ttyd on :7682 directly (no Perl WS proxy needed).
    # Docker dev: same-origin proxy on Comserv port 3000 (laptop cannot reach :7682).
    unless ($self->_is_docker_container) {
        return $self->_ttyd_direct_client_url($c, $port)
            if $self->_ttyd_port_reachable($port);
    }

    if ($c && eval { $c->uri_for }) {
        my $proxy = eval { $c->uri_for('/admin/ttyd-proxy') };
        if ($proxy) {
            my $url = $proxy->as_string;
            $url =~ s{/+\z}{};
            return $url;
        }
    }
    return $self->_ttyd_direct_client_url($c, $port);
}

sub _ttyd_direct_client_url {
    my ($self, $c, $port) = @_;
    $port //= 7682;
    my $host = '127.0.0.1';
    if ($c && eval { $c->req }) {
        my $uri_host = $c->req->uri ? ($c->req->uri->host || '') : '';
        if ($uri_host =~ /\S/) {
            $host = $uri_host;
            $host =~ s/:\d+\z//;
        }
    }
    return "http://$host:$port/admin/ttyd-proxy";
}

sub _ttyd_resolve_endpoint {
    my ($self, $c) = @_;
    my $home         = $self->_comserv_home($c);
    my $default_port = 7682;
    my $client_url   = $self->_ttyd_client_url($c, $default_port);

    if ($self->_is_docker_container) {
        my $log_status = $self->_ttyd_status_from_host_log($home) || {};
        return {
            port           => $default_port,
            url            => $client_url,
            local_url      => "http://127.0.0.1:$default_port",
            ws_url         => ($client_url =~ s/^http/ws/r),
            reachable      => $log_status->{reachable} ? 1 : 0,
            writable       => $log_status->{writable} ? 1 : 0,
            check_origin   => 0,
            command        => 'bash -l (host)',
            using_fallback => 0,
            host_mode      => 1,
        };
    }

    my @ports = (7682, 7681);
    my $fallback;
    for my $port (@ports) {
        next unless $self->_ttyd_port_reachable($port);
        my $flags = $self->_ttyd_process_flags($port);
        my $url   = $self->_ttyd_client_url($c, $port);
        my $ep = {
            port            => $port,
            url             => $url,
            local_url       => "http://127.0.0.1:$port",
            ws_url          => ($url =~ s/^http/ws/r),
            reachable       => 1,
            writable        => $flags->{writable} ? 1 : 0,
            check_origin    => $flags->{check_origin} ? 1 : 0,
            command         => $flags->{command} || '',
            using_fallback  => 0,
            host_mode       => 0,
        };
        return $ep if $flags->{writable};
        $fallback //= $ep;
    }
    return $fallback if $fallback;

    return {
        port           => $default_port,
        url            => $client_url,
        local_url      => "http://127.0.0.1:$default_port",
        ws_url         => ($client_url =~ s/^http/ws/r),
        reachable      => 0,
        writable       => 0,
        check_origin   => 0,
        command        => '',
        using_fallback => 0,
        host_mode      => 0,
    };
}

sub _comserv_home {
    my ($self, $c) = @_;
    return $c->config->{home} if $c && $c->config->{home};
    my $p = __FILE__;
    $p =~ s{/lib/Comserv.*}{};
    return $p;
}

sub _request_host_ttyd_start {
    my ($self, $home) = @_;
    require File::Path;
    File::Path::make_path("$home/var");
    my $req = "$home/var/ttyd-start.request";
    open my $fh, '>', $req or return "Cannot write $req: $!";
    print $fh time(), "\n";
    close $fh;
    return;
}

sub _start_comserv_ttyd {
    my ($self, $c) = @_;
    my $home    = $self->_comserv_home($c);
    my $starter = "$home/script/ttyd_comserv_start.sh";

    if ($self->_is_docker_container) {
        my $log_status = $self->_ttyd_status_from_host_log($home) || {};
        if ($log_status->{reachable} && $log_status->{writable}) {
            return {
                success         => 1,
                already_running => 1,
                output          => "Host ttyd already running (port 7682, seen in var/ttyd-comserv.log)\n",
                exit_code       => 0,
            };
        }
        my $err = $self->_request_host_ttyd_start($home);
        return { success => 0, error => $err } if $err;
        sleep 3;
        $log_status = $self->_ttyd_status_from_host_log($home) || {};
        my $ready  = $log_status->{reachable} && $log_status->{writable};
        return {
            success         => $ready ? 1 : 0,
            already_running => 0,
            output          => "Requested host ttyd start via var/ttyd-start.request.\n"
                . "On the workstation host, keep this running once:\n"
                . "  script/ttyd_host_watcher.sh\n"
                . "Or run manually:\n"
                . "  script/ttyd_comserv_start.sh\n",
            exit_code       => $ready ? 0 : 1,
            error           => $ready ? undef : 'Host watcher did not start ttyd yet (run ttyd_host_watcher.sh on host)',
        };
    }

    if ($self->_ttyd_port_reachable(7682) && $self->_ttyd_process_flags(7682)->{writable}) {
        return {
            success         => 1,
            already_running => 1,
            output          => "Writable ttyd already running on port 7682\n",
            exit_code       => 0,
        };
    }

    unless (-e $starter) {
        return { success => 0, error => "Start script not found: $starter" };
    }
    unless (-x $starter) {
        return { success => 0, error => "Start script is not executable: $starter" };
    }

    my $output = qx($starter 2>&1);
    my $exit   = ($? == -1) ? -1 : ($? >> 8);
    my $ttyd   = $self->_ttyd_resolve_endpoint($c);
    my $ready  = $ttyd->{reachable} && $ttyd->{writable};

    return {
        success         => $ready ? 1 : 0,
        already_running => 0,
        output          => $output // '',
        exit_code       => $exit,
        error           => $ready ? undef : ($output =~ /\S/ ? $output : 'ttyd failed to start'),
        ttyd_url        => $ttyd->{url},
        ttyd_reachable  => $ttyd->{reachable} ? 1 : 0,
        ttyd_writable   => $ttyd->{writable} ? 1 : 0,
    };
}

sub _ensure_comserv_ttyd {
    my ($self, $c) = @_;
    return if $self->_ttyd_port_reachable(7682) && $self->_ttyd_process_flags(7682)->{writable};
    return if $self->{_comserv_ttyd_start_attempted}++;
    my $result = $self->_start_comserv_ttyd($c);
    warn "ttyd_comserv_start.sh failed: " . ($result->{error} // $result->{output} // 'unknown') . "\n"
        unless $result->{success};
}

sub shell_run_command :Path('/admin/shell_run_command') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'shell_run_command')) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => JSON::false, error => 'Admin required' }));
        return;
    }

    my $cmd = $c->request->params->{command} || '';
    unless ($cmd =~ /\S/) {
        $c->response->body(encode_json({ success => JSON::false, error => 'Command is required' }));
        return;
    }

    if ($cmd =~ /rm\s+-rf\s+\/|mkfs|dd\s+if=/i) {
        $c->response->body(encode_json({ success => JSON::false, error => 'Command blocked for safety' }));
        return;
    }

    # require Comserv::Controller::AI;  # now uses model layer
    my $cfg = $c->model('AI')->config;
    unless ($cfg) {
        $c->response->body(encode_json({ success => JSON::false, error => 'AI controller unavailable' }));
        return;
    }

    my $root = $cfg->_project_root_path($c);
    chdir $root or do {
        $c->response->body(encode_json({ success => JSON::false, error => "Failed to chdir to project root: $!" }));
        return;
    };

    my $api_key = $cfg->_grok_cli_api_key($c);
    local $ENV{XAI_API_KEY}  = $api_key if $api_key;
    local $ENV{GROK_API_KEY}  = $api_key if $api_key;
    local $ENV{HOME}          = $cfg->_grok_home() || $ENV{HOME};
    local $ENV{USER}          = 'shanta';
    local $ENV{LOGNAME}       = 'shanta';
    local $ENV{PATH}          = join ':', grep { $_ && -d $_ }
        ("$ENV{HOME}/.local/bin", "$ENV{HOME}/.grok/bin", '/usr/local/bin', '/usr/bin', '/bin');
    local $ENV{TERM}          = 'xterm-256color';
    local $ENV{LANG}          = $ENV{LANG} || 'en_US.UTF-8';
    local $ENV{LC_ALL}        = $ENV{LC_ALL} || 'en_US.UTF-8';

    my $output   = qx($cmd 2>&1) // '';
    my $exit_val = ($? == -1) ? -1 : ($? >> 8);

    $c->response->body(encode_json({
        success   => JSON::true,
        output    => $output,
        exit_code => $exit_val,
    }));
}

sub _interactive_ws_available {
    my ($self, $c) = @_;
    return 1 if ($ENV{COMSERV_TWIGGY} // '') eq '1';
    return 1 if ($ENV{PLACK_SERVER_SOFTWARE} // '') =~ /Twiggy/i;
    if ($c && eval { $c->req }) {
        my $env = $c->req->env || {};
        my $sw  = join ' ', grep { $_ }
            ($env->{SERVER_SOFTWARE} // ''),
            ($env->{'psgi.server_software'} // '');
        return 1 if $sw =~ /Twiggy/i;
    }
    my $home = $c && $c->config->{home} ? $c->config->{home} : undef;
    return 1 if $home && -f "$home/var/twiggy.enabled";
    return 1 if $c && $c->config->{interactive_terminal};
    return 0;
}

sub _ssh_terminal_start_ttyd_json {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ssh_terminal_start_ttyd',
        'Starting writable ttyd via script/ttyd_comserv_start.sh');

    my $result = $self->_start_comserv_ttyd($c);
    my $ttyd   = $self->_ttyd_resolve_endpoint($c);
    my $ready  = $ttyd->{reachable} && $ttyd->{writable};

    $c->response->body(encode_json({
        success                  => $ready ? JSON::true : JSON::false,
        already_running          => $result->{already_running} ? JSON::true : JSON::false,
        output                   => $result->{output} // '',
        exit_code                => $result->{exit_code},
        error                    => $result->{error},
        interactive_ws_available => $ready ? JSON::true : JSON::false,
        ttyd_url                 => $ttyd->{url},
        ttyd_port                => $ttyd->{port},
        ttyd_reachable           => $ttyd->{reachable} ? JSON::true : JSON::false,
        ttyd_writable            => $ttyd->{writable} ? JSON::true : JSON::false,
        shell_run_path           => '/admin/shell_run_command',
        hint                     => $ready
            ? 'Interactive shell via ttyd on ' . $ttyd->{url}
            : 'Restart writable ttyd: script/ttyd_comserv_start.sh (needs -W flag)',
    }));
}

sub ssh_terminal_start_ttyd :Path('/admin/ssh_terminal_start_ttyd') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'ssh_terminal_start_ttyd')) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => JSON::false, error => 'admin required' }));
        return;
    }

    $self->_ssh_terminal_start_ttyd_json($c);
}

sub ssh_terminal_status :Path('/admin/ssh_terminal_status') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'ssh_terminal_status')) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => JSON::false, error => 'admin required' }));
        return;
    }

    my $method = lc($c->req->method || 'get');
    my $action = $c->request->params->{action} // '';
    if ($method eq 'post' && $action eq 'start') {
        $self->_ssh_terminal_start_ttyd_json($c);
        return;
    }

    my $ttyd = $self->_ttyd_resolve_endpoint($c);
    my $ready = $ttyd->{reachable} && $ttyd->{writable};
    $c->response->body(encode_json({
        success                  => JSON::true,
        interactive_ws_available => $ready ? JSON::true : JSON::false,
        ttyd_url                 => $ttyd->{url},
        ttyd_port                => $ttyd->{port},
        ttyd_reachable           => $ttyd->{reachable} ? JSON::true : JSON::false,
        ttyd_writable            => $ttyd->{writable} ? JSON::true : JSON::false,
        shell_run_path           => '/admin/shell_run_command',
        hint                     => $ready
            ? 'Interactive shell via ttyd on ' . $ttyd->{url}
            : 'Restart writable ttyd: script/ttyd_comserv_start.sh (needs -W flag)',
    }));
}

# Same-origin reverse proxy to host ttyd (HTTP + WebSocket). Docker/laptop uses
# /admin/ttyd-proxy on the Comserv port instead of direct :7682.
sub ttyd_proxy :Path('/admin/ttyd-proxy') :Args(0) {
    my ($self, $c) = @_;
    $self->_ttyd_proxy_dispatch($c);
}

sub ttyd_proxy_slash :Path('/admin/ttyd-proxy/') :Args(0) {
    my ($self, $c) = @_;
    $self->_ttyd_proxy_dispatch($c);
}

sub ttyd_proxy_ws :Path('/admin/ttyd-proxy/ws') :Args(0) {
    my ($self, $c) = @_;
    $self->_ttyd_proxy_dispatch($c);
}

sub ttyd_proxy_token :Path('/admin/ttyd-proxy/token') :Args(0) {
    my ($self, $c) = @_;
    $self->_ttyd_proxy_dispatch($c);
}

sub _ttyd_upstream_sock_path {
    my ($self, $c) = @_;
    my $home = $self->_comserv_home($c);
    return "$home/var/ttyd-proxy.sock";
}

sub _ttyd_upstream_open {
    my ($self, $c) = @_;
    my $home = $self->_comserv_home($c);
    my $port = $ENV{TTYD_HOST_PORT} || 7682;

    if ($self->_is_docker_container) {
        my $sock_path = $self->_ttyd_upstream_sock_path($c);
        if (-S $sock_path) {
            require IO::Socket::UNIX;
            my $sock = IO::Socket::UNIX->new(Peer => $sock_path);
            return $sock if $sock;
        }
        for my $host (qw(host.docker.internal 172.20.0.1 172.17.0.1)) {
            next unless $self->_ttyd_port_reachable_on($host, $port);
            require IO::Socket::INET;
            my $sock = IO::Socket::INET->new(
                PeerAddr => $host,
                PeerPort => $port,
                Proto    => 'tcp',
                Timeout  => 2,
            );
            return $sock if $sock;
        }
        return;
    }

    require IO::Socket::INET;
    return IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 2,
    );
}

sub _ttyd_proxy_hop_by_hop {
    return map { lc($_) => 1 } qw(
        connection keep-alive proxy-authentication proxy-connection
        proxy-authorization te trailers transfer-encoding upgrade
    );
}

sub _ttyd_proxy_dispatch {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'ttyd_proxy')) {
        $c->response->status(403);
        $c->response->body('Access denied: admin required');
        return;
    }

    my $upgrade = lc($c->req->header('Upgrade') || '');
    if ($upgrade eq 'websocket') {
        $self->_ttyd_proxy_websocket($c);
        return;
    }

    my $upstream = $self->_ttyd_upstream_open($c);
    unless ($upstream) {
        $c->response->status(502);
        $c->response->content_type('text/plain');
        $c->response->body(
            "Cannot reach host ttyd. On the workstation host run: script/ttyd_comserv_start.sh\n"
        );
        return;
    }

    my $env     = $c->req->env || {};
    my $method  = $c->req->method || 'GET';
    my $uri     = $env->{REQUEST_URI} || '/admin/ttyd-proxy/';
    my %skip    = $self->_ttyd_proxy_hop_by_hop;
    my $req     = "$method $uri HTTP/1.1\r\n";

    for my $key (sort keys %$env) {
        next unless $key =~ /^HTTP_(.+)$/;
        my $name = $1;
        $name =~ s/_/-/g;
        next if $skip{ lc $name };
        next if lc $name eq 'host';
        my $val = $env->{$key};
        next unless defined $val && $val ne '';
        $req .= "$name: $val\r\n";
    }
    $req .= 'Host: 127.0.0.1:' . ($ENV{TTYD_HOST_PORT} || 7682) . "\r\n";
    $req .= "Connection: close\r\n";

    my $body = $c->req->body;
    if (defined $body && length $body) {
        $req .= 'Content-Length: ' . length($body) . "\r\n";
    }
    $req .= "\r\n";
    $req .= $body if defined $body && length $body;

    print {$upstream} $req;
    $upstream->flush if $upstream->can('flush');

    my $header = '';
    while (my $line = <$upstream>) {
        $header .= $line;
        last if $header =~ /\r\n\r\n/;
    }

    unless ($header =~ /^HTTP\/[\d.]+ (\d+)/) {
        $c->response->status(502);
        $c->response->body('Invalid response from ttyd');
        close $upstream;
        return;
    }
    $c->response->status($1);

    my ($hdr_block) = $header =~ /\AHTTP\/[\d.]+\s+\d+\s[^\r\n]*\r\n(.*)\r\n\r\n/s;
    my %resp_skip = $self->_ttyd_proxy_hop_by_hop;
    if ($hdr_block) {
        for my $line (split /\r\n/, $hdr_block) {
            my ($name, $val) = split /:\s*/, $line, 2;
            next unless defined $name && defined $val;
            next if $resp_skip{ lc $name };
            $c->response->header($name => $val);
        }
    }

    my $resp_body = '';
    if ($header =~ /\r\n\r\n/s) {
        ($resp_body) = $header =~ /\r\n\r\n(.*)/s;
    }
    my $buf;
    while (my $n = read($upstream, $buf, 65536)) {
        $resp_body .= $buf;
    }
    close $upstream;

    $c->response->body($resp_body);
    $c->detach();
}

sub _ttyd_proxy_websocket {
    my ($self, $c) = @_;

    my $upstream = $self->_ttyd_upstream_open($c);
    unless ($upstream) {
        $c->response->status(502);
        $c->response->body('Cannot reach host ttyd for WebSocket');
        return;
    }

    my $env = $c->req->env || {};
    my $uri = $env->{REQUEST_URI} || '/admin/ttyd-proxy/ws';
    my %skip = $self->_ttyd_proxy_hop_by_hop;
    my $req  = "GET $uri HTTP/1.1\r\n";

    for my $key (sort keys %$env) {
        next unless $key =~ /^HTTP_(.+)$/;
        my $name = $1;
        $name =~ s/_/-/g;
        next if $skip{ lc $name };
        next if lc $name eq 'host';
        my $val = $env->{$key};
        next unless defined $val && $val ne '';
        $req .= "$name: $val\r\n";
    }
    $req .= 'Host: 127.0.0.1:' . ($ENV{TTYD_HOST_PORT} || 7682) . "\r\n";
    $req .= "Connection: Upgrade\r\n\r\n";

    print {$upstream} $req;
    $upstream->flush if $upstream->can('flush');

    my $io = $c->req->io_fh;
    my $upstream_resp = '';
    my $start = time;
    while ($upstream_resp !~ /\r\n\r\n/ && (time - $start) < 5) {
        my $buf;
        my $n = sysread($upstream, $buf, 4096);
        last unless defined $n && $n > 0;
        $upstream_resp .= $buf;
    }

    unless ($upstream_resp =~ /^HTTP\/[\d.]+ 101/) {
        $c->response->status(502);
        $c->response->body('ttyd WebSocket upgrade failed');
        close $upstream;
        return;
    }

    my ($hdr_part, $ws_extra) = $upstream_resp =~ /\A(HTTP\/[\d.]+ 101[^\r\n]*\r\n(?:(?:[^\r\n]+\r\n)*)\r\n)(.*)/s;
    print $io ($hdr_part // $upstream_resp);
    print $io $ws_extra if defined $ws_extra && length $ws_extra;
    $io->flush if $io->can('flush');

    $self->_ttyd_socket_keepalive($io);
    $self->_ttyd_socket_keepalive($upstream);

    # Hand off to AnyEvent before Catalyst/Plack applies HTTP idle timeouts
    $c->detach();

    require AnyEvent;
    require AnyEvent::Handle;

    my $closed = 0;
    my ($client, $server);
    my $cv = AnyEvent->condvar;

    my $cleanup = sub {
        return if $closed++;
        $client->destroy if $client;
        $server->destroy if $server;
        close $upstream if $upstream;
        $cv->send;
    };

    $client = AnyEvent::Handle->new(
        fh       => $io,
        on_error => sub { $cleanup->() },
    );
    $server = AnyEvent::Handle->new(
        fh       => $upstream,
        on_error => sub { $cleanup->() },
    );

    $client->on_read(sub {
        my ($hdl) = @_;
        return if $closed;
        return unless $server && $server->fh;
        $server->push_write(delete $hdl->{rbuf});
    });
    $server->on_read(sub {
        my ($hdl) = @_;
        return if $closed;
        return unless $client && $client->fh;
        $client->push_write(delete $hdl->{rbuf});
    });

    $client->on_eof($cleanup);
    $server->on_eof($cleanup);

    $cv->recv;
}

sub _ttyd_socket_keepalive {
    my ($self, $fh) = @_;
    return unless $fh;
    eval {
        require Socket;
        my $fd = fileno($fh);
        return unless defined $fd;
        setsockopt($fh, Socket::SOL_SOCKET(), Socket::SO_KEEPALIVE(), pack('i', 1));
    };
}

# WebSocket PTY — same-origin interactive shell (replaces cross-origin ttyd iframe).
sub system_shell_terminal :Path('/admin/system-shell-terminal') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'system_shell_terminal')) {
        $c->response->status(403);
        $c->response->body('Access denied: admin required');
        return;
    }

    my $upgrade    = $c->req->header('Upgrade')    || '';
    my $connection = $c->req->header('Connection') || '';
    unless ($upgrade eq 'websocket' && $connection =~ /Upgrade/i) {
        $c->response->status(400);
        $c->response->body('WebSocket upgrade required');
        return;
    }

    require Protocol::WebSocket::Handshake::Server;

    my $io = $c->req->io_fh;
    my $hs = Protocol::WebSocket::Handshake::Server->new;
    my $env = $c->req->env;
    my $handshake_request =
        "GET " . $env->{REQUEST_URI} . " HTTP/1.1\r\n" .
        "Host: " . $env->{HTTP_HOST} . "\r\n" .
        "Upgrade: " . ($env->{HTTP_UPGRADE} || 'websocket') . "\r\n" .
        "Connection: " . ($env->{HTTP_CONNECTION} || 'Upgrade') . "\r\n" .
        "Sec-WebSocket-Key: " . ($env->{HTTP_SEC_WEBSOCKET_KEY} || '') . "\r\n" .
        "Sec-WebSocket-Version: " . ($env->{HTTP_SEC_WEBSOCKET_VERSION} || '13') . "\r\n" .
        "\r\n";

    $hs->parse($handshake_request);
    unless ($hs->is_done) {
        $c->response->status(400);
        $c->response->body('WebSocket handshake failed');
        return;
    }

    print $io $hs->to_string;
    $io->flush if $io->can('flush');
    $c->detach();

    unless ($self->_interactive_ws_available($c)) {
        $c->response->status(503);
        $c->response->body('WebSocket terminal requires Twiggy. Start with: perl script/comserv_server.pl --twiggy -p PORT -r');
        return;
    }

    require Comserv::Controller::Coding;
    my $coding = $c->controller('Coding');
    unless ($coding && $coding->can('_terminal_relay_child')) {
        warn "system_shell_terminal: Coding controller relay unavailable\n";
        return;
    }

    my $shell_env = $coding->can('_coding_shell_env')
        ? $coding->_coding_shell_env($c) : {};
    $shell_env->{login_shell} = 1;
    $coding->_terminal_relay_child($io, $shell_env);
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    # Report this server's metrics (throttled) so infrastructure cards populate
    eval { Comserv::Util::HardwareAgent->report_if_due($c, 300) };

    # Get system stats
    my $stats = $self->get_system_stats($c);

    # Get remote server stats (db + prod catalyst servers)
    my $remote_servers = $self->get_remote_server_stats($c);
    
    # Get recent user activity
    my $recent_activity = $self->get_recent_activity($c);
    
    # Get system notifications
    my $notifications = $self->get_system_notifications($c);
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Admin controller index view - Template: admin/index.tt";
    }
    
    my $pending_hosting = 0;
    my $pending_hosting_sites = [];
    my $outstanding_invoices = [];
    eval {
        my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || '';
        if (lc($site_name) eq 'csc') {
            my @pending = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
                { status => 'pending' },
                { order_by => { -asc => 'sitename' } }
            )->all;
            $pending_hosting = scalar @pending;
            $pending_hosting_sites = \@pending;
        } else {
            my @inv = $c->model('DBEncy')->resultset('Accounting::InventorySupplierInvoice')->search(
                { sitename => $site_name, status => 'outstanding' },
                { join => 'supplier', prefetch => 'supplier', order_by => { -asc => 'me.due_date' } }
            )->all;
            $outstanding_invoices = \@inv;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
            "Outstanding invoices query error: $@");
    }

    my $helpdesk_open_tickets = [];
    my $helpdesk_open_count   = 0;
    eval {
        my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || '';
        my $is_csc    = lc($site_name) eq 'csc';
        my %hd_where  = (status => [qw(open in_progress)]);
        $hd_where{site_name} = $site_name unless $is_csc;
        my @hd_tickets = $c->model('DBEncy')->resultset('SupportTicket')->search(
            \%hd_where,
            { order_by => [{ -desc => 'me.created_at' }], rows => 10 }
        )->all;
        $helpdesk_open_count   = $is_csc
            ? $c->model('DBEncy')->resultset('SupportTicket')->search({ status => [qw(open in_progress)] })->count
            : scalar @hd_tickets;
        $helpdesk_open_tickets = \@hd_tickets;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
            "HelpDesk ticket query error: $@");
    }

    my $software_status = $self->_get_software_status($c);

    my $site_name_idx = $c->stash->{SiteName} || $c->session->{SiteName} || '';
    my $is_csc        = (lc($site_name_idx) eq 'csc') ? 1 : 0;
    my $has_accounting = $is_csc ? 1 : 0;
    unless ($is_csc) {
        eval {
            $has_accounting = $c->model('DBEncy')->resultset('SiteModule')->search({
                sitename    => $site_name_idx,
                module_name => 'accounting',
            })->count ? 1 : 0;
        };
    }

    $c->stash(
        template              => 'admin/index.tt',
        stats                 => $stats,
        remote_servers        => $remote_servers,
        recent_activity       => $recent_activity,
        notifications         => $notifications,
        pending_hosting        => $pending_hosting,
        pending_hosting_sites  => $pending_hosting_sites,
        outstanding_invoices   => $outstanding_invoices,
        helpdesk_open_tickets  => $helpdesk_open_tickets,
        helpdesk_open_count    => $helpdesk_open_count,
        software_status        => $software_status,
        is_csc                 => $is_csc,
        has_accounting         => $has_accounting,
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Completed Admin index action");
}

sub _get_software_status {
    my ($self, $c) = @_;

    my $repo_dir = $c->path_to('..')->stringify;

    my $current_branch  = '';
    my $last_commit     = '';
    my $commits_behind  = 0;
    my $has_uncommitted = 0;
    my $has_untracked   = 0;
    my @recommendations;

    eval {
        chomp($current_branch = `git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null`);
        chomp($last_commit    = `git -C "$repo_dir" log -1 --format="%h %s" 2>/dev/null`);

        my $fetch_out = `git -C "$repo_dir" fetch origin 2>&1`;
        chomp(my $behind_raw = `git -C "$repo_dir" rev-list --count HEAD..origin/main 2>/dev/null`);
        $commits_behind = ($behind_raw =~ /^\d+$/) ? $behind_raw + 0 : 0;

        my $status_out = `git -C "$repo_dir" status --porcelain 2>/dev/null`;
        $has_uncommitted = ($status_out =~ /^[MADRCU]/m) ? 1 : 0;
        $has_untracked   = ($status_out =~ /^\?\?/m)     ? 1 : 0;

        if ($commits_behind > 0) {
            push @recommendations, {
                type    => 'warning',
                icon    => 'fas fa-exclamation-triangle',
                message => "Your branch is $commits_behind commit(s) behind origin/main.",
                action  => 'Run Git Pull to update.',
                link    => '/admin/git_pull',
            };
        }
    };

    return {
        git_status => {
            current_branch          => $current_branch  || 'Unknown',
            last_commit             => $last_commit      || 'No commits',
            commits_behind          => $commits_behind,
            has_uncommitted_changes => $has_uncommitted,
            has_untracked_files     => $has_untracked,
        },
        recommendations => \@recommendations,
    };
}

# Get system statistics for the admin dashboard
sub get_system_stats {
    my ($self, $c) = @_;
    
    my $stats = {
        user_count        => 0,
        active_user_count => 0,
        file_count        => 0,
        disk_usage        => 'Unknown',
        disk_pct          => 0,
        disk_used         => '',
        disk_total        => '',
        disk_level        => 'ok',
        nfs_pct           => 0,
        nfs_used          => '',
        nfs_total         => '',
        nfs_level         => 'ok',
        uptime            => 'Unknown',
    };

    eval {
        my $schema = $c->model('DBEncy');
        $stats->{user_count}        = $schema->resultset('User')->count;
        $stats->{active_user_count} = $schema->resultset('User')->search({ status => 'active' })->count;
    };

    eval {
        $stats->{file_count} = $c->model('DBEncy')->resultset('File')->search({ file_status => 'active' })->count;
    };

    eval {
        my $disk = Comserv::Util::DiskStats->app_disk_stats($c);
        if ($disk) {
            $stats->{disk_pct}   = $disk->{pct};
            $stats->{disk_used}  = $disk->{used_fmt};
            $stats->{disk_total} = $disk->{total_fmt};
            $stats->{disk_usage} = $disk->{usage};
            $stats->{disk_level} = $disk->{level};
        }
    };

    eval {
        my $nfs = Comserv::Util::DiskStats->separated_nfs_stats($c);
        if ($nfs->{blended}) {
            $stats->{nfs_blended} = 1;
        } elsif ($nfs->{same_device}) {
            $stats->{nfs_same_device} = 1;
        } elsif ($nfs->{pct}) {
            $stats->{nfs_pct}   = $nfs->{pct};
            $stats->{nfs_used}  = $nfs->{used_fmt};
            $stats->{nfs_total} = $nfs->{total_fmt};
            $stats->{nfs_level} = $nfs->{level};
            $stats->{nfs_source} = $nfs->{source} if $nfs->{source};
        }
    };

    eval {
        my $uptime_output = `uptime 2>/dev/null`;
        if ($uptime_output =~ /up\s+(.*?),\s+\d+\s+user/) {
            $stats->{uptime} = $1;
        } elsif ($uptime_output =~ /up\s+(.+)/) {
            ($stats->{uptime} = $1) =~ s/,\s*\d+\s*user.*//;
        }
    };

    return $stats;
}

my @MONITORED_SERVERS = (
    { names => ['db-production', 'db-01', 'db01', '192.168.1.20'], ip => '192.168.1.20',
      label => 'DB Server 1 (192.168.1.20)', hostname_override => 'db-production',
      ssh_user => 'ubuntu', ssh_alias => 'db1',
      ingest_url => undef },
    { names => ['db-02', 'db02', '192.168.1.21'], ip => '192.168.1.21',
      label => 'DB Server 2 (192.168.1.21)', hostname_override => 'db-02',
      ssh_user => 'ubuntu', ssh_alias => 'db2',
      ingest_url => undef },
    { names => ['comservproduction1', 'comservproduction', 'prod-01', 'prod1', 'production1', '192.168.1.126'],
      ip => '192.168.1.126', label => 'Prod Catalyst 1 (192.168.1.126)',
      hostname_override => 'comservproduction1', ssh_user => 'ubuntu', ssh_alias => 'production1',
      ingest_url => 'http://127.0.0.1:5000/admin/hardware_monitor/ingest' },
    { names => ['comservproduction2', 'prod-02', 'prod2', 'production2', '192.168.1.127'],
      ip => '192.168.1.127', label => 'Prod Catalyst 2 (192.168.1.127)',
      hostname_override => 'comservproduction2', ssh_user => 'ubuntu', ssh_alias => 'production2',
      ingest_url => 'http://127.0.0.1:5000/admin/hardware_monitor/ingest' },
);

sub _monitored_server_by_ip {
    my ($ip) = @_;
    return unless defined $ip && length $ip;
    for my $srv (@MONITORED_SERVERS) {
        return $srv if $srv->{ip} eq $ip;
    }
    return;
}

sub _hw_ingest_url {
    my ($self, $c) = @_;
    return "$ENV{HW_INGEST_BASE_URL}/admin/hardware_monitor/ingest"
        if $ENV{HW_INGEST_BASE_URL};
    my $lan_ip = do {
        my $ip = '';
        eval {
            require Socket;
            my $sock;
            if (Socket::inet_aton('192.168.1.1')) {
                socket($sock, Socket::PF_INET(), Socket::SOCK_DGRAM(), 0);
                connect($sock, Socket::pack_sockaddr_in(80, Socket::inet_aton('192.168.1.1')));
                $ip = Socket::inet_ntoa((Socket::unpack_sockaddr_in(getsockname($sock)))[1]);
                close $sock;
            }
        };
        $ip || '127.0.0.1';
    };
    my $port = $c->req->uri->port // 3001;
    return "http://${lan_ip}:${port}/admin/hardware_monitor/ingest";
}

sub _ssh_credentials_paths {
    my @paths;
    push @paths, "$ENV{HOME}/.comserv/secrets/ssh_credentials.json" if $ENV{HOME};
    push @paths, '/home/shanta/.comserv/secrets/ssh_credentials.json';
    my %seen;
    return grep { $_ && -f $_ && !$seen{$_}++ } @paths;
}

sub _load_ssh_credentials {
    my ($self) = @_;
    for my $path ($self->_ssh_credentials_paths()) {
        open my $cf, '<', $path or next;
        local $/;
        my $json = <$cf>;
        close $cf;
        my $creds = eval { decode_json($json) };
        return $creds if $creds && ref $creds eq 'HASH';
    }
    return {};
}

sub _resolve_ssh_target {
    my ($self, $target) = @_;
    $target = lc($target // '');
    return (undef, undef, 22, '') if $target eq '' || $target eq 'workstation';

    my ($ssh_host, $ssh_user, $ssh_port, $ssh_password) = ('', 'ubuntu', 22, '');
    my %alias = (
        production1 => '192.168.1.126', prod1 => '192.168.1.126', prod_01 => '192.168.1.126',
        production2 => '192.168.1.127', prod2 => '192.168.1.127', prod_02 => '192.168.1.127',
        db1 => '192.168.1.20', db_01 => '192.168.1.20', db01 => '192.168.1.20',
        db2 => '192.168.1.21', db_02 => '192.168.1.21', db02 => '192.168.1.21',
    );
    if ($alias{$target}) {
        $ssh_host = $alias{$target};
    } elsif ($target =~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {
        $ssh_host = $target;
    } elsif ($target =~ /^[a-z0-9._-]+$/i) {
        $ssh_host = $target;
    } else {
        return (undef, undef, 22, '');
    }

    for my $srv (@MONITORED_SERVERS) {
        next unless $srv->{ip} eq $ssh_host;
        $ssh_user = $srv->{ssh_user} if $srv->{ssh_user};
        last;
    }

    my $creds = $self->_load_ssh_credentials();
    if (%$creds) {
        $ssh_password = $creds->{ssh_password} || '';
        $ssh_port     = $creds->{ssh_port}     || 22;
        if ($creds->{ssh_target} && $creds->{ssh_target} =~ /^([^@]+)\@(.+)$/) {
            $ssh_user = $1 unless $ssh_host =~ /^192\.168\.1\.(?:20|21)$/;
        }
        if ($creds->{hosts} && ref $creds->{hosts} eq 'HASH' && $creds->{hosts}{$ssh_host}) {
            my $hc = $creds->{hosts}{$ssh_host};
            $ssh_user     = $hc->{user}     if $hc->{user};
            $ssh_password = $hc->{password} if $hc->{password};
            $ssh_port     = $hc->{port}     if $hc->{port};
        }
    }

    $ssh_port = int($ssh_port);
    $ssh_port = 22 unless $ssh_port > 0 && $ssh_port <= 65535;
    return ($ssh_host, $ssh_user, $ssh_port, $ssh_password);
}

sub get_remote_server_stats {
    my ($self, $c) = @_;
    my @servers;
    eval {
        my $rs = $c->model('DBEncy')->resultset('HardwareMetrics');
        for my $srv (@MONITORED_SERVERS) {
            my @names = @{ $srv->{names} };
            push @names, $srv->{ip} if $srv->{ip};
            my %latest;
            my @rows = $rs->search(
                {
                    -or => [
                        { hostname => { -in => \@names } },
                        { system_identifier => { -like => $srv->{ip} . '%' } },
                    ],
                    timestamp => { '>=' => \"DATE_SUB(NOW(), INTERVAL 24 HOUR)" },
                },
                { order_by => { -desc => 'timestamp' }, rows => 500 },
            )->all;
            for my $row (@rows) {
                my $mn = $row->metric_name;
                next if exists $latest{$mn};
                $latest{$mn} = {
                    value => $row->metric_value,
                    text  => $row->metric_text,
                    unit  => $row->unit,
                    level => $row->level,
                    ts    => $row->timestamp,
                };
            }
            my $reported_hostname = @rows ? $rows[0]->hostname : undef;
            my $last_seen         = @rows ? $rows[0]->timestamp : undef;
            my $fresh_count = $rs->search(
                {
                    -or => [
                        { hostname => { -in => \@names } },
                        { system_identifier => { -like => $srv->{ip} . '%' } },
                    ],
                    timestamp => { '>=' => \"DATE_SUB(NOW(), INTERVAL 2 HOUR)" },
                },
                { rows => 1 },
            )->count;
            push @servers, {
                name      => $srv->{ip},
                ip        => $srv->{ip},
                label     => $srv->{label},
                hostname  => $reported_hostname,
                metrics   => \%latest,
                last_seen => $last_seen,
                online    => scalar(@rows) ? 1 : 0,
                stale     => (scalar(@rows) && !$fresh_count) ? 1 : 0,
            };
        }
    };
    return \@servers;
}

my @HW_GRAPH_METRICS = qw(
    cpu_load_pct mem_used_pct swap_used_pct
    ipmi_power_consumption ipmi_inlet_temp
    ipmi_ps1_current ipmi_ps2_current
);

sub _local_monitor_hostnames {
    my ($self) = @_;
    my %seen;
    my @names;
    for my $n (qw(workstation workstation.local 192.168.1.199 localhost), $ENV{HW_HOSTNAME_OVERRIDE}) {
        next unless defined $n && $n ne '';
        push @names, $n unless $seen{$n}++;
    }
    for my $cmd ('hostname -s 2>/dev/null', 'hostname -f 2>/dev/null', 'hostname 2>/dev/null') {
        my $h = `$cmd`;
        chomp $h if defined $h;
        next unless $h;
        push @names, $h unless $seen{$h}++;
    }
    return \@names;
}

sub _hardware_metrics_host_search {
    my ($self, $c, $target) = @_;
    my @conds;
    my %seen;

    if ($target && ref $target eq 'HASH' && ($target->{ip} || $target->{names})) {
        my $srv = ($target->{ip} ? _monitored_server_by_ip($target->{ip}) : undef) || $target;
        my @names;
        for my $n (
            @{ $srv->{names} || [] },
            $srv->{ip},
            $srv->{hostname_override},
            $target->{hostname},
            $srv->{hostname},
        ) {
            next unless defined $n && $n ne '';
            push @names, $n unless $seen{$n}++;
        }
        push @conds, { hostname => { -in => \@names } } if @names;
        if ($srv->{ip}) {
            push @conds, { system_identifier => { -like => $srv->{ip} . '%' } };
        }
    } else {
        my @names = @{ $self->_local_monitor_hostnames() };
        my $discovered = $self->_discover_local_agent_hostname($c);
        push @names, $discovered if $discovered;
        my %ns;
        @names = grep { defined $_ && length $_ && !$ns{$_}++ } @names;
        push @conds, { hostname => { -in => \@names } } if @names;
    }

    return @conds ? { -or => \@conds } : undef;
}

sub _discover_local_agent_hostname {
    my ($self, $c) = @_;
    return unless $c && eval { $c->model('DBEncy') };
    my $rs = $c->model('DBEncy')->resultset('HardwareMetrics');
    my $row = eval {
        $rs->search(
            {
                system_identifier => { -like => '%:agent' },
                timestamp         => { '>=' => \"DATE_SUB(NOW(), INTERVAL 7 DAY)" },
            },
            { order_by => { -desc => 'timestamp' }, rows => 1 },
        )->single;
    };
    return $row ? $row->hostname : undef;
}

sub _perl_loaded_modules {
    my @modules;
    for my $module (sort keys %INC) {
        next unless $module =~ /\.pm$/;
        (my $name = $module) =~ s/\//::/g;
        $name =~ s/\.pm$//;
        my $version = eval "\$${name}::VERSION" || 'Unknown'; ## no critic
        push @modules, { name => $name, version => $version };
    }
    return \@modules;
}

sub _perl_installed_modules {
    my ($perl_bin) = @_;
    return [] unless defined $perl_bin && length $perl_bin && -x $perl_bin;
    my $oneliner = 'use ExtUtils::Installed; my $inst=ExtUtils::Installed->new; '
                 . 'for my $m (sort $inst->modules) { my $v=$inst->version($m)||""; print $m,"\t",$v,"\n" }';
    my $cmd = $perl_bin . ' -MExtUtils::Installed -e ' . "'" . $oneliner . "'";
    my @modules;
    my $output = `$cmd 2>/dev/null`;
    for my $line (split /\n/, $output // '') {
        my ($name, $version) = split /\t/, $line, 2;
        next unless defined $name && length $name;
        push @modules, { name => $name, version => ($version // '') || 'Unknown' };
    }
    return \@modules;
}

sub _perl_environments {
    my ($self) = @_;
    my @envs;
    my $runtime = $^X || 'perl';
    push @envs, {
        label   => 'Catalyst process (loaded now)',
        path    => $runtime,
        version => $],
        kind    => 'loaded',
        modules => _perl_loaded_modules(),
        note    => 'Modules already loaded by this running app — not the full install list.',
    };

    if ($runtime =~ /perlbrew/) {
        push @envs, {
            label   => 'Perlbrew Perl (installed)',
            path    => $runtime,
            version => $],
            kind    => 'installed',
            modules => _perl_installed_modules($runtime),
            note    => 'Site modules installed under the active perlbrew Perl.',
        };
    }

    for my $sys (qw(/usr/bin/perl /bin/perl)) {
        next unless -x $sys;
        next if $sys eq $runtime;
        my $ver = `$sys -e 'print $]' 2>/dev/null`;
        chomp $ver;
        push @envs, {
            label   => 'System Perl (installed)',
            path    => $sys,
            version => ($ver || 'Unknown'),
            kind    => 'installed',
            modules => _perl_installed_modules($sys),
            note    => 'Distribution/system Perl module list.',
        };
        last;
    }
    return \@envs;
}

sub get_hardware_metrics_history {
    my ($self, $c, $target, $hours) = @_;
    $hours = int($hours || 24);
    $hours = 1   if $hours < 1;
    $hours = 168 if $hours > 168;

    my $result = {
        hours           => $hours,
        chart_data_json => '[]',
        metrics         => [],
        history_count   => 0,
        db_error        => '',
        search_label    => '',
    };
    return $result unless $c && eval { $c->model('DBEncy') };

    my $host_search = $self->_hardware_metrics_host_search($c, $target);
    return $result unless $host_search;

    my @metrics;
    my %chart_data;
    eval {
        my $rs = $c->model('DBEncy')->resultset('HardwareMetrics');
        my %search = (
            %$host_search,
            timestamp => { '>=' => \"DATE_SUB(NOW(), INTERVAL $hours HOUR)" },
        );

        my @rows = $rs->search(
            \%search,
            { order_by => { -desc => 'timestamp' } },
        );
        @metrics = map { {
            timestamp         => $_->timestamp,
            hostname          => $_->hostname,
            metric_name       => $_->metric_name,
            metric_value      => $_->metric_value,
            metric_text       => $_->metric_text,
            unit              => $_->unit,
            level             => $_->level,
            message           => $_->message,
        } } @rows;

        my @disk_pct_metrics = $rs->search(
            { metric_name => { -like => 'disk_used_pct%' }, %search },
            { columns => ['metric_name'], distinct => 1 },
        )->get_column('metric_name')->all;

        my @graph_metric_names = (@HW_GRAPH_METRICS, @disk_pct_metrics, $rs->search(
            { metric_name => { -like => '%_temp' }, %search },
            { columns => ['metric_name'], distinct => 1 },
        )->get_column('metric_name')->all);

        my %graph_search = (%search, metric_name => { -in => \@graph_metric_names });
        my @chart_rows = $rs->search(
            \%graph_search,
            { order_by => { -asc => 'timestamp' } },
        );

        my %_seen_slot;
        for my $row (@chart_rows) {
            my $mn = $row->metric_name;
            next unless defined $row->metric_value;
            my $ts = $row->timestamp;
            if ($ts =~ /^(\d{4}-\d{2}-\d{2} \d{2}):(\d{2})/) {
                my $slot_min = int($2 / 5) * 5;
                $ts = sprintf('%s:%02d:00', $1, $slot_min);
            }
            my $slot_key = "$mn|" . $row->hostname . "|$ts";
            next if $_seen_slot{$slot_key}++;
            push @{ $chart_data{$mn}{ $row->hostname } },
                [ $ts, $row->metric_value + 0 ];
        }
        for my $mn (keys %chart_data) {
            for my $h (keys %{ $chart_data{$mn} }) {
                $chart_data{$mn}{$h} = [ sort { $a->[0] cmp $b->[0] } @{ $chart_data{$mn}{$h} } ];
            }
        }
    };
    if ($@) {
        $result->{db_error} = "$@";
        return $result;
    }

    my %in_order = map { $_ => 1 } @HW_GRAPH_METRICS;
    my @ordered  = grep { exists $chart_data{$_} } @HW_GRAPH_METRICS;
    push @ordered, grep {
        /^disk_used_pct/ && !$in_order{$_} && exists $chart_data{$_} && do {
            (my $mnt = $_) =~ s/^disk_used_pct//;
            $mnt =~ s{^_}{/}; $mnt =~ s{_}{/}g;
            $mnt !~ m{^(/sys|/proc|/run/|/dev/pts|/snap/)};
        }
    } sort keys %chart_data;
    push @ordered, grep { /_temp$/ && !$in_order{$_} } sort keys %chart_data;

    $result->{metrics}         = \@metrics;
    $result->{history_count}   = scalar @metrics;
    $result->{chart_data_json} = encode_json([ map { { metric => $_, hosts => $chart_data{$_} } } @ordered ]);
    return $result;
}

# Get recent user activity for the admin dashboard
sub get_recent_activity {
    my ($self, $c) = @_;
    
    my @activity = ();
    
    # Try to get recent logins
    eval {
        my @logins = $c->model('DBEncy::UserLogin')->search(
            {},
            {
                order_by => { -desc => 'login_time' },
                rows => 5
            }
        );
        
        foreach my $login (@logins) {
            push @activity, {
                type => 'login',
                user => $login->user->username,
                time => $login->login_time,
                details => $login->ip_address
            };
        }
    };
    
    # Try to get recent content changes
    eval {
        my @changes = $c->model('DBEncy::ContentHistory')->search(
            {},
            {
                order_by => { -desc => 'change_time' },
                rows => 5
            }
        );
        
        foreach my $change (@changes) {
            push @activity, {
                type => 'content',
                user => $change->user->username,
                time => $change->change_time,
                details => "Updated " . $change->content->title
            };
        }
    };
    
    # Sort all activity by time (most recent first)
    @activity = sort { $b->{time} cmp $a->{time} } @activity;
    
    # Limit to 10 items
    if (scalar(@activity) > 10) {
        @activity = @activity[0..9];
    }
    
    return \@activity;
}

# Get system notifications for the admin dashboard
sub get_system_notifications {
    my ($self, $c) = @_;
    
    my @notifications = ();
    
    # Check for pending user registrations
    eval {
        my $pending_count = $c->model('DBEncy::User')->search({ status => 'pending' })->count();
        if ($pending_count > 0) {
            push @notifications, {
                type => 'warning',
                message => "$pending_count pending user registration(s) require approval",
                link => $c->uri_for('/admin/users', { filter => 'pending' })
            };
        }
    };
    
    # Check for low disk space (app server disk only)
    eval {
        my $disk = Comserv::Util::DiskStats->app_disk_stats($c);
        if ($disk && $disk->{pct} >= 90) {
            push @notifications, {
                type    => 'danger',
                message => "App server disk critically low ($disk->{pct}% — $disk->{used_fmt} / $disk->{total_fmt})",
                link    => $c->uri_for('/admin/hardware_monitor/disk_health'),
            };
        } elsif ($disk && $disk->{pct} >= 80) {
            push @notifications, {
                type    => 'warning',
                message => "App server disk running low ($disk->{pct}%)",
                link    => $c->uri_for('/admin/hardware_monitor/disk_health'),
            };
        }
    };
    
    # Check for pending comments
    eval {
        my $pending_count = $c->model('DBEncy::Comment')->search({ status => 'pending' })->count();
        if ($pending_count > 0) {
            push @notifications, {
                type => 'info',
                message => "$pending_count pending comment(s) require moderation",
                link => $c->uri_for('/admin/comments', { filter => 'pending' })
            };
        }
    };
    
    # Check for pending CSC hosting registrations — only for CSC-level admin/accounting users
    eval {
        my $user_id = $c->session->{user_id};
        my $is_csc_admin = 0;
        if ($user_id) {
            my $user_obj = $c->model('DBEncy')->resultset('User')->find($user_id,
                { columns => ['roles'] });
            if ($user_obj) {
                my $global_roles = $user_obj->roles || '';
                $is_csc_admin = ($global_roles =~ /admin|accounting/i) ? 1 : 0;
            }
        }

        if ($is_csc_admin) {
            my $pending = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
                { status => 'pending' }
            )->count;
            if ($pending > 0) {
                my $msg = "$pending pending CSC hosting registration(s) require approval."
                    . " Note: new accounts without prior setup must be added manually to the"
                    . " system after payment is confirmed.";
                push @notifications, {
                    type    => 'warning',
                    message => $msg,
                    link    => 'https://computersystemconsulting.ca/membership/admin/hosting_accounts',
                };
            }

            # Recently paid hosting invoices (last 48h)
            my $cutoff = DateTime->now->subtract(hours => 48)->strftime('%Y-%m-%d %H:%M:%S');
            my @paid = $c->model('DBEncy')->resultset('Accounting::InventorySupplierInvoice')->search(
                { sitename => { '!=' => 'CSC' }, status => 'paid',
                  updated_at => { '>=' => $cutoff } },
                { order_by => { -desc => 'updated_at' } }
            )->all;
            for my $inv (@paid) {
                push @notifications, {
                    type    => 'success',
                    message => 'Payment received: ' . $inv->sitename . ' — ' . $inv->invoice_number
                               . ' (CAD ' . $inv->total_amount . ')',
                    link    => 'https://computersystemconsulting.ca/Inventory/sales',
                };
            }
        }

        # Auto-pay overdue alert — shown to any site admin for their own invoices
        eval {
            my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || '';
            my $today_str = do { my @t = localtime; sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) };
            my $auto_due  = $c->model('DBEncy')->resultset('Accounting::InventorySupplierInvoice')->search({
                sitename => $site_name,
                auto_pay => 1,
                status   => { '!=' => 'paid' },
                due_date => { '<=' => $today_str },
            })->count;
            if ($auto_due > 0) {
                push @notifications, {
                    type    => 'warning',
                    message => "$auto_due auto-pay invoice(s) past due — confirm the charge has posted.",
                    link    => '/Inventory/invoice/process_auto_pay',
                };
            }
        };
    };

    return \@notifications;
}

# Admin users management
sub users :Path('/admin/users') :Args(0) {
    my ($self, $c) = @_;
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    
    unless ($admin_auth->check_admin_access($c, 'admin_users')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'users',
            "Access denied for admin_users - username: " . ($c->session->{username} || 'none'));
        $c->flash->{error_msg} = "Access denied. Admin access required.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'users',
        "Admin accessing user management - user: " . ($c->session->{username} || 'unknown'));

    my $admin_type = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $sitename = $c->session->{SiteName};
    my $schema = $c->model('DBEncy');

    my $search = $c->req->param('search') || '';
    my $filter_site = $c->req->param('filter_site') || '';
    my $filter_role = $c->req->param('filter_role') || '';
    my $filter_status = $c->req->param('filter_status') || '';
    my $page = $c->req->param('page') || 1;
    my $rows_per_page = 50;

    my @users;
    my $pager;
    my %stats = ( total => 0, active => 0, suspended => 0, pending => 0, by_role => {} );
    my @available_sites;
    my %user_sites_map;
    my $error_msg;

    eval {
        my %search_conditions;

        if ($search) {
            $search_conditions{'-or'} = [
                { username    => { like => "%$search%" } },
                { first_name  => { like => "%$search%" } },
                { last_name   => { like => "%$search%" } },
                { email       => { like => "%$search%" } },
            ];
        }

        $search_conditions{status} = $filter_status if $filter_status;

        if ($filter_role && $filter_role ne 'all') {
            $search_conditions{roles} = { like => "%$filter_role%" };
        }

        my $user_rs;

        if ($is_csc_admin) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'users',
                "CSC admin - showing all users, search='$search' status='$filter_status' role='$filter_role'");

            $user_rs = $schema->resultset('User')->search(
                \%search_conditions,
                { page => $page, rows => $rows_per_page, order_by => { -desc => 'me.id' } }
            );
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'users',
                "Site admin ($sitename) - filtering by site");

            if ($filter_site && $filter_site ne $sitename) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'users',
                    "Site admin tried to access filter_site=$filter_site, forcing to $sitename");
                $filter_site = $sitename;
            }

            my $site_obj = $schema->resultset('Site')->search({ name => $sitename })->single;
            my @user_ids;
            if ($site_obj) {
                @user_ids = $schema->resultset('UserSiteRole')->search(
                    { site_id => $site_obj->id },
                    { columns => ['user_id'], distinct => 1 }
                )->get_column('user_id')->all;
            }

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'users',
                "Found " . scalar(@user_ids) . " user_ids for sitename=$sitename");

            $search_conditions{id} = @user_ids ? { -in => \@user_ids } : { -in => [0] };

            $user_rs = $schema->resultset('User')->search(
                \%search_conditions,
                { page => $page, rows => $rows_per_page, order_by => { -desc => 'me.id' } }
            );
        }

        @users = $user_rs->all;
        $pager = $user_rs->pager;

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'users',
            "Fetched " . scalar(@users) . " users (page $page, total " . $pager->total_entries . ")");

        if (@users) {
            my @user_ids = map { $_->id } @users;
            my @site_role_rows = $schema->resultset('UserSiteRole')->search(
                { user_id => { -in => \@user_ids } },
                { columns => ['user_id', 'site_id'], distinct => 1 }
            )->all;
            my %site_name_cache;
            for my $sr (@site_role_rows) {
                my $sid = $sr->site_id;
                next unless defined $sid;
                unless (exists $site_name_cache{$sid}) {
                    my $s = $schema->resultset('Site')->find($sid);
                    $site_name_cache{$sid} = $s ? $s->name : "site#$sid";
                }
                push @{$user_sites_map{$sr->user_id}}, $site_name_cache{$sid};
            }
        }

        my $stats_rs = $schema->resultset('User')->search(
            $is_csc_admin ? {} : \%search_conditions
        );

        while (my $u = $stats_rs->next) {
            $stats{total}++;
            my $status = $u->status || 'active';
            if    ($status eq 'active')    { $stats{active}++ }
            elsif ($status eq 'suspended') { $stats{suspended}++ }
            elsif ($status =~ /pending/)   { $stats{pending}++ }

            if ($u->roles) {
                for my $role (split /,/, $u->roles) {
                    $role =~ s/^\s+|\s+$//g;
                    $stats{by_role}{$role} = ($stats{by_role}{$role} || 0) + 1 if $role;
                }
            }
        }

        @available_sites = $is_csc_admin
            ? $schema->resultset('Site')->search({}, { order_by => 'name' })->all
            : $schema->resultset('Site')->search({ name => $sitename })->all;

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'users',
            "Completed users action - stats: total=$stats{total} active=$stats{active} suspended=$stats{suspended}");
    };

    if ($@) {
        $error_msg = "Database error loading users: $@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'users', $error_msg);
    }

    $c->stash(
        users           => \@users,
        pager           => $pager,
        stats           => \%stats,
        search          => $search,
        filter_site     => $filter_site,
        filter_role     => $filter_role,
        filter_status   => $filter_status,
        is_csc_admin    => $is_csc_admin,
        admin_type      => $admin_type,
        sitename        => $sitename,
        available_sites => \@available_sites,
        user_sites_map  => \%user_sites_map,
        error_msg       => $error_msg,
        template        => 'admin/users.tt',
    );
}

# Admin purge unverified/bogus users
sub purge_users :Path('/admin/purge_users') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();

    unless ($admin_auth->check_admin_access($c, 'admin_users')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'purge_users',
            "Access denied for admin_users - username: " . ($c->session->{username} || 'none'));
        $c->flash->{error_msg} = "Access denied. Admin access required.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $admin_type = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');

    unless ($is_csc_admin) {
        $c->flash->{error_msg} = "Only global CSC administrators can purge users.";
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }

    my $hours = $c->req->param('purge_hours') // 24;
    if ($hours !~ /^\d+$/ || $hours <= 0) {
        $hours = 24;
    }

    my $email_pattern = $c->req->param('email_pattern') // '';
    $email_pattern =~ s/^\s+|\s+$//g;

    my $schema = $c->model('DBEncy');
    my $purged_count = 0;

    eval {
        my $cutoff = DateTime->now->subtract(hours => $hours)->strftime('%Y-%m-%d %H:%M:%S');

        my %search_cond = (
            status => 'pending_verification',
            created_at => { '<' => $cutoff },
        );

        if ($email_pattern ne '') {
            $search_cond{email} = { like => "%$email_pattern%" };
        }

        my @users_to_purge = $schema->resultset('User')->search(\%search_cond)->all;

        for my $user (@users_to_purge) {
            my $user_id = $user->id;

            $schema->txn_do(sub {
                $schema->resultset('EmailVerificationCode')->search({ user_id => $user_id })->delete;
                $schema->resultset('PasswordResetToken')->search({ user_id => $user_id })->delete;
                $schema->resultset('UserSiteRole')->search({ user_id => $user_id })->delete;
                $schema->resultset('Accounting::PointAccount')->search({ user_id => $user_id })->delete;

                eval {
                    $schema->resultset('System::SiteUser')->search({ user_id => $user_id })->delete;
                };

                $schema->resultset('User')->search({ id => $user_id })->delete;
                $purged_count++;
            });
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'purge_users',
            "Admin purged $purged_count unverified users older than $hours hours (email pattern: '$email_pattern')");

        $c->flash->{success_msg} = "Successfully purged $purged_count unverified accounts.";
    };

    if ($@) {
        my $err = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'purge_users',
            "Error purging unverified users: $err");
        $c->flash->{error_msg} = "Error purging unverified users: $err";
    }

    $c->response->redirect($c->uri_for('/admin/users'));
}

# Admin create user
sub create_user :Path('/admin/create_user') :Args(0) {
    my ($self, $c) = @_;
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    
    unless ($admin_auth->check_admin_access($c, 'admin_create_user')) {
        $c->flash->{error_msg} = "Access denied. Admin access required.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $admin_type = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $sitename = $c->session->{SiteName};
    my $schema = $c->model('DBEncy');

    if ($c->req->method eq 'POST') {
        my $first_name = $c->req->param('first_name');
        my $last_name = $c->req->param('last_name');
        my $email = $c->req->param('email');
        my @sitenames = $c->req->param('sitenames');
        my @roles = $c->req->param('roles');

        unless ($first_name && $last_name && $email) {
            $c->stash(
                error_msg => 'First name, last name, and email are required',
                template => 'admin/create_user.tt'
            );
            return;
        }

        unless (@sitenames && @roles) {
            $c->stash(
                error_msg => 'At least one site and role must be selected',
                template => 'admin/create_user.tt'
            );
            return;
        }

        if (!$is_csc_admin) {
            foreach my $site (@sitenames) {
                if ($site ne $sitename) {
                    $c->flash->{error_msg} = "You can only create users for your site: $sitename";
                    $c->response->redirect($c->uri_for('/admin/create_user'));
                    return;
                }
            }
        }

        my $existing_user = $schema->resultset('User')->find({ email => $email });
        if ($existing_user) {
            $c->stash(
                error_msg => "A user with email '$email' already exists",
                template => 'admin/create_user.tt'
            );
            return;
        }

        eval {
            my $user = $schema->resultset('User')->create({
                first_name => $first_name,
                last_name => $last_name,
                email => $email,
                username => undef,
                password => undef,
                status => 'pending_setup',
                created_by => $c->session->{user_id},
                creation_context => 'admin_created',
                roles => 'normal',
            });

            my $user_verification = Comserv::Util::UserVerification->new();
            my $code = $user_verification->generate_verification_code();
            $user_verification->create_verification_code($user, $code);

            foreach my $site_name (@sitenames) {
                my $site_obj = $schema->resultset('Site')->search({ name => $site_name })->single;
                next unless $site_obj;
                foreach my $role_name (@roles) {
                    $schema->resultset('UserSiteRole')->create({
                        user_id    => $user->id,
                        site_id    => $site_obj->id,
                        role       => $role_name,
                        granted_by => $c->session->{user_id},
                    });
                }
            }

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_user',
                "Admin created user: $email with sites: " . join(',', @sitenames) . " roles: " . join(',', @roles));

            $c->session->{invitation_code} = $code;
            $c->session->{invitation_email} = $email;

            $c->flash->{success_msg} = "User invitation sent to $email. Verification code: $code (testing mode)";
            $c->response->redirect($c->uri_for('/admin/users'));
            return;
        };

        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_user',
                "Error creating user: $@");
            $c->stash(
                error_msg => "Error creating user: $@",
                template => 'admin/create_user.tt'
            );
            return;
        }
    }

    my @available_sites;
    if ($is_csc_admin) {
        @available_sites = $schema->resultset('Site')->search({}, { order_by => 'name' })->all;
    } else {
        @available_sites = $schema->resultset('Site')->search({ name => $sitename })->all;
    }

    my @available_roles = ('normal', 'editor', 'developer', 'WorkshopLeader', 'helpdesk', 'admin');

    $c->stash(
        available_sites => \@available_sites,
        available_roles => \@available_roles,
        is_csc_admin => $is_csc_admin,
        template => 'admin/create_user.tt',
    );
}

# Admin content management
sub content :Path('/admin/content') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'content', 
        "Starting content action");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'content')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }
    
    # Get filter parameter
    my $filter = $c->req->param('filter') || 'all';
    
    # Get search parameter
    my $search = $c->req->param('search') || '';
    
    # Get page parameter
    my $page = $c->req->param('page') || 1;
    my $items_per_page = 20;
    
    # Build search conditions
    my $search_conditions = {};
    
    # Apply filter
    if ($filter eq 'published') {
        $search_conditions->{status} = 'published';
    }
    elsif ($filter eq 'draft') {
        $search_conditions->{status} = 'draft';
    }
    elsif ($filter eq 'archived') {
        $search_conditions->{status} = 'archived';
    }
    
    # Apply search
    if ($search) {
        $search_conditions->{'-or'} = [
            { title => { 'like', "%$search%" } },
            { content => { 'like', "%$search%" } },
            { 'author.username' => { 'like', "%$search%" } }
        ];
    }
    
    # Get content from database
    my $content_rs = $c->model('DBEncy::Content')->search(
        $search_conditions,
        {
            join => 'author',
            order_by => { -desc => 'created_at' },
            page => $page,
            rows => $items_per_page
        }
    );
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Admin controller content view - Template: admin/content.tt";
        push @{$c->stash->{debug_msg}}, "Filter: $filter, Search: $search, Page: $page";
        push @{$c->stash->{debug_msg}}, "Content count: " . $content_rs->pager->total_entries;
    }
    
    # Pass data to the template
    $c->stash(
        template => 'admin/content.tt',
        content_items => [ $content_rs->all ],
        filter => $filter,
        search => $search,
        pager => $content_rs->pager
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'content', 
        "Completed content action");
}

# Admin settings
sub settings :Path('/admin/settings') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'settings', 
        "Starting settings action");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'settings')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }
    
    # Handle form submission
    if ($c->req->method eq 'POST') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'settings', 
            "Processing settings form submission");
        
        # Get form parameters
        my $site_name = $c->req->param('site_name');
        my $site_description = $c->req->param('site_description');
        my $admin_email = $c->req->param('admin_email');
        my $items_per_page = $c->req->param('items_per_page');
        my $allow_comments = $c->req->param('allow_comments') ? 1 : 0;
        my $moderate_comments = $c->req->param('moderate_comments') ? 1 : 0;
        my $theme = $c->req->param('theme');
        
        # Validate inputs
        my $errors = {};
        
        unless ($site_name) {
            $errors->{site_name} = "Site name is required";
        }
        
        unless ($admin_email && $admin_email =~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/) {
            $errors->{admin_email} = "Valid admin email is required";
        }
        
        unless ($items_per_page && $items_per_page =~ /^\d+$/ && $items_per_page > 0) {
            $errors->{items_per_page} = "Items per page must be a positive number";
        }
        
        # If there are validation errors, re-display the form
        if (%$errors) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'settings', 
                "Validation errors in settings form");
            
            $c->stash(
                template => 'admin/settings.tt',
                errors => $errors,
                form_data => {
                    site_name => $site_name,
                    site_description => $site_description,
                    admin_email => $admin_email,
                    items_per_page => $items_per_page,
                    allow_comments => $allow_comments,
                    moderate_comments => $moderate_comments,
                    theme => $theme
                }
            );
            return;
        }
        
        # Save settings to database
        eval {
            # Update site_name setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'site_name',
                    value => $site_name
                }
            );
            
            # Update site_description setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'site_description',
                    value => $site_description
                }
            );
            
            # Update admin_email setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'admin_email',
                    value => $admin_email
                }
            );
            
            # Update items_per_page setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'items_per_page',
                    value => $items_per_page
                }
            );
            
            # Update allow_comments setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'allow_comments',
                    value => $allow_comments
                }
            );
            
            # Update moderate_comments setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'moderate_comments',
                    value => $moderate_comments
                }
            );
            
            # Update theme setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'theme',
                    value => $theme
                }
            );
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'settings', 
                "Settings updated successfully");
            
            # Set success message and redirect
            $c->flash->{success_msg} = "Settings updated successfully";
            $c->response->redirect($c->uri_for('/admin/settings'));
            return;
        };
        
        # Handle database errors
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'settings', 
                "Error updating settings: $@");
            
            $c->stash(
                template => 'admin/settings.tt',
                error_msg => "Error updating settings: $@",
                form_data => {
                    site_name => $site_name,
                    site_description => $site_description,
                    admin_email => $admin_email,
                    items_per_page => $items_per_page,
                    allow_comments => $allow_comments,
                    moderate_comments => $moderate_comments,
                    theme => $theme
                }
            );
            return;
        }
    }
    
    # Get current settings from database
    my %settings = ();
    eval {
        my @setting_records = $c->model('DBEncy::Setting')->search({});
        foreach my $record (@setting_records) {
            $settings{$record->name} = $record->value;
        }
    };
    
    # Get available themes
    my @themes = ('default', 'dark', 'light', 'custom');
    eval {
        my $themes_dir = $c->path_to('root', 'static', 'themes');
        if (-d $themes_dir) {
            opendir(my $dh, $themes_dir) or die "Cannot open themes directory: $!";
            @themes = grep { -d "$themes_dir/$_" && $_ !~ /^\./ } readdir($dh);
            closedir($dh);
        }
    };
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Admin controller settings view - Template: admin/settings.tt";
        push @{$c->stash->{debug_msg}}, "Available themes: " . join(', ', @themes);
    }
    
    # Pass data to the template
    $c->stash(
        template => 'admin/settings.tt',
        settings => \%settings,
        themes => \@themes
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'settings', 
        "Completed settings action");
}

sub planning :Path('/admin/planning') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'planning',
        "Planning page requested by user=" . ($c->session->{user_id} // 'anon'));
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'planning')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }

    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $is_csc   = (uc($sitename) eq 'CSC') ? 1 : 0;

    my @all_db_projects;
    eval {
        my %cond = ();
        $cond{sitename} = $sitename unless $is_csc;
        @all_db_projects = $c->model('DBEncy')->resultset('Project')->search(
            \%cond, { order_by => 'id' }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'planning',
            "Could not fetch projects for planning: $@");
    }

    $c->stash(
        template          => 'admin/documentation/Planning.tt',
        planning_is_csc   => $is_csc,
        planning_sitename => $sitename,
        all_db_projects   => \@all_db_projects,
    );
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'planning',
        "Rendering admin/documentation/Planning.tt (is_csc=$is_csc sitename=$sitename projects=" . scalar(@all_db_projects) . ")");
    $c->forward($c->view('TT'));
}

# Admin system information
sub system_info :Path('/admin/system_info') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'system_info', 
        "Starting system_info action");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'system_info')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }
    
    my $host_ip = $c->req->param('host') // '';
    my $filter_hours = int($c->req->param('hours') || 24);
    $filter_hours = 1   if $filter_hours < 1;
    $filter_hours = 168 if $filter_hours > 168;

    my $system_info = $self->get_detailed_system_info($c);
    my $remote_servers = $self->get_remote_server_stats($c);
    my $selected_server;
    if ($host_ip) {
        ($selected_server) = grep { $_->{ip} eq $host_ip } @$remote_servers;
    }

    my $hw_target  = $selected_server || 'local';
    my $hw_history = $self->get_hardware_metrics_history($c, $hw_target, $filter_hours);
    my $view_label = $selected_server
        ? ($selected_server->{label} // $host_ip)
        : 'This host';

    my $app_disk = eval { Comserv::Util::DiskStats->app_disk_stats($c) };
    my $nfs_disk = eval { Comserv::Util::DiskStats->nfs_disk_stats($c) };
    my $perl_envs = $self->_perl_environments();

    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Admin controller system_info view - Template: admin/system_info.tt";
    }
    
    $c->stash(
        template          => 'admin/system_info.tt',
        system_info       => $system_info,
        remote_servers    => $remote_servers,
        selected_server   => $selected_server,
        selected_host_ip  => $host_ip,
        app_disk          => $app_disk,
        nfs_disk          => $nfs_disk,
        ingest_url        => $self->_hw_ingest_url($c),
        ingest_token      => ($ENV{HW_INGEST_TOKEN} // 'changeme'),
        filter_hours      => $filter_hours,
        view_label        => $view_label,
        chart_data_json   => ($hw_history->{chart_data_json} || '[]'),
        history_metrics   => ($hw_history->{metrics} || []),
        history_count     => ($hw_history->{history_count} || 0),
        hw_db_error       => ($hw_history->{db_error} || ''),
        perl_envs         => $perl_envs,
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'system_info', 
        "Completed system_info action");
}

# POST/GET /admin/install_hardware_agent?ip=192.168.1.20
sub install_hardware_agent :Path('/admin/install_hardware_agent') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'install_hardware_agent')) {
        $c->response->status(403);
        $c->response->content_type('application/json');
        $c->response->body(encode_json({ success => \0, error => 'Access denied' }));
        return;
    }

    my $ip = $c->req->param('ip') || '';
    my $srv = _monitored_server_by_ip($ip);
    unless ($srv) {
        $c->response->content_type('application/json');
        $c->response->body(encode_json({ success => \0, error => "Unknown server IP: $ip" }));
        return;
    }

    my $script = File::Spec->catfile($c->config->{home}, '..', 'script', 'device_agent.sh');
    $script = File::Spec->catfile($c->config->{home}, 'script', 'device_agent.sh') unless -f $script;
    unless (-f $script) {
        $c->response->content_type('application/json');
        $c->response->body(encode_json({ success => \0, error => 'device_agent.sh not found' }));
        return;
    }

    open my $sf, '<', $script or do {
        $c->response->content_type('application/json');
        $c->response->body(encode_json({ success => \0, error => "Cannot read $script" }));
        return;
    };
    local $/;
    my $script_body = <$sf>;
    close $sf;
    my $b64 = MIME::Base64::encode_base64($script_body, '');

    my $ingest_url = $srv->{ingest_url} || $self->_hw_ingest_url($c);
    my $ingest_token = $ENV{HW_INGEST_TOKEN} // 'changeme';
    my $hostname_override = $srv->{hostname_override} || $srv->{ip};
    my $ssh_target = $srv->{ssh_alias} || $srv->{ip};
    my ($ssh_host, $ssh_user) = $self->_resolve_ssh_target($ssh_target);
    my @users = grep { defined && length } ($srv->{ssh_user}, $ssh_user, 'ubuntu', 'root');
    my %seen_u;
    @users = grep { !$seen_u{$_}++ } @users;

    my ($output, $exit, $ssh_user_used) = ('', 1, '');
    for my $try_user (@users) {
        ($output, $exit) = $self->_install_device_agent_via_ssh(
            $ssh_host, $try_user, $b64, $ingest_url, $ingest_token, $hostname_override,
        );
        $ssh_user_used = $try_user;
        last if $exit == 0;
        last unless $output =~ /Permission denied \(publickey|Authentication failed|Could not authenticate|sshpass:.*(denied|incorrect|failure)/i;
    }

    $c->response->content_type('application/json');
    $c->response->body(encode_json({
        success           => $exit == 0 ? \1 : \0,
        output            => $output,
        exit_code         => $exit,
        ip                => $ip,
        ssh_user          => $ssh_user_used,
        hostname_override => $hostname_override,
        ingest_url        => $ingest_url,
    }));
}

# Get detailed system information
sub get_detailed_system_info {
    my ($self, $c) = @_;
    
    my $info = {
        perl_version => $],
        catalyst_version => $Catalyst::VERSION,
        server_software => $ENV{SERVER_SOFTWARE} || 'Unknown',
        server_name => $ENV{SERVER_NAME} || 'Unknown',
        server_protocol => $ENV{SERVER_PROTOCOL} || 'Unknown',
        server_admin => $ENV{SERVER_ADMIN} || 'Unknown',
        server_port => $ENV{SERVER_PORT} || 'Unknown',
        document_root => $ENV{DOCUMENT_ROOT} || 'Unknown',
        script_name => $ENV{SCRIPT_NAME} || 'Unknown',
        request_uri => $ENV{REQUEST_URI} || 'Unknown',
        request_method => $ENV{REQUEST_METHOD} || 'Unknown',
        query_string => $ENV{QUERY_STRING} || 'Unknown',
        remote_addr => $ENV{REMOTE_ADDR} || 'Unknown',
        remote_port => $ENV{REMOTE_PORT} || 'Unknown',
        remote_user => $ENV{REMOTE_USER} || 'Unknown',
        http_user_agent => $ENV{HTTP_USER_AGENT} || 'Unknown',
        http_referer => $ENV{HTTP_REFERER} || 'Unknown',
        http_accept => $ENV{HTTP_ACCEPT} || 'Unknown',
        http_accept_language => $ENV{HTTP_ACCEPT_LANGUAGE} || 'Unknown',
        http_accept_encoding => $ENV{HTTP_ACCEPT_ENCODING} || 'Unknown',
        http_connection => $ENV{HTTP_CONNECTION} || 'Unknown',
        http_host => $ENV{HTTP_HOST} || 'Unknown',
        https => $ENV{HTTPS} || 'Off',
        gateway_interface => $ENV{GATEWAY_INTERFACE} || 'Unknown',
        server_signature => $ENV{SERVER_SIGNATURE} || 'Unknown',
        server_addr => $ENV{SERVER_ADDR} || 'Unknown',
        path => $ENV{PATH} || 'Unknown',
        system_uptime => 'Unknown',
        system_load => 'Unknown',
        memory_usage => 'Unknown',
        disk_usage => 'Unknown',
        database_info => 'Unknown',
        installed_modules => []
    };
    
    # Get system uptime
    eval {
        my $uptime_output = `uptime`;
        chomp($uptime_output);
        $info->{system_uptime} = $uptime_output;
        
        if ($uptime_output =~ /load average: ([\d.]+), ([\d.]+), ([\d.]+)/) {
            $info->{system_load} = "$1 (1 min), $2 (5 min), $3 (15 min)";
        }
    };
    
    # Get memory usage
    eval {
        my $free_output = `free -h`;
        my @lines = split(/\n/, $free_output);
        if ($lines[1] =~ /Mem:\s+(\S+)\s+(\S+)\s+(\S+)/) {
            $info->{memory_usage} = "Total: $1, Used: $2, Free: $3";
        }
    };
    
    # Get disk usage
    eval {
        my $df_output = `df -h .`;
        my @lines = split(/\n/, $df_output);
        if ($lines[1] =~ /(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/) {
            $info->{disk_usage} = "Filesystem: $1, Size: $2, Used: $3, Avail: $4, Use%: $5, Mounted on: $6";
        }
    };
    
    # Get database information
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $db_info = $dbh->get_info(17); # SQL_DBMS_NAME
        my $db_version = $dbh->get_info(18); # SQL_DBMS_VER
        $info->{database_info} = "$db_info version $db_version";
    };
    
    $info->{perl_executable} = $^X || 'perl';
    my @loaded = @{ _perl_loaded_modules() };
    $info->{loaded_modules}    = \@loaded;
    $info->{installed_modules} = \@loaded;    # legacy stash key

    return $info;
}

# Admin logs viewer
sub logs :Path('/admin/logs') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logs', 
        "Starting logs action");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'logs')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }
    
    # Get log file parameter — sanitize to basename only, no path traversal
    my $log_file_raw = $c->req->param('file') || 'catalyst.log';
    (my $log_file = $log_file_raw) =~ s{[/\\]}{}g;
    $log_file =~ s/\.\.\///g;
    $log_file = 'catalyst.log' unless $log_file =~ /^[\w.\-]+\.log$/;

    # Get available log files
    my @log_files = ();
    eval {
        my $logs_dir = $c->path_to('logs');
        if (-d $logs_dir) {
            opendir(my $dh, $logs_dir) or die "Cannot open logs directory: $!";
            @log_files = grep { -f "$logs_dir/$_" && $_ !~ /^\./ } readdir($dh);
            closedir($dh);
        }
    };

    # Validate that the requested file is actually in the list
    my %valid_files = map { $_ => 1 } @log_files;
    $log_file = 'catalyst.log' unless $valid_files{$log_file};

    # Get log content
    my $log_content = '';
    eval {
        my $log_path = $c->path_to('logs', $log_file);
        if (-f $log_path) {
            # Read last 1000 lines without shell interpolation
            open(my $fh, '<', $log_path) or die "Cannot open log: $!";
            my @lines = <$fh>;
            close $fh;
            my $start = @lines > 1000 ? @lines - 1000 : 0;
            $log_content = join('', @lines[$start..$#lines]);
        }
    };
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Admin controller logs view - Template: admin/logs.tt";
        push @{$c->stash->{debug_msg}}, "Log file: $log_file";
        push @{$c->stash->{debug_msg}}, "Available log files: " . join(', ', @log_files);
    }
    
    # Pass data to the template
    $c->stash(
        template => 'admin/logs.tt',
        log_file => $log_file,
        log_files => \@log_files,
        log_content => $log_content
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logs',
        "Completed logs action");
}

# Admin security scan
sub security_scan :Path('/admin/security-scan') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'security_scan',
        "Starting security_scan action");

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'security_scan')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }

    my @known_targets = (
        # ── Production public sites ─────────────────────────────────────────
        { label => 'PROD: coop.computersystemconsulting.ca (MCoop)', url => 'http://coop.computersystemconsulting.ca',  site => 'MCoop'      },
        { label => 'PROD: usbm.ca (USBM)',                           url => 'http://usbm.ca',                           site => 'USBM'       },
        { label => 'PROD: 3d.usbm.ca (3d)',                          url => 'http://3d.usbm.ca',                        site => '3d'         },
        { label => 'PROD: shamanbotanicals.ca (SB)',                  url => 'http://shamanbotanicals.ca',               site => 'SB'         },
        { label => 'PROD: ve7tit.com (VE7TIT)',                      url => 'http://ve7tit.com',                        site => 'VE7TIT'     },
        { label => 'PROD: weaverbeck.com (WeaverBeck)',              url => 'http://weaverbeck.com',                    site => 'WeaverBeck' },
        { label => 'PROD: altpowerstore.com',                        url => 'http://altpowerstore.com',                 site => 'none'       },
        # ── Dev main app (port 3001) — host selects site ────────────────────
        { label => 'DEV:3001 workstation.local (none)',              url => 'http://workstation.local:3001',            site => 'none'       },
        { label => 'DEV:3001 coop.workstation (MCoop)',              url => 'http://coop.workstation:3001',             site => 'MCoop'      },
        { label => 'DEV:3001 usbm.local (USBM)',                     url => 'http://usbm.local:3001',                   site => 'USBM'       },
        { label => 'DEV:3001 3d.local (3d)',                         url => 'http://3d.local:3001',                     site => '3d'         },
        { label => 'DEV:3001 bmaster.workstation (BMaster)',         url => 'http://bmaster.workstation:3001',          site => 'BMaster'    },
        { label => 'DEV:3001 ve7tit.local (VE7TIT)',                 url => 'http://ve7tit.local:3001',                 site => 'VE7TIT'     },
        # ── Docker prod (port 3000) ──────────────────────────────────────────
        { label => 'DOCKER:3000 workstation.local (none)',           url => 'http://workstation.local:3000',            site => 'none'       },
        { label => 'DOCKER:3000 coop.workstation (MCoop)',           url => 'http://coop.workstation:3000',             site => 'MCoop'      },
        { label => 'DOCKER:3000 usbm.local (USBM)',                  url => 'http://usbm.local:3000',                   site => 'USBM'       },
        # ── Docker dev (port 5000) ───────────────────────────────────────────
        { label => 'DOCKER:5000 workstation.local (none)',           url => 'http://workstation.local:5000',            site => 'none'       },
        { label => 'DOCKER:5000 usbm.local (USBM)',                  url => 'http://usbm.local:5000',                   site => 'USBM'       },
        # ── Worktrees from planning (port 4000–4021) ─────────────────────────
        { label => 'WT:4001 PlanningSystem',                         url => 'http://workstation.local:4001',            site => 'none'       },
        { label => 'WT:4002 SchemaManagement',                       url => 'http://workstation.local:4002',            site => 'none'       },
        { label => 'WT:4003 InfrastructureHA',                       url => 'http://workstation.local:4003',            site => 'none'       },
        { label => 'WT:4004 WorkShops',                              url => 'http://workstation.local:4004',            site => 'none'       },
        { label => 'WT:4005 Users',                                  url => 'http://workstation.local:4005',            site => 'none'       },
        { label => 'WT:4006 FileManagement',                         url => 'http://workstation.local:4006',            site => 'none'       },
        { label => 'WT:4007 UnifiedMail',                            url => 'http://workstation.local:4007',            site => 'none'       },
        { label => 'WT:4008 Membership',                             url => 'http://workstation.local:4008',            site => 'none'       },
        { label => 'WT:4009 PointSystem',                            url => 'http://workstation.local:4009',            site => 'none'       },
        { label => 'WT:4010 AIChatSystem',                           url => 'http://workstation.local:4010',            site => 'none'       },
        { label => 'WT:4011 CssThemes',                              url => 'http://workstation.local:4011',            site => 'none'       },
        { label => 'WT:4012 ENCY',                                   url => 'http://workstation.local:4012',            site => 'none'       },
        { label => 'WT:4013 HelpDesk',                               url => 'http://workstation.local:4013',            site => 'none'       },
        { label => 'WT:4014 HealthPlanning',                         url => 'http://workstation.local:4014',            site => 'none'       },
        { label => 'WT:4015 ProdServerHealth',                       url => 'http://workstation.local:4015',            site => 'none'       },
        { label => 'WT:4016 Security',                               url => 'http://workstation.local:4016',            site => 'none'       },
        { label => 'WT:4017 Documentation',                          url => 'http://workstation.local:4017',            site => 'none'       },
        { label => 'WT:4018 APISystem',                              url => 'http://workstation.local:4018',            site => 'none'       },
        { label => 'WT:4019 BMaster',                                url => 'http://workstation.local:4019',            site => 'none'       },
        { label => 'WT:4020 AIChatPlanInt',                          url => 'http://workstation.local:4020',            site => 'none'       },
        { label => 'WT:4021 Inventory',                              url => 'http://workstation.local:4021',            site => 'none'       },
    );

    my $scan_results = undef;
    my $scan_output  = '';
    my $scan_error   = '';

    if ($c->req->method eq 'POST') {
        my $target_url = $c->req->param('target_url') // '';
        my $site_name  = $c->req->param('site_name')  // 'none';
        my $max_pages  = $c->req->param('max_pages')  // 100;

        # Sanitize inputs
        $target_url =~ s/\s+//g;
        $site_name  =~ s/[^a-zA-Z0-9._-]//g;
        $max_pages  = int($max_pages);
        $max_pages  = 50  if $max_pages < 1;
        $max_pages  = 500 if $max_pages > 500;

        unless ($target_url =~ m{^https?://[\w.\-]+(:\d+)?(/.*)?$}) {
            $c->stash->{error_msg} = 'Invalid target URL. Must be http:// or https:// with a hostname.';
            $c->stash(template => 'admin/security_scan.tt', known_targets => \@known_targets);
            return;
        }

        my $report_file = File::Spec->catfile($c->path_to(''), 'security_crawl_report.json');
        my $script      = File::Spec->catfile($c->path_to('script'), 'security_crawl.pl');

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'security_scan',
            "Running security scan: url=$target_url site=$site_name max=$max_pages");

        eval {
            open(my $pipe, '-|',
                'perl', $script,
                '--url',    $target_url,
                '--site',   $site_name,
                '--max',    $max_pages,
                '--output', $report_file,
            ) or die "Cannot run scan script: $!";
            while (my $line = <$pipe>) {
                $scan_output .= $line;
            }
            close($pipe);
        };
        if ($@) {
            $scan_error = $@;
        }

        if (-f $report_file) {
            eval {
                my $json_text = do { local $/; open(my $fh, '<', $report_file) or die $!; <$fh> };
                $scan_results = decode_json($json_text);
            };
            $scan_error .= $@ if $@;
        }

        $c->stash(
            scan_target  => $target_url,
            scan_site    => $site_name,
            scan_output  => $scan_output,
            scan_error   => $scan_error,
            scan_results => $scan_results,
        );
    }

    $c->stash(
        template      => 'admin/security_scan.tt',
        known_targets => \@known_targets,
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'security_scan',
        "Completed security_scan action");
}

# Security scan — start background scan (POST), returns JSON immediately
sub security_scan_start :Path('/admin/security-scan-start') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'security_scan_start')) {
        $c->response->status(403);
        $c->response->body(encode_json({ error => 'Access denied' }));
        return;
    }

    my $target_url = $c->req->param('target_url') // '';
    my $site_name  = $c->req->param('site_name')  // 'none';
    my $max_pages  = $c->req->param('max_pages')  // 100;
    my $use_auth   = $c->req->param('use_auth')   // 0;

    $target_url =~ s/\s+//g;
    $site_name  =~ s/[^a-zA-Z0-9._-]//g;
    $max_pages  = int($max_pages);
    $max_pages  = 50  if $max_pages < 1;
    $max_pages  = 500 if $max_pages > 500;

    unless ($target_url =~ m{^https?://[\w.\-]+(:\d+)?(/.*)?$}) {
        $c->response->body(encode_json({ error => 'Invalid URL' }));
        return;
    }

    # When authenticated mode is requested, forward the caller's Cookie header
    # to the scan script so it runs as the current logged-in user.
    my $auth_cookie = '';
    if ($use_auth) {
        $auth_cookie = $c->req->header('Cookie') // '';
        $auth_cookie =~ s/[\r\n]//g;  # strip any newlines (header injection guard)
    }

    my $out_file  = '/tmp/comserv_security_scan.txt';
    my $json_file = '/tmp/comserv_security_scan.json';
    my $script    = File::Spec->catfile($c->path_to('script'), 'security_crawl.pl');

    unlink $out_file, $json_file;

    my $pid = fork();
    if (!defined $pid) {
        $c->response->body(encode_json({ error => "fork failed: $!" }));
        return;
    }

    if ($pid == 0) {
        open(STDOUT, '>', $out_file) or exit 1;
        open(STDERR, '>&STDOUT');
        my @cmd = ('perl', $script,
            '--url',    $target_url,
            '--site',   $site_name,
            '--max',    $max_pages,
            '--output', $json_file,
        );
        push @cmd, '--auth-cookie', $auth_cookie if $auth_cookie;
        exec(@cmd);
        exit 1;
    }

    # Reap child automatically so it doesn't become a zombie
    local $SIG{CHLD} = 'IGNORE';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'security_scan_start',
        "Started background scan pid=$pid url=$target_url site=$site_name max=$max_pages auth=" . ($auth_cookie ? 'yes' : 'no'));

    $c->response->body(encode_json({ started => 1, pid => $pid, auth_mode => $auth_cookie ? 1 : 0 }));
}

# Security scan — poll for new output lines (GET)
sub security_scan_poll :Path('/admin/security-scan-poll') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'security_scan_poll')) {
        $c->response->status(403);
        $c->response->body(encode_json({ error => 'Access denied' }));
        return;
    }

    my $offset    = int($c->req->param('offset') // 0);
    my $out_file  = '/tmp/comserv_security_scan.txt';
    my $json_file = '/tmp/comserv_security_scan.json';

    my @new_lines;
    my $new_offset = $offset;

    if (-f $out_file) {
        open(my $fh, '<', $out_file);
        seek($fh, $offset, 0);
        while (my $line = <$fh>) {
            chomp $line;
            $line =~ s/\r//g;
            push @new_lines, $line;
        }
        $new_offset = tell($fh);
        close($fh);
    }

    my $done    = 0;
    my $results = undef;

    if (-f $out_file) {
        my $content = '';
        if (open(my $f, '<', $out_file)) { local $/; $content = <$f> // ''; close($f); }
        if ($content =~ /Full report written/) {
            $done = 1;
            if (-f $json_file) {
                eval {
                    my $jt = do { local $/; open(my $f, '<', $json_file) or die; <$f> };
                    $results = decode_json($jt);
                };
            }
        }
    }

    my %resp = (lines => \@new_lines, offset => $new_offset, done => $done);
    if ($done && $results) {
        $resp{results} = $results;
        # Return the archive file that was written (last one in the archive dir)
        my $archive_dir = $c->path_to('logs', 'security_scans');
        if (-d $archive_dir) {
            my @files = sort glob("$archive_dir/*.json");
            $resp{archive_file} = $files[-1] if @files;
        }
    }
    $c->response->body(encode_json(\%resp));
}

# Security scan — list archived scan reports (GET, returns JSON)
sub security_scan_history :Path('/admin/security-scan-history') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'security_scan_history')) {
        $c->response->status(403);
        $c->response->body(encode_json({ error => 'Access denied' }));
        return;
    }

    my $archive_dir = $c->path_to('logs', 'security_scans');
    my @scans;

    if (-d $archive_dir) {
        for my $file (reverse sort glob("$archive_dir/*.json")) {
            my $name = $file; $name =~ s|.*/||;
            my $size = -s $file;
            my $mtime = (stat $file)[9];
            eval {
                my $json_text = do { local $/; open(my $f, '<', $file) or die; <$f> };
                my $data = decode_json($json_text);
                push @scans, {
                    file      => $name,
                    scan_time => $data->{scan_time} // '',
                    base_url  => $data->{base_url}  // '',
                    sitename  => $data->{sitename}  // '',
                    summary   => $data->{summary}   // {},
                    size      => $size,
                };
            };
            push @scans, { file => $name, size => $size, error => $@ } if $@;
        }
    }

    $c->response->body(encode_json({ scans => \@scans }));
}

# Security scan — load a specific archived report (GET, returns JSON)
sub security_scan_load :Path('/admin/security-scan-load') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'security_scan_load')) {
        $c->response->status(403);
        $c->response->body(encode_json({ error => 'Access denied' }));
        return;
    }

    my $file = $c->req->param('file') // '';
    $file =~ s|[^a-zA-Z0-9._-]||g;

    unless ($file =~ /\.json$/) {
        $c->response->body(encode_json({ error => 'Invalid file name' }));
        return;
    }

    my $archive_dir = $c->path_to('logs', 'security_scans');
    my $path = "$archive_dir/$file";

    unless (-f $path) {
        $c->response->body(encode_json({ error => 'File not found' }));
        return;
    }

    eval {
        my $json_text = do { local $/; open(my $f, '<', $path) or die $!; <$f> };
        my $data = decode_json($json_text);
        $c->response->body(encode_json($data));
    };
    if ($@) {
        $c->response->body(encode_json({ error => "Cannot read file: $@" }));
    }
}

# Security scan — create todos from a scan archive (POST, returns JSON)
sub security_scan_create_todos :Path('/admin/security-scan-create-todos') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'security_scan_create_todos')) {
        $c->response->status(403);
        $c->response->body(encode_json({ error => 'Access denied' }));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->status(405);
        $c->response->body(encode_json({ error => 'POST required' }));
        return;
    }

    my $file = $c->req->param('file') // '';
    $file =~ s|[^a-zA-Z0-9._-]||g;

    my $data;
    if ($file && $file =~ /\.json$/) {
        my $path = $c->path_to('logs', 'security_scans', $file);
        unless (-f $path) {
            $c->response->body(encode_json({ error => "File not found: $file" }));
            return;
        }
        eval {
            my $json_text = do { local $/; open(my $f, '<', $path) or die $!; <$f> };
            $data = decode_json($json_text);
        };
        if ($@) {
            $c->response->body(encode_json({ error => "Cannot read file: $@" }));
            return;
        }
    } else {
        my $live = '/tmp/comserv_security_scan.json';
        unless (-f $live) {
            $c->response->body(encode_json({ error => 'No scan results available. Run a scan first.' }));
            return;
        }
        eval {
            my $json_text = do { local $/; open(my $f, '<', $live) or die $!; <$f> };
            $data = decode_json($json_text);
        };
        if ($@) {
            $c->response->body(encode_json({ error => "Cannot read live scan: $@" }));
            return;
        }
    }

    my $findings  = $data->{findings} // [];
    my $sitename  = $data->{sitename} // 'none';
    my $scan_url  = $data->{base_url} // '';
    my $scan_time = $data->{scan_time} // '';

    my $schema    = $c->model('DBEncy');
    my $todo_rs   = $schema->resultset('Todo');
    my $today     = DateTime->now->ymd;
    my $due       = DateTime->now->add(days => 14)->ymd;
    my $poster    = $c->session->{username} // 'security_scan';

    # Priority map: critical findings get priority 1, broken links get priority 3
    my %priority_for = (
        EXPOSED_SENSITIVE    => 1,
        EXPOSED_POST_ACCEPTED => 1,
        LEAK_STACK_TRACE     => 1,
        SERVER_ERROR         => 2,
        NOT_FOUND            => 3,
    );

    my $created = 0;
    my $skipped = 0;
    my @created_subjects;

    for my $f (@$findings) {
        my $result   = $f->{result} // '';
        my $url      = $f->{url}    // '';
        my $from_url = $f->{from_url} // '';
        my $phase    = $f->{phase}  // '';

        next unless $result && $url;

        # Only create todos for actionable findings
        my $is_security = ($result =~ /^EXPOSED|LEAK_STACK_TRACE/);
        my $is_broken   = ($result eq 'NOT_FOUND' && $phase eq 'crawl' && $from_url);
        next unless ($is_security || $is_broken);

        # Build subject (max 240 chars)
        my $path = $url; $path =~ s|^\Q$scan_url\E||; $path ||= $url;
        my $subject;
        if ($is_broken) {
            my $from_path = $from_url; $from_path =~ s|^\Q$scan_url\E||; $from_path ||= $from_url;
            $subject = "Dead link: $path (on $from_path)";
        } else {
            $subject = "Security [$result]: $path";
        }
        $subject = substr($subject, 0, 240) if length($subject) > 240;

        # Skip if an open todo with the same subject already exists for this site
        my $existing = $todo_rs->search({
            sitename => $sitename,
            subject  => $subject,
            status   => { -not_in => ['Delivered', 'Cancelled'] },
        })->first;
        if ($existing) {
            $skipped++;
            next;
        }

        my $priority = $priority_for{$result} // 2;
        my $description = $is_broken
            ? "Dead link found by security crawler on $scan_time.\nURL: $url\nFound on page: $from_url\nScan target: $scan_url"
            : "Security finding from crawler on $scan_time.\nResult: $result\nURL: $url\nPhase: $phase\nScan target: $scan_url"
                . ($f->{snippet} ? "\n\nSnippet:\n" . $f->{snippet} : '');

        eval {
            $todo_rs->create({
                sitename            => $sitename,
                subject             => $subject,
                description         => $description,
                status              => 'Requested',
                priority            => $priority,
                start_date          => $today,
                due_date            => $due,
                reporter            => 'security_scan',
                username_of_poster  => $poster,
                group_of_poster     => 'admin',
                project_code        => 'security',
                last_mod_by         => $poster,
                last_mod_date       => $today,
                date_time_posted    => $today,
                share               => 0,
                user_id             => 0,
                project_id          => 0,
            });
            $created++;
            push @created_subjects, $subject;
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'security_scan_create_todos', "Failed to create todo for $url: $@");
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'security_scan_create_todos',
        "Created $created todos, skipped $skipped duplicates from scan: $scan_url");

    $c->response->body(encode_json({
        created  => $created,
        skipped  => $skipped,
        subjects => \@created_subjects,
    }));
}

# Admin backup and restore
sub backup :Path('/admin/backup') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
        "Starting backup action");

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'backup')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }

    # Handle backup creation
    if ($c->req->method eq 'POST' && $c->req->param('action') eq 'create_backup') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
            "Creating backup");

        my $backup_type = $c->req->param('backup_type') || 'full';
        my $backup_name = $c->req->param('backup_name') || 'backup_' . time();

        # Create backup directory if it doesn't exist
        my $backup_dir = $c->path_to('backups');
        unless (-d $backup_dir) {
            eval { make_path($backup_dir) };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup',
                    "Error creating backup directory: $@");

                $c->flash->{error_msg} = "Error creating backup directory: $@";
                $c->response->redirect($c->uri_for('/admin/backup'));
                return;
            }
        }

        # Create backup
        my $backup_file = "$backup_dir/$backup_name.tar.gz";
        my $backup_command = '';

        if ($backup_type eq 'full') {
            # Full backup (files + database)
            $backup_command = "tar -czf $backup_file --exclude='backups' --exclude='tmp' --exclude='logs/*.log' .";
        }
        elsif ($backup_type eq 'files') {
            # Files only backup
            $backup_command = "tar -czf $backup_file --exclude='backups' --exclude='tmp' --exclude='logs/*.log' --exclude='db' .";
        }
        elsif ($backup_type eq 'database') {
            # Database only backup
            # This is a simplified example - you'd need to customize for your database
            $backup_command = "mysqldump -u username -p'password' database_name > $backup_dir/db_dump.sql && tar -czf $backup_file $backup_dir/db_dump.sql && rm $backup_dir/db_dump.sql";
        }

        # Execute backup command
        my $result = system($backup_command);

        if ($result == 0) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
                "Backup created successfully: $backup_file");

            $c->flash->{success_msg} = "Backup created successfully: $backup_name.tar.gz";
        }
        else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup',
                "Error creating backup: $!");

            $c->flash->{error_msg} = "Error creating backup: $!";
        }

        $c->response->redirect($c->uri_for('/admin/backup'));
        return;
    }

    # Handle backup restoration
    if ($c->req->method eq 'POST' && $c->req->param('action') eq 'restore_backup') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
            "Restoring backup");

        my $backup_file = $c->req->param('backup_file');

        unless ($backup_file) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'backup',
                "No backup file selected for restoration");

            $c->flash->{error_msg} = "No backup file selected for restoration";
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }

        # Validate backup file
        my $backup_path = $c->path_to('backups', $backup_file);
        unless (-f $backup_path) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'backup',
                "Backup file not found: $backup_file");

            $c->flash->{error_msg} = "Backup file not found: $backup_file";
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }

        # Create temporary directory for restoration
        my $temp_dir = $c->path_to('tmp', 'restore_' . time());
        eval { make_path($temp_dir) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup',
                "Error creating temporary directory: $@");

            $c->flash->{error_msg} = "Error creating temporary directory: $@";
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }

        # Extract backup to temporary directory
        my $extract_command = "tar -xzf $backup_path -C $temp_dir";
        my $extract_result = system($extract_command);

        if ($extract_result != 0) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup',
                "Error extracting backup: $!");

            $c->flash->{error_msg} = "Error extracting backup: $!";
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }

        # Restore database if database dump exists
        if (-f "$temp_dir/db_dump.sql") {
            # This is a simplified example - you'd need to customize for your database
            my $db_restore_command = "mysql -u username -p'password' database_name < $temp_dir/db_dump.sql";
            my $db_restore_result = system($db_restore_command);

            if ($db_restore_result != 0) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup',
                    "Error restoring database: $!");

                $c->flash->{error_msg} = "Error restoring database: $!";
                $c->response->redirect($c->uri_for('/admin/backup'));
                return;
            }
        }

        # Restore files
        # This is a simplified example - you'd need to customize for your application
        my $files_restore_command = "cp -R $temp_dir/* .";
        my $files_restore_result = system($files_restore_command);

        if ($files_restore_result != 0) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup',
                "Error restoring files: $!");

            $c->flash->{error_msg} = "Error restoring files: $!";
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }

        # Clean up temporary directory
        my $cleanup_command = "rm -rf $temp_dir";
        system($cleanup_command);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
            "Backup restored successfully: $backup_file");

        $c->flash->{success_msg} = "Backup restored successfully: $backup_file";
        $c->response->redirect($c->uri_for('/admin/backup'));
        return;
    }

    # Get available backups
    my @backups = ();
    eval {
        my $backup_dir = $c->path_to('backups');
        if (-d $backup_dir) {
            opendir(my $dh, $backup_dir) or die "Cannot open backups directory: $!";
            @backups = grep { -f "$backup_dir/$_" && $_ =~ /\.tar\.gz$/ } readdir($dh);
            closedir($dh);

            # Sort backups by modification time (newest first)
            @backups = sort {
                (stat("$backup_dir/$b"))[9] <=> (stat("$backup_dir/$a"))[9]
            } @backups;
        }
    };

    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller backup view - Template: admin/backup.tt";
        push @{$c->stash->{debug_msg}}, "Available backups: " . join(', ', @backups);
    }

    # Pass data to the template
    $c->stash(
        template => 'admin/backup.tt',
        backups => \@backups
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
        "Completed backup action");
}

# Keeping it here for backward compatibility
sub mail :Path('/admin/mail') :Args(0) {
    my ($self, $c) = @_;
    $c->response->redirect($c->uri_for('/mail/mail_admin_dashboard'));
}

sub network_devices_forward :Path('/admin/network_devices_old') :Args(0) {
    my ($self, $c) = @_;

    # Redirect to the new network devices page
    $c->response->redirect($c->uri_for('/admin/network_devices'));
}

# Commented out to avoid redefinition - this functionality is now in Admin::NetworkDevices
# sub network_devices :Path('/admin/network_devices') :Args(0) {
#     # Implementation removed to avoid duplication
# }

# Commented out to avoid redefinition - this functionality is now in Admin::NetworkDevices
# sub add_network_device :Path('/admin/add_network_device') :Args(0) {
#     # Implementation removed to avoid duplication
# }

# Commented out to avoid redefinition - this functionality is now in Admin::NetworkDevices
# sub edit_network_device :Path('/admin/edit_network_device') :Args(1) {
#     # Implementation removed to avoid duplication
# }

# Commented out to avoid redefinition - this functionality is now in Admin::NetworkDevices
# sub delete_network_device :Path('/admin/delete_network_device') :Args(1) {
#     # Implementation removed to avoid duplication
# }

# Database Schema Comparison functionality (with alias)
sub compare_schema :Path('/admin/compare_schema') :Args(0) {
    my ($self, $c) = @_;
    $c->stash(template => 'admin/schema_compare.tt');
    $c->forward('schema_compare');
}

# Database Schema Comparison functionality
# schema_compare action has been moved to Admin/SchemaComparison.pm (refactor)
# Temporary redirect so existing links continue to work
sub schema_compare :Path('/admin/schema_compare') :Args(0) {
    my ($self, $c) = @_;
    $c->detach( $c->controller('Admin::SchemaComparison')->action_for('schema_compare') );
}

# AJAX endpoint to get table schema details
sub get_table_schema :Path('/admin/get_table_schema') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_table_schema', 
        "Starting get_table_schema action");
    
    # Check if the user has admin role - use session-based check
    my $has_admin_role = 0;
    if ($c->session->{username}) {
        if ($c->session->{username} eq 'Shanta') {
            $has_admin_role = 1;
        } else {
            my $roles = $c->session->{roles};
            if (ref($roles) eq 'ARRAY') {
                foreach my $role (@$roles) {
                    if (lc($role) eq 'admin') {
                        $has_admin_role = 1;
                        last;
                    }
                }
            } elsif (defined $roles && !ref($roles) && $roles =~ /\badmin\b/i) {
                $has_admin_role = 1;
            }
        }
    }
    
    unless ($has_admin_role) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    $table_name =~ s/[^a-zA-Z0-9_]//g if $table_name;
    $database   =~ s/[^a-zA-Z0-9_]//g if $database;

    unless ($table_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters' });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        my $schema_info;
        
        if ($database eq 'ency') {
            $schema_info = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $schema_info = $self->get_forager_table_schema($c, $table_name);
        } else {
            die "Invalid database: $database";
        }
        
        $c->stash(json => { 
            success => 1, 
            schema => $schema_info,
            table_name => $table_name,
            database => $database
        });
        
    } catch {
        my $error = "Error getting table schema: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_table_schema', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

# Get field comparison between table and Result file
sub get_field_comparison :Path('/admin/get_field_comparison') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison',
        "Starting get_field_comparison action");
    
    my $table_name = $c->request->param('table_name');
    my $database = $c->request->param('database');
    $table_name =~ s/[^a-zA-Z0-9_]//g if $table_name;
    $database   =~ s/[^a-zA-Z0-9_]//g if $database;

    unless ($table_name && $database) {
        $c->response->status(400);
        $c->stash(json => {
            success => 0,
            error => 'Missing table_name or database parameter'
        });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        # Build comprehensive mapping for this database
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        
        my $comparison = $self->get_table_result_comparison_v2($c, $table_name, $database, $result_table_mapping);
        
        # Add debugging information
        my $table_key = lc($table_name);
        my $result_info = $result_table_mapping->{$table_key};
        my $result_file_path = $result_info ? $result_info->{result_path} : undef;
        my $result_name = $result_info ? $result_info->{result_name} : 'NOT FOUND';
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison',
            "Table: $table_name, Database: $database, Result name: $result_name, Result file: " . ($result_file_path || 'NOT FOUND'));
        
        # Add detailed debugging
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison',
            "Comparison has_result_file: " . ($comparison->{has_result_file} ? 'YES' : 'NO'));
        
        if ($comparison->{fields}) {
            my $field_count = scalar(keys %{$comparison->{fields}});
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison',
                "Fields found: $field_count");
            
            # Log first few fields for debugging
            my $count = 0;
            foreach my $field_name (keys %{$comparison->{fields}}) {
                last if $count >= 3;
                my $field_data = $comparison->{fields}->{$field_name};
                my $has_table = $field_data->{table} ? 'YES' : 'NO';
                my $has_result = $field_data->{result} ? 'YES' : 'NO';
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison',
                    "Field '$field_name': Table=$has_table, Result=$has_result");
                $count++;
            }
        }
        
        $c->stash(json => {
            success => 1,
            comparison => $comparison,
            debug_mode => $c->session->{debug_mode} ? 1 : 0,
            debug => {
                table_name => $table_name,
                database => $database,
                result_name => $result_name,
                result_file_path => $result_file_path,
                has_result_file => $comparison->{has_result_file},
                total_result_files => scalar(keys %$result_table_mapping)
            }
        });
        
    } catch {
        my $error = "Error getting field comparison for $table_name ($database): $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_field_comparison', $error);
        
        $c->response->status(500);
        $c->stash(json => {
            success => 0,
            error => $error
        });
    };
    
    $c->forward('View::JSON');
}

# Get database comparison between each database and its result files
sub get_database_comparison {
    my ($self, $c) = @_;
    
    my $comparison = {
        ency => {
            name => 'ency',
            display_name => 'Encyclopedia Database',
            tables => [],
            table_count => 0,
            connection_status => 'unknown',
            error => undef,
            table_comparisons => [],
            results_without_tables => [],
        },
        forager => {
            name => 'forager',
            display_name => 'Forager Database',
            tables => [],
            table_count => 0,
            connection_status => 'unknown',
            error => undef,
            table_comparisons => [],
            results_without_tables => [],
        },
        migration_mysql => {
            name => 'migration_mysql',
            display_name => 'Migration Target — MySQL Server',
            connection_status => 'unknown',
            error => undef,
            databases => [],
            ency_schema => undef,
        },
        migration_postgres => {
            name => 'migration_postgres',
            display_name => 'New Server — PostgreSQL Docker (192.168.1.20:5433)',
            connection_status => 'unknown',
            error => undef,
            databases => []
        },
        summary => {
            total_databases => 4,
            connected_databases => 0,
            total_tables => 0,
            tables_with_results => 0,
            tables_without_results => 0,
            results_without_tables => 0
        }
    };
    
    # Get Ency database tables and compare with result files
    try {
        my $ency_tables = $self->get_ency_database_tables($c);
        @$ency_tables = sort { lc($a) cmp lc($b) } @$ency_tables;
        my $ency_comp = $self->build_schema_comparison_data($c, 'ency', $ency_tables);

        $comparison->{ency}->{tables} = $ency_tables;
        $comparison->{ency}->{table_count} = scalar(@$ency_tables);
        $comparison->{ency}->{connection_status} = 'connected';
        $comparison->{summary}->{connected_databases}++;
        $comparison->{summary}->{total_tables} += scalar(@$ency_tables);
        $comparison->{summary}->{tables_with_results}    += $ency_comp->{tables_with_results_count};
        $comparison->{summary}->{tables_without_results} += $ency_comp->{tables_without_results_count};
        $comparison->{summary}->{results_without_tables} += $ency_comp->{results_without_tables_count};
        $comparison->{ency}->{table_comparisons}      = $ency_comp->{table_comparisons};
        $comparison->{ency}->{results_without_tables} = $ency_comp->{results_without_tables};

    } catch {
        my $error = "Error connecting to ency database: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_database_comparison', $error);
        $comparison->{ency}->{connection_status} = 'error';
        $comparison->{ency}->{error} = $error;
    };
    
    # Get Forager database tables and compare with result files
    try {
        my $forager_tables = $self->get_forager_database_tables($c);
        @$forager_tables = sort { lc($a) cmp lc($b) } @$forager_tables;
        my $forager_comp = $self->build_schema_comparison_data($c, 'forager', $forager_tables);

        $comparison->{forager}->{tables} = $forager_tables;
        $comparison->{forager}->{table_count} = scalar(@$forager_tables);
        $comparison->{forager}->{connection_status} = 'connected';
        $comparison->{summary}->{connected_databases}++;
        $comparison->{summary}->{total_tables} += scalar(@$forager_tables);
        $comparison->{summary}->{tables_with_results}    += $forager_comp->{tables_with_results_count};
        $comparison->{summary}->{tables_without_results} += $forager_comp->{tables_without_results_count};
        $comparison->{summary}->{results_without_tables} += $forager_comp->{results_without_tables_count};
        $comparison->{forager}->{table_comparisons}      = $forager_comp->{table_comparisons};
        $comparison->{forager}->{results_without_tables} = $forager_comp->{results_without_tables};

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison',
            "Forager: " . scalar(@$forager_tables) . " tables, "
            . $forager_comp->{tables_with_results_count} . " with results, "
            . $forager_comp->{tables_without_results_count} . " without results, "
            . $forager_comp->{results_without_tables_count} . " orphaned results");

    } catch {
        my $error = "Error connecting to forager database: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_database_comparison', $error);
        $comparison->{forager}->{connection_status} = 'error';
        $comparison->{forager}->{error} = $error;
    };

    # Get migration target MySQL server info
    my $mysql_info = $self->get_migration_mysql_info($c);
    $comparison->{migration_mysql}->{connection_status} = $mysql_info->{connection_status};
    $comparison->{migration_mysql}->{error}             = $mysql_info->{error};
    $comparison->{migration_mysql}->{databases}         = $mysql_info->{databases} // [];
    $comparison->{migration_mysql}->{host}              = $mysql_info->{host};
    if ($mysql_info->{host}) {
        $comparison->{migration_mysql}->{display_name} = 'Migration Target — MySQL (' . $mysql_info->{host} . ')';
    }
    if ($mysql_info->{connection_status} eq 'connected') {
        $comparison->{summary}->{connected_databases}++;

        # Compare migration server's ency database against local Result files
        my ($ency_db) = grep { lc($_->{name}) eq 'ency' } @{ $mysql_info->{databases} // [] };
        if ($ency_db && $ency_db->{tables}) {
            my @migration_ency_tables = map { $_->{name} } @{ $ency_db->{tables} };
            @migration_ency_tables = sort { lc($a) cmp lc($b) } @migration_ency_tables;
            my $mig_comp = $self->build_schema_comparison_data($c, 'ency', \@migration_ency_tables);
            $comparison->{migration_mysql}->{ency_schema} = {
                database_name              => $ency_db->{name},
                table_count                => scalar(@migration_ency_tables),
                table_comparisons          => $mig_comp->{table_comparisons},
                results_without_tables     => $mig_comp->{results_without_tables},
                tables_with_results_count  => $mig_comp->{tables_with_results_count},
                tables_without_results_count => $mig_comp->{tables_without_results_count},
                results_without_tables_count => $mig_comp->{results_without_tables_count},
            };
        }
    }

    # Get migration target PostgreSQL server info
    my $pg_info = $self->get_migration_postgres_info($c);
    $comparison->{migration_postgres}->{connection_status} = $pg_info->{connection_status};
    $comparison->{migration_postgres}->{error}             = $pg_info->{error};
    $comparison->{migration_postgres}->{databases}         = $pg_info->{databases} // [];
    $comparison->{migration_postgres}->{host}              = $pg_info->{host};
    if ($pg_info->{connection_status} eq 'connected') {
        $comparison->{summary}->{connected_databases}++;
    }

    return $comparison;
}

# Compare a database table with its Result file
sub compare_table_with_result_file {
    my ($self, $c, $table_name, $database) = @_;
    
    my $result_name = $self->table_name_to_result_name($table_name);
    my $comparison = {
        table_name => $table_name,
        result_name => $result_name,
        database => $database,
        has_result_file => 0,
        result_file_path => undef,
        database_schema => {},
        result_file_schema => {},
        differences => [],
        sync_status => 'unknown',
        last_modified => undef
    };
    
    # Look for Result file
    my $result_file_path = $self->find_result_file($c, $table_name, $database);
    if ($result_file_path && -f $result_file_path) {
        $comparison->{has_result_file} = 1;
        $comparison->{result_file_path} = $result_file_path;
        $comparison->{last_modified} = (stat($result_file_path))[9];
        
        # Get database schema
        try {
            if ($database eq 'ency') {
                $comparison->{database_schema} = $self->get_ency_table_schema($c, $table_name);
            } elsif ($database eq 'forager') {
                $comparison->{database_schema} = $self->get_forager_table_schema($c, $table_name);
            }
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'compare_table_with_result_file', 
                "Error getting database schema for $table_name: $_");
        };
        
        # Parse Result file schema
        try {
            $comparison->{result_file_schema} = $self->parse_result_file_schema($c, $result_file_path);
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'compare_table_with_result_file', 
                "Error parsing Result file schema for $table_name: $_");
        };
        
        # Compare schemas and find differences
        $comparison->{differences} = $self->find_schema_differences(
            $comparison->{database_schema}, 
            $comparison->{result_file_schema}
        );
        
        # Determine sync status
        if (scalar(@{$comparison->{differences}}) == 0) {
            $comparison->{sync_status} = 'synchronized';
        } else {
            $comparison->{sync_status} = 'needs_sync';
        }
    } else {
        $comparison->{sync_status} = 'no_result_file';
    }
    
    return $comparison;
}

# Find Result file for a table
sub find_result_file {
    my ($self, $c, $table_name, $database) = @_;
    
    # Convert table name to proper case for Result file names
    my $result_name = $self->table_name_to_result_name($table_name);
    
    # Database-specific Result file locations to check
    my @search_paths;
    
    # Get the application root directory
    my $app_root = $c->config->{home} || '/home/shanta/PycharmProjects/comserv2';
    
    if (lc($database) eq 'ency') {
        # If the input looks like a subdirectory path (e.g., "Ency/ExternalID"),
        # also try a direct path match before falling back to computed result_name
        if ($table_name =~ m{/}) {
            my $direct = "$app_root/Comserv/lib/Comserv/Model/Schema/Ency/Result/${table_name}.pm";
            return $direct if -f $direct;
        }
        @search_paths = (
            "$app_root/Comserv/lib/Comserv/Model/Schema/Ency/Result/$result_name.pm",
            "$app_root/Comserv/lib/Comserv/Model/Schema/Ency/Result/Ency/$result_name.pm",
            "$app_root/Comserv/lib/Comserv/Model/Schema/Ency/Result/System/$result_name.pm",
            "$app_root/Comserv/lib/Comserv/Model/Schema/Ency/Result/User/$result_name.pm"
        );
    } elsif (lc($database) eq 'forager') {
        @search_paths = (
            "$app_root/Comserv/lib/Comserv/Model/Schema/Forager/Result/$result_name.pm"
        );
    } else {
        # Fallback for unknown databases
        @search_paths = (
            "$app_root/Comserv/lib/Comserv/Model/Schema/Result/$result_name.pm",
            "$app_root/Comserv/lib/Comserv/Schema/Result/$result_name.pm"
        );
    }
    
    foreach my $path (@search_paths) {
        if (-f $path) {
            return $path;
        }
    }
    
    return undef;
}

# Convert table name to Result class name
sub table_name_to_result_name {
    my ($self, $table_name) = @_;
    
    # Convert snake_case or lowercase to PascalCase
    # e.g., "user_group" -> "UserGroup", "ency_herb_tb" -> "Herb"
    
    # Handle database-specific table name patterns
    my $clean_name = $table_name;

    # Strip subdirectory prefix (e.g., "Ency/ExternalID" -> "ExternalID")
    # scan_result_directory_recursive uses "/" to denote subdirectory nesting
    if ($clean_name =~ m{^[A-Za-z][A-Za-z0-9]*/(.+)$}) {
        $clean_name = $1;
    }

    # Remove common prefixes
    $clean_name =~ s/^ency_//i;
    $clean_name =~ s/^forager_//i;
    
    # Remove common suffixes
    $clean_name =~ s/_tb$//i;
    $clean_name =~ s/_table$//i;
    
    # Handle special plurals and known mappings
    my %table_to_result = (
        'categories' => 'Category',
        'event' => 'Event',
        'files' => 'File',
        'groups' => 'Group',
        'internal_links_tb' => 'InternalLinksTb',
        'learned_data' => 'Learned_data',
        'log' => 'Log',
        'mail_domains' => 'MailDomain',
        'network_devices' => 'NetworkDevice',
        'page' => 'Page',
        'page_tb' => 'PageTb',
        'pallets' => 'Pallet',
        'participant' => 'Participant',
        'projects' => 'Project',
        'project_sites' => 'ProjectSite',
        'queens' => 'Queen',
        'reference' => 'Reference',
        'site_config' => 'SiteConfig',
        'sitedomain' => 'SiteDomain',
        'sites' => 'Site',
        'site_themes' => 'SiteTheme',
        'site_workshop' => 'SiteWorkshop',
        'themes' => 'Theme',
        'theme_variables' => 'ThemeVariable',
        'todo' => 'Todo',
        'user_groups' => 'UserGroup',
        'users' => 'User',
        'user_sites' => 'UserSite',
        'workshop' => 'WorkShop',
        'yards' => 'Yard',
        'ency_herb_tb' => 'Herb',
        'page' => 'Page'
    );
    
    # Check if it's a known mapping
    if (exists $table_to_result{lc($table_name)}) {
        return $table_to_result{lc($table_name)};
    }
    
    # Convert underscores to PascalCase
    my $result_name = join('', map { ucfirst(lc($_)) } split(/_/, $clean_name));
    
    return $result_name;
}

# Find Result files that don't have corresponding database tables
sub find_orphaned_result_files {
    my ($self, $c, $database, $existing_tables) = @_;
    
    my @orphaned_results = ();
    my %table_lookup = map { lc($_) => 1 } @$existing_tables;
    
    # Get all Result files for this database
    my @result_files = $self->get_all_result_files($database);
    
    foreach my $result_file (@result_files) {
        # Extract actual table name from Result file by reading the __PACKAGE__->table() declaration
        my $table_name = $self->extract_table_name_from_result_file($result_file->{path});
        
        # Skip if we couldn't extract table name
        next unless $table_name;
        
        # Check if corresponding table exists
        unless (exists $table_lookup{lc($table_name)}) {
            push @orphaned_results, {
                result_name => $result_file->{name},
                result_path => $result_file->{path},
                expected_table_name => $table_name,
                actual_table_name => $table_name,
                last_modified => $result_file->{last_modified}
            };
        }
    }
    
    return @orphaned_results;
}

# Extract table name from Result file by reading __PACKAGE__->table() declaration
sub extract_table_name_from_result_file {
    my ($self, $file_path) = @_;
    
    return undef unless -f $file_path;
    
    # Read the Result file
    my $content;
    eval {
        $content = File::Slurp::read_file($file_path);
    };
    if ($@) {
        warn "Failed to read Result file $file_path: $@";
        return undef;
    }
    
    # Extract table name from __PACKAGE__->table('table_name') declaration
    # Robust multiline regex to handle different formatting styles
    if ($content =~ /__PACKAGE__->table\s*\(\s*['"]([^'"]+)['"]\s*\)/s) {
        return $1;
    }
    
    return undef;
}

# Build the three-group schema comparison data for a table list + Result files
sub build_schema_comparison_data {
    my ($self, $c, $database, $table_names_ref) = @_;

    my $result_table_mapping = $self->build_result_table_mapping($c, $database);
    my @tables_with_results;
    my @tables_without_results;

    foreach my $table_name (@$table_names_ref) {
        my $table_comparison = $self->compare_table_with_result_file_v2(
            $c, $table_name, $database, $result_table_mapping
        );
        if ($table_comparison->{has_result_file}) {
            push @tables_with_results, $table_comparison;
        } else {
            push @tables_without_results, $table_comparison;
        }
    }

    my @results_without_tables = sort {
        lc($a->{result_name}) cmp lc($b->{result_name})
    } $self->find_orphaned_result_files_v2($c, $database, $table_names_ref, $result_table_mapping);

    @tables_with_results    = sort { lc($a->{table_name}) cmp lc($b->{table_name}) } @tables_with_results;
    @tables_without_results = sort { lc($a->{table_name}) cmp lc($b->{table_name}) } @tables_without_results;

    return {
        table_comparisons            => [ @tables_with_results, @tables_without_results ],
        results_without_tables       => \@results_without_tables,
        tables_with_results_count    => scalar(@tables_with_results),
        tables_without_results_count => scalar(@tables_without_results),
        results_without_tables_count => scalar(@results_without_tables),
    };
}

# Build comprehensive mapping of result files to their actual table names
sub build_result_table_mapping {
    my ($self, $c, $database) = @_;
    
    my %mapping = ();  # table_name => { result_name => ..., result_path => ... }
    
    # Get all Result files for this database
    my @result_files = $self->get_all_result_files($database);
    
    foreach my $result_file (@result_files) {
        # Extract actual table name from Result file
        my $table_name = $self->extract_table_name_from_result_file($result_file->{path});
        
        if ($table_name) {
            $mapping{lc($table_name)} = {
                result_name => $result_file->{name},
                result_path => $result_file->{path},
                last_modified => $result_file->{last_modified}
            };
        }
    }
    
    return \%mapping;
}

# Compare table with result file using the comprehensive mapping
sub compare_table_with_result_file_v2 {
    my ($self, $c, $table_name, $database, $result_table_mapping) = @_;
    
    my $comparison = {
        table_name => $table_name,
        database => $database,
        has_result_file => 0,
        result_file_path => undef,
        database_schema => {},
        result_file_schema => {},
        differences => [],
        sync_status => 'unknown',
        last_modified => undef
    };
    
    # Check if this table has a corresponding result file
    my $table_key = lc($table_name);
    if (exists $result_table_mapping->{$table_key}) {
        my $result_info = $result_table_mapping->{$table_key};
        
        $comparison->{has_result_file} = 1;
        $comparison->{result_file_path} = $result_info->{result_path};
        $comparison->{last_modified} = $result_info->{last_modified};
        
        # Get database schema
        try {
            if ($database eq 'ency') {
                $comparison->{database_schema} = $self->get_ency_table_schema($c, $table_name);
            } elsif ($database eq 'forager') {
                $comparison->{database_schema} = $self->get_forager_table_schema($c, $table_name);
            }
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'compare_table_with_result_file_v2', 
                "Error getting database schema for $table_name: $_");
        };
        
        # Parse Result file schema
        try {
            $comparison->{result_file_schema} = $self->parse_result_file_schema($c, $result_info->{result_path});
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'compare_table_with_result_file_v2', 
                "Error parsing Result file schema for $table_name: $_");
        };
        
        # Compare schemas and find differences
        $comparison->{differences} = $self->find_schema_differences(
            $comparison->{database_schema}, 
            $comparison->{result_file_schema}
        );
        
        # Determine sync status
        if (scalar(@{$comparison->{differences}}) == 0) {
            $comparison->{sync_status} = 'synchronized';
        } else {
            $comparison->{sync_status} = 'needs_sync';
        }
    } else {
        $comparison->{sync_status} = 'no_result_file';
    }
    
    return $comparison;
}

# Find result files without corresponding tables using the comprehensive mapping
sub find_orphaned_result_files_v2 {
    my ($self, $c, $database, $existing_tables, $result_table_mapping) = @_;
    
    my @orphaned_results = ();
    my %table_lookup = map { lc($_) => 1 } @$existing_tables;
    
    # Check each result file to see if its table exists
    foreach my $table_name (keys %$result_table_mapping) {
        unless (exists $table_lookup{$table_name}) {
            my $result_info = $result_table_mapping->{$table_name};
            
            # Extract schema information for orphaned results
            my $result_schema = { columns => {} };
            eval {
                $result_schema = $self->parse_result_file_schema($c, $result_info->{result_path});
            };
            
            push @orphaned_results, {
                result_name => $result_info->{result_name},
                result_path => $result_info->{result_path},
                expected_table_name => $table_name,
                actual_table_name => $table_name,
                last_modified => $result_info->{last_modified},
                columns => $result_schema->{columns},
                primary_keys => $result_schema->{primary_keys} || [],
                relationships => $result_schema->{relationships} || {},
                raw_package_calls => $result_schema->{raw_package_calls} || []
            };
        }
    }
    
    return @orphaned_results;
}

# Get all Result files for a database
sub get_all_result_files {
    my ($self, $database) = @_;
    
    my @result_files = ();
    use File::Basename qw(dirname);
    my $lib_path = dirname(dirname(dirname(__FILE__)));
    my $base_path = "$lib_path/Comserv/Model/Schema";
    
    if (lc($database) eq 'ency') {
        my $result_dir = "$base_path/Ency/Result";
        @result_files = $self->scan_result_directory_recursive($result_dir, '');
    } elsif (lc($database) eq 'forager') {
        my $result_dir = "$base_path/Forager/Result";
        @result_files = $self->scan_result_directory_recursive($result_dir, '');
    }
    
    return @result_files;
}

# Scan a directory recursively for Result files
sub scan_result_directory_recursive {
    my ($self, $dir_path, $prefix) = @_;
    
    my @files = ();
    
    if (opendir(my $dh, $dir_path)) {
        while (my $file = readdir($dh)) {
            next if $file =~ /^\.\.?$/;  # Skip . and ..
            
            my $full_path = "$dir_path/$file";
            
            if (-d $full_path) {
                # Recursively scan subdirectory
                push @files, $self->scan_result_directory_recursive($full_path, $prefix . $file . '/');
            } elsif ($file =~ /\.pm$/) {
                # Add Result file
                my $name = $file;
                $name =~ s/\.pm$//;  # Remove .pm extension
                
                push @files, {
                    name => $prefix . $name,
                    path => $full_path,
                    last_modified => (stat($full_path))[9]
                };
            }
        }
        closedir($dh);
    }
    
    return @files;
}

# Convert Result class name back to table name
sub result_name_to_table_name {
    my ($self, $result_name) = @_;
    
    # Remove any path prefix (e.g., "System/Site" -> "Site")
    $result_name =~ s/.*\///;
    
    # Handle special cases - map Result names to actual table names
    my %result_to_table = (
        'Category' => 'categories',
        'File' => 'files',
        'Group' => 'groups',
        'User' => 'users',
        'Event' => 'events',
        'Site' => 'sites',
        'Todo' => 'todos',
        'Project' => 'projects',
        'WorkShop' => 'workshops',
        'Theme' => 'themes',
        'Reference' => 'references',
        'Participant' => 'participants',
        'Herb' => 'ency_herb_tb',
        'Page' => 'page',
        'InternalLinksTb' => 'internal_links_tb',
        'Learned_data' => 'learned_data',
        'Log' => 'log',
        'MailDomain' => 'mail_domains',
        'NetworkDevice' => 'network_devices',
        'Pallet' => 'pallets',
        'ProjectSite' => 'project_sites',
        'Queen' => 'queens',
        'SiteConfig' => 'site_config',
        'SiteDomain' => 'sitedomain',
        'SiteTheme' => 'site_themes',
        'SiteWorkshop' => 'site_workshop',
        'ThemeVariable' => 'theme_variables',
        'UserGroup' => 'user_groups',
        'UserSite' => 'user_sites',
        'Yard' => 'yards'
    );
    
    # Check if it's a known mapping
    if (exists $result_to_table{$result_name}) {
        return $result_to_table{$result_name};
    }
    
    # Convert PascalCase to snake_case
    my $table_name = $result_name;
    $table_name =~ s/([a-z])([A-Z])/$1_$2/g;  # Insert underscore before capitals
    $table_name = lc($table_name);
    
    # For unknown mappings, try common patterns
    # This is a fallback - ideally all mappings should be explicit above
    return $table_name;
}

# Get detailed field comparison between table and Result file
sub get_table_result_comparison {
    my ($self, $c, $table_name, $database) = @_;
    
    # Get table schema
    my $table_schema;
    eval {
        if ($database eq 'ency') {
            $table_schema = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $table_schema = $self->get_forager_table_schema($c, $table_name);
        } else {
            die "Invalid database: $database";
        }
    };
    if ($@) {
        warn "Failed to get table schema for $table_name ($database): $@";
        $table_schema = { columns => {} };
    }
    
    # Find and parse Result file
    my $result_file_path = $self->find_result_file($c, $table_name, $database);
    my $result_schema = { columns => {} };
    
    if ($result_file_path && -f $result_file_path) {
        eval {
            $result_schema = $self->parse_result_file_schema($c, $result_file_path);
        };
        if ($@) {
            warn "Failed to parse Result file $result_file_path: $@";
            $result_schema = { columns => {} };
        }
    }
    
    # Create field comparison
    my $comparison = {
        table_name => $table_name,
        database => $database,
        has_result_file => ($result_file_path && -f $result_file_path) ? 1 : 0,
        result_file_path => $result_file_path,
        fields => {}
    };
    
    # Get all unique field names from both sources
    my %all_fields = ();
    if ($table_schema && $table_schema->{columns}) {
        %all_fields = (%all_fields, map { $_ => 1 } keys %{$table_schema->{columns}});
    }
    if ($result_schema && $result_schema->{columns}) {
        %all_fields = (%all_fields, map { $_ => 1 } keys %{$result_schema->{columns}});
    }
    
    # Compare each field
    foreach my $field_name (sort keys %all_fields) {
        my $table_field = $table_schema->{columns}->{$field_name};
        my $result_field = $result_schema->{columns}->{$field_name};
        
        $comparison->{fields}->{$field_name} = {
            table => $table_field,
            result => $result_field,
            differences => $self->compare_field_attributes($table_field, $result_field, $c, $field_name)
        };
    }
    
    return $comparison;
}

# Get detailed field comparison between table and Result file using comprehensive mapping
sub get_table_result_comparison_v2 {
    my ($self, $c, $table_name, $database, $result_table_mapping) = @_;
    
    # Get table schema
    my $table_schema;
    eval {
        if ($database eq 'ency') {
            $table_schema = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $table_schema = $self->get_forager_table_schema($c, $table_name);
        } else {
            die "Invalid database: $database";
        }
    };
    if ($@) {
        warn "Failed to get table schema for $table_name ($database): $@";
        $table_schema = { columns => {} };
    }
    
    # Check if this table has a corresponding result file using the mapping
    my $table_key = lc($table_name);
    my $result_info = $result_table_mapping->{$table_key};
    my $result_schema = { columns => {} };
    
    if ($result_info && -f $result_info->{result_path}) {
        eval {
            $result_schema = $self->parse_result_file_schema($c, $result_info->{result_path});
        };
        if ($@) {
            warn "Failed to parse Result file $result_info->{result_path}: $@";
            $result_schema = { columns => {} };
        }
    }
    
    # Create field comparison
    my $comparison = {
        table_name => $table_name,
        database => $database,
        has_result_file => $result_info ? 1 : 0,
        result_file_path => $result_info ? $result_info->{result_path} : undef,
        fields => {},
        primary_keys => $result_schema->{primary_keys} || [],
        relationships => $result_schema->{relationships} || {},
        raw_package_calls => $result_schema->{raw_package_calls} || []
    };
    
    # Get all unique field names from both sources
    my %all_fields = ();
    if ($table_schema && $table_schema->{columns}) {
        %all_fields = (%all_fields, map { $_ => 1 } keys %{$table_schema->{columns}});
    }
    if ($result_schema && $result_schema->{columns}) {
        %all_fields = (%all_fields, map { $_ => 1 } keys %{$result_schema->{columns}});
    }
    
    # Compare each field
    foreach my $field_name (sort keys %all_fields) {
        my $table_field = $table_schema->{columns}->{$field_name};
        my $result_field = $result_schema->{columns}->{$field_name};
        
        # Add primary key and foreign key status to field data
        if ($table_field) {
            $table_field->{is_primary_key} = (grep { $_ eq $field_name } @{$table_schema->{primary_keys} || []}) ? 1 : 0;
            $table_field->{is_foreign_key} = (grep { $_->{column} eq $field_name } @{$table_schema->{foreign_keys} || []}) ? 1 : 0;
        }
        if ($result_field) {
            $result_field->{is_primary_key} = (grep { $_ eq $field_name } @{$result_schema->{primary_keys} || []}) ? 1 : 0;
            # In Result files, foreign keys are often identified via belongs_to relationships
            # Already set in get_result_file_schema, but ensuring it here too
            unless ($result_field->{is_foreign_key}) {
                $result_field->{is_foreign_key} = (grep { ($_->{column} || '') eq $field_name } values %{$result_schema->{relationships} || {}}) ? 1 : 0;
            }
        }
        
        $comparison->{fields}->{$field_name} = {
            table => $table_field,
            result => $result_field,
            differences => $self->compare_field_attributes($table_field, $result_field, $c, $field_name)
        };
    }
    
    return $comparison;
}

# Compare field attributes between table and Result file
sub compare_field_attributes {
    my ($self, $table_field, $result_field, $c, $field_name) = @_;
    
    my @differences = ();
    my @attributes = qw(data_type size is_nullable is_auto_increment is_primary_key is_foreign_key default_value extra relationship);
    
    foreach my $attr (@attributes) {
        my $table_value = $table_field ? $table_field->{$attr} : undef;
        my $result_value = $result_field ? $result_field->{$attr} : undef;
        
        # Store original values for debugging
        my $original_table_value = $table_value;
        my $original_result_value = $result_value;
        
        # Normalize values for comparison
        $table_value = $self->normalize_field_value($attr, $table_value);
        $result_value = $self->normalize_field_value($attr, $result_value);
        
        # Add debug information for data_type comparisons when debug_mode is enabled
        if ($c && $c->session->{debug_mode} && $attr eq 'data_type' && defined $original_table_value && defined $original_result_value) {
            push @{$c->stash->{debug_msg}}, sprintf(
                "Field '%s' data_type normalization: Table Type: %s -> %s, Result Type: %s -> %s, Match: %s",
                $field_name || 'unknown',
                $original_table_value || 'undef',
                $table_value || 'undef',
                $original_result_value || 'undef', 
                $result_value || 'undef',
                (defined $table_value && defined $result_value && $table_value eq $result_value) ? 'YES' : 'NO'
            );
        }
        
        if (defined $table_value && defined $result_value) {
            if ($table_value ne $result_value) {
                push @differences, {
                    attribute => $attr,
                    table_value => $table_value,
                    result_value => $result_value,
                    original_table_value => $original_table_value,
                    original_result_value => $original_result_value,
                    type => 'different'
                };
            }
        } elsif (defined $table_value && !defined $result_value) {
            push @differences, {
                attribute => $attr,
                table_value => $table_value,
                result_value => undef,
                original_table_value => $original_table_value,
                original_result_value => $original_result_value,
                type => 'missing_in_result'
            };
        } elsif (!defined $table_value && defined $result_value) {
            push @differences, {
                attribute => $attr,
                table_value => undef,
                result_value => $result_value,
                original_table_value => $original_table_value,
                original_result_value => $original_result_value,
                type => 'missing_in_table'
            };
        }
    }
    
    return \@differences;
}

# Normalize field values for comparison
sub normalize_field_value {
    my ($self, $attribute, $value) = @_;
    
    return undef unless defined $value;
    
    # Handle data type normalization
    if ($attribute eq 'data_type') {
        return $self->normalize_data_type($value);
    }
    
    # Handle boolean attributes
    if ($attribute eq 'is_nullable' || $attribute eq 'is_auto_increment' || $attribute eq 'is_primary_key' || $attribute eq 'is_foreign_key') {
        return $value ? 1 : 0;
    }
    
    # Handle numeric attributes
    if ($attribute eq 'size') {
        return "$value" if $value =~ /^[\d,]+$/;
    }
    
    # Handle extra attributes normalization
    if ($attribute eq 'extra') {
        $value =~ s/\s+/ /g; # Normalize whitespace
        $value =~ s/^\s+|\s+$//g; # Trim
        return $value;
    }

    # Handle relationship object normalization for comparison
    if ($attribute eq 'relationship') {
        if (ref($value) eq 'HASH') {
            return $value->{type} . ":" . $value->{accessor} . "->" . ($value->{related_class} =~ s/.*:://r);
        }
        return $value;
    }
    
    # Handle string attributes
    return "$value";
}

# Find differences between database and Result file schemas
sub find_schema_differences {
    my ($self, $db_schema, $result_schema) = @_;
    
    my @differences = ();
    
    # Compare columns
    my %db_columns = %{$db_schema->{columns} || {}};
    my %result_columns = %{$result_schema->{columns} || {}};
    
    # Find columns in database but not in Result file
    foreach my $col_name (keys %db_columns) {
        unless (exists $result_columns{$col_name}) {
            push @differences, {
                type => 'missing_in_result',
                column => $col_name,
                description => "Column '$col_name' exists in database but not in Result file"
            };
        }
    }
    
    # Find columns in Result file but not in database
    foreach my $col_name (keys %result_columns) {
        unless (exists $db_columns{$col_name}) {
            push @differences, {
                type => 'missing_in_database',
                column => $col_name,
                description => "Column '$col_name' exists in Result file but not in database"
            };
        }
    }
    
    # Compare column attributes for common columns
    foreach my $col_name (keys %db_columns) {
        if (exists $result_columns{$col_name}) {
            my $db_col = $db_columns{$col_name};
            my $result_col = $result_columns{$col_name};
            
            # Compare data types
            if (($db_col->{data_type} || '') ne ($result_col->{data_type} || '')) {
                push @differences, {
                    type => 'column_type_mismatch',
                    column => $col_name,
                    database_value => $db_col->{data_type},
                    result_value => $result_col->{data_type},
                    description => "Data type mismatch for column '$col_name'"
                };
            }
            
            # Compare nullable status
            if (($db_col->{is_nullable} || 0) != ($result_col->{is_nullable} || 0)) {
                push @differences, {
                    type => 'column_nullable_mismatch',
                    column => $col_name,
                    database_value => $db_col->{is_nullable} ? 'YES' : 'NO',
                    result_value => $result_col->{is_nullable} ? 'YES' : 'NO',
                    description => "Nullable status mismatch for column '$col_name'"
                };
            }

            # Compare size
            if (($db_col->{size} || '') ne ($result_col->{size} || '')) {
                push @differences, {
                    type => 'column_size_mismatch',
                    column => $col_name,
                    database_value => $db_col->{size} || 'N/A',
                    result_value => $result_col->{size} || 'N/A',
                    description => "Size mismatch for column '$col_name'"
                };
            }

            # Compare auto increment
            if (($db_col->{is_auto_increment} || 0) != ($result_col->{is_auto_increment} || 0)) {
                push @differences, {
                    type => 'column_auto_increment_mismatch',
                    column => $col_name,
                    database_value => $db_col->{is_auto_increment} ? 'YES' : 'NO',
                    result_value => $result_col->{is_auto_increment} ? 'YES' : 'NO',
                    description => "Auto-increment mismatch for column '$col_name'"
                };
            }

            # Compare default value
            if (($db_col->{default_value} // '') ne ($result_col->{default_value} // '')) {
                push @differences, {
                    type => 'column_default_mismatch',
                    column => $col_name,
                    database_value => $db_col->{default_value} // 'NULL',
                    result_value => $result_col->{default_value} // 'NULL',
                    description => "Default value mismatch for column '$col_name'"
                };
            }

            # Compare extra
            if (($db_col->{extra} || '') ne ($result_col->{extra} || '')) {
                push @differences, {
                    type => 'column_extra_mismatch',
                    column => $col_name,
                    database_value => $db_col->{extra} || 'N/A',
                    result_value => $result_col->{extra} || 'N/A',
                    description => "Extra attributes mismatch for column '$col_name'"
                };
            }
        }
    }
    
    # Compare Primary Keys
    my @db_pks = sort @{$db_schema->{primary_keys} || []};
    my @result_pks = sort @{$result_schema->{primary_keys} || []};
    
    if (join(',', @db_pks) ne join(',', @result_pks)) {
        push @differences, {
            type => 'primary_key_mismatch',
            attribute => 'set_primary_key',
            database_value => join(', ', @db_pks) || 'None',
            result_value => join(', ', @result_pks) || 'None',
            description => "Primary key mismatch"
        };
    }
    
    # Compare Unique Constraints
    my %db_uniques = map { ($_->{name} || 'unnamed') => join(',', sort @{$_->{columns}}) } @{$db_schema->{unique_constraints} || []};
    my %result_uniques = map { ($_->{name} || 'unnamed') => join(',', sort @{$_->{columns}}) } @{$result_schema->{unique_constraints} || []};
    
    foreach my $name (keys %db_uniques) {
        if (!exists $result_uniques{$name}) {
            push @differences, {
                type => 'unique_constraint_missing_in_result',
                attribute => "add_unique_constraint ($name)",
                database_value => $db_uniques{$name},
                result_value => undef,
                description => "Unique constraint '$name' missing in Result file"
            };
        } elsif ($db_uniques{$name} ne $result_uniques{$name}) {
            push @differences, {
                type => 'unique_constraint_mismatch',
                attribute => "add_unique_constraint ($name)",
                database_value => $db_uniques{$name},
                result_value => $result_uniques{$name},
                description => "Unique constraint '$name' column mismatch"
            };
        }
    }
    
    foreach my $name (keys %result_uniques) {
        if (!exists $db_uniques{$name}) {
            push @differences, {
                type => 'unique_constraint_missing_in_table',
                attribute => "add_unique_constraint ($name)",
                database_value => undef,
                result_value => $result_uniques{$name},
                description => "Unique constraint '$name' exists in Result file but not in database"
            };
        }
    }
    
    return \@differences;
}

# Get the database name
sub get_database_name {
    my ($self, $c) = @_;
    
    my $database_name = 'Unknown Database';
    
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("SELECT DATABASE()");
        $sth->execute();
        
        if (my ($db_name) = $sth->fetchrow_array()) {
            $database_name = $db_name;
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_database_name', 
            "Error getting database name: $_");
    };
    
    return $database_name;
}

# Get list of database tables with their schema information
sub get_database_tables {
    my ($self, $c) = @_;
    
    my @tables = ();
    
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW TABLES");
        $sth->execute();
        
        while (my ($table) = $sth->fetchrow_array()) {
            push @tables, $table;
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_database_tables', 
            "Error getting database tables: $_");
    };
    
    return \@tables;
}

# Get list of tables from the Ency database
sub get_ency_database_tables {
    my ($self, $c) = @_;
    
    my @tables = ();
    
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW TABLES");
        $sth->execute();
        
        while (my ($table) = $sth->fetchrow_array()) {
            push @tables, $table;
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_ency_database_tables', 
            "Error getting ency database tables: $_");
        die $_;
    };
    
    # Sort tables alphabetically
    @tables = sort @tables;
    
    return \@tables;
}

# Get list of tables from the Forager database
sub get_forager_database_tables {
    my ($self, $c) = @_;
    
    my @tables = ();
    
    try {
        my $dbh = $c->model('DBForager')->schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW TABLES");
        $sth->execute();
        
        while (my ($table) = $sth->fetchrow_array()) {
            push @tables, $table;
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_forager_database_tables', 
            "Error getting forager database tables: $_");
        die $_;
    };
    
    # Sort tables alphabetically
    @tables = sort @tables;
    
    return \@tables;
}

# Get table schema from the Ency database
sub get_ency_table_schema {
    my ($self, $c, $table_name) = @_;
    
    my $schema_info = {
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        foreign_keys => [],
        indexes => []
    };
    
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        
        # Get column information
        my $sth = $dbh->prepare("DESCRIBE $table_name");
        $sth->execute();
        
        while (my $row = $sth->fetchrow_hashref()) {
            my $column_name = $row->{Field};
            
            $schema_info->{columns}->{$column_name} = {
                data_type => $row->{Type},
                is_nullable => ($row->{Null} eq 'YES' ? 1 : 0),
                default_value => $row->{Default},
                is_auto_increment => ($row->{Extra} =~ /auto_increment/i ? 1 : 0),
                extra => $row->{Extra},
                size => undef  # Will be parsed from Type if needed
            };
            
            # Check for primary key
            if ($row->{Key} eq 'PRI') {
                push @{$schema_info->{primary_keys}}, $column_name;
            }
        }
        
        # Get foreign key information
        $sth = $dbh->prepare("
            SELECT 
                COLUMN_NAME,
                REFERENCED_TABLE_NAME,
                REFERENCED_COLUMN_NAME,
                CONSTRAINT_NAME
            FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
            WHERE TABLE_SCHEMA = DATABASE() 
            AND TABLE_NAME = ? 
            AND REFERENCED_TABLE_NAME IS NOT NULL
        ");
        $sth->execute($table_name);
        
        while (my $row = $sth->fetchrow_hashref()) {
            push @{$schema_info->{foreign_keys}}, {
                column => $row->{COLUMN_NAME},
                referenced_table => $row->{REFERENCED_TABLE_NAME},
                referenced_column => $row->{REFERENCED_COLUMN_NAME},
                constraint_name => $row->{CONSTRAINT_NAME}
            };
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_ency_table_schema', 
            "Error getting ency table schema for $table_name: $_");
        die $_;
    };
    
    return $schema_info;
}

# Get table schema from the Forager database
sub get_forager_table_schema {
    my ($self, $c, $table_name) = @_;
    
    my $schema_info = {
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        foreign_keys => [],
        indexes => []
    };
    
    try {
        my $dbh = $c->model('DBForager')->schema->storage->dbh;
        
        # Get column information
        my $sth = $dbh->prepare("DESCRIBE $table_name");
        $sth->execute();
        
        while (my $row = $sth->fetchrow_hashref()) {
            my $column_name = $row->{Field};
            
            $schema_info->{columns}->{$column_name} = {
                data_type => $row->{Type},
                is_nullable => ($row->{Null} eq 'YES' ? 1 : 0),
                default_value => $row->{Default},
                is_auto_increment => ($row->{Extra} =~ /auto_increment/i ? 1 : 0),
                extra => $row->{Extra},
                size => undef  # Will be parsed from Type if needed
            };
            
            # Check for primary key
            if ($row->{Key} eq 'PRI') {
                push @{$schema_info->{primary_keys}}, $column_name;
            }
        }
        
        # Get foreign key information
        $sth = $dbh->prepare("
            SELECT 
                COLUMN_NAME,
                REFERENCED_TABLE_NAME,
                REFERENCED_COLUMN_NAME,
                CONSTRAINT_NAME
            FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
            WHERE TABLE_SCHEMA = DATABASE() 
            AND TABLE_NAME = ? 
            AND REFERENCED_TABLE_NAME IS NOT NULL
        ");
        $sth->execute($table_name);
        
        while (my $row = $sth->fetchrow_hashref()) {
            push @{$schema_info->{foreign_keys}}, {
                column => $row->{COLUMN_NAME},
                referenced_table => $row->{REFERENCED_TABLE_NAME},
                referenced_column => $row->{REFERENCED_COLUMN_NAME},
                constraint_name => $row->{CONSTRAINT_NAME}
            };
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_forager_table_schema', 
            "Error getting forager table schema for $table_name: $_");
        die $_;
    };
    
    return $schema_info;
}

# Get database table schema information
sub get_database_table_schema {
    my ($self, $c, $table_name) = @_;
    
    my $schema_info = {
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        foreign_keys => [],
        indexes => []
    };
    
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        
        # Get column information
        my $sth = $dbh->prepare("DESCRIBE `$table_name`");
        $sth->execute();
        
        while (my $row = $sth->fetchrow_hashref()) {
            my $column_name = $row->{Field};
            
            # Parse MySQL column type
            my ($data_type, $size) = $self->parse_mysql_column_type($row->{Type});
            
            $schema_info->{columns}->{$column_name} = {
                data_type => $data_type,
                size => $size,
                is_nullable => ($row->{Null} eq 'YES' ? 1 : 0),
                default_value => $row->{Default},
                is_auto_increment => ($row->{Extra} =~ /auto_increment/i ? 1 : 0),
                extra => $row->{Extra}
            };
            
            # Check for primary key
            if ($row->{Key} eq 'PRI') {
                push @{$schema_info->{primary_keys}}, $column_name;
            }
        }
        
        # Get foreign key information
        $sth = $dbh->prepare("
            SELECT 
                COLUMN_NAME,
                REFERENCED_TABLE_NAME,
                REFERENCED_COLUMN_NAME,
                CONSTRAINT_NAME
            FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
            WHERE TABLE_SCHEMA = DATABASE() 
            AND TABLE_NAME = ? 
            AND REFERENCED_TABLE_NAME IS NOT NULL
        ");
        $sth->execute($table_name);
        
        while (my $row = $sth->fetchrow_hashref()) {
            push @{$schema_info->{foreign_keys}}, {
                column => $row->{COLUMN_NAME},
                referenced_table => $row->{REFERENCED_TABLE_NAME},
                referenced_column => $row->{REFERENCED_COLUMN_NAME},
                constraint_name => $row->{CONSTRAINT_NAME}
            };
        }
        
        # Get unique constraints
        $sth = $dbh->prepare("
            SELECT 
                CONSTRAINT_NAME,
                GROUP_CONCAT(COLUMN_NAME ORDER BY ORDINAL_POSITION) as COLUMNS
            FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
            WHERE TABLE_SCHEMA = DATABASE() 
            AND TABLE_NAME = ? 
            AND CONSTRAINT_NAME != 'PRIMARY'
            GROUP BY CONSTRAINT_NAME
        ");
        $sth->execute($table_name);
        
        while (my $row = $sth->fetchrow_hashref()) {
            push @{$schema_info->{unique_constraints}}, {
                name => $row->{CONSTRAINT_NAME},
                columns => [split(',', $row->{COLUMNS})]
            };
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_database_table_schema', 
            "Error getting schema for table $table_name: $_");
    };
    
    return $schema_info;
}

# Parse MySQL column type to extract data type and size
sub parse_mysql_column_type {
    my ($self, $type_string) = @_;
    
    # Handle common MySQL types
    if ($type_string =~ /^(\w+)\((\d+)\)/) {
        return ($1, $2);
    } elsif ($type_string =~ /^(\w+)\((\d+),(\d+)\)/) {
        return ($1, "$2,$3");  # For decimal types
    } elsif ($type_string =~ /^(\w+)/) {
        return ($1, undef);
    }
    
    return ($type_string, undef);
}

# Get Result files and their schema information
sub get_result_files {
    my ($self, $c) = @_;
    
    my $result_files = {};
    
    try {
        my $result_dir = $c->path_to('lib', 'Comserv', 'Model', 'Schema', 'Ency', 'Result');
        
        if (-d $result_dir) {
            find(sub {
                return unless -f $_ && /\.pm$/;
                # Skip helper directories/files if any
                return if $File::Find::dir =~ /\/Result\/(User|Base|Audit)$/; 
                
                my $file_path = $File::Find::name;
                my $relative_path = $file_path;
                $relative_path =~ s/^\Q$result_dir\E\/?//;
                
                # Extract class name (e.g., Comserv::Model::Schema::Ency::Result::PlanSystemMapping)
                my $class_rel = $relative_path;
                $class_rel =~ s/\.pm$//;
                $class_rel =~ s/\//::/g;
                my $full_class = "Comserv::Model::Schema::Ency::Result::$class_rel";
                
                my $schema_info = $self->get_result_file_schema($c, $full_class, $file_path);
                if ($schema_info && $schema_info->{table_name}) {
                    $result_files->{$schema_info->{table_name}} = $schema_info;
                }
            }, $result_dir);
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_result_files', 
            "Error getting Result files: $_");
    };
    
    return $result_files;
}

# Get schema information from a Result file
sub get_result_file_schema {
    my ($self, $c, $file_path) = @_;
    
    my $schema_info = {
        file_path => $file_path,
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        relationships => {},
        table_name => undef
    };
    
    try {
        # Read the file content
        my $content = read_file($file_path);
        
        # Extract table name
        if ($content =~ /__PACKAGE__->table\s*\(\s*['"]([^'"]+)['"]\s*\)/s) {
            $schema_info->{table_name} = $1;
        }
        
        # Capture all __PACKAGE__ calls for display
        $schema_info->{raw_package_calls} = [];
        while ($content =~ /(__PACKAGE__->(\w+)\s*\((.*?)\)\s*;)/gs) {
            push @{$schema_info->{raw_package_calls}}, {
                full => $1,
                method => $2,
                args => $3
            };
        }
        
        # Extract columns
        if ($content =~ /__PACKAGE__->add_columns\s*\((.*?)\);/s) {
            my $columns_text = $1;
            $schema_info->{columns} = $self->parse_result_file_columns($columns_text);
        }
        
        # Extract primary key
        if ($content =~ /__PACKAGE__->set_primary_key\s*\((.*?)\)/s) {
            my $pk_text = $1;
            $pk_text =~ s/['"\s]//g;
            @{$schema_info->{primary_keys}} = split(/,/, $pk_text);
            
            # Mark columns as PK in the columns hash
            foreach my $pk (@{$schema_info->{primary_keys}}) {
                if ($schema_info->{columns}->{$pk}) {
                    $schema_info->{columns}->{$pk}->{is_primary_key} = 1;
                }
            }
        }
        
        # Extract unique constraints
        while ($content =~ /__PACKAGE__->add_unique_constraint\s*\(\s*(?:['"]([^'"]+)['"]\s*=>\s*)?\[(.*?)\]\s*\)/gs) {
            my $constraint_name = $1 || 'unnamed';
            my $columns_text = $2;
            $columns_text =~ s/['"\s]//g;
            push @{$schema_info->{unique_constraints}}, {
                name => $constraint_name,
                columns => [split(/,/, $columns_text)]
            };
        }
        
        # Extract relationships (belongs_to, has_many, etc.)
        # Pattern: __PACKAGE__->rel_type('accessor' => 'Related::Class', 'foreign_key', { options })
        while ($content =~ /__PACKAGE__->(belongs_to|has_many|has_one|might_have)\s*\(\s*['"]?(\w+)['"]?\s*=>\s*['"]?([^'",\s\)]+)['"]?\s*(?:,\s*(?:['"]?(\w+)['"]?|\{(.*?)\}))?/gs) {
            my $type = $1;
            my $accessor = $2;
            my $related_class = $3;
            my $fk_col_or_opt = $4;
            
            # Handle cases where the 3rd param is a hashref (options)
            my $fk_col = ($fk_col_or_opt && $fk_col_or_opt !~ /^\{/) ? $fk_col_or_opt : undef;
            
            $schema_info->{relationships}->{$accessor} = {
                type => $type,
                class => $related_class,
                column => $fk_col || $accessor # Fallback to accessor name if no FK specified
            };
            
            # Mark the column as a foreign key if we can find it
            my $target_col = $fk_col || $accessor;
            if ($schema_info->{columns}->{$target_col}) {
                $schema_info->{columns}->{$target_col}->{relationship} = {
                    type => $type,
                    related_class => $related_class,
                    accessor => $accessor
                };
                $schema_info->{columns}->{$target_col}->{is_foreign_key} = 1;
            }
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_result_file_schema', 
            "Error parsing Result file $file_path: $_");
        return undef;
    };
    
    return $schema_info;
}

# Legacy wrapper for parse_result_file_schema
sub parse_result_file_schema {
    my ($self, $c, $file_path) = @_;
    return $self->get_result_file_schema($c, $file_path);
}

# Parse column definitions from Result file
sub parse_result_file_columns {
    my ($self, $columns_text) = @_;
    
    my $columns = {};
    
    # Split by column definitions (looking for column_name => { ... })
    # Using more robust matching for nested structures
    while ($columns_text =~ /(\w+)\s*=>\s*\{([\s\S]*?)\}(?=\s*,\s*\w+\s*=>|\s*,?\s*\))/g) {
        my $column_name = $1;
        my $column_def = $2;
        
        my $column_info = {};
        
        # Parse column attributes
        # Handles: attr => 'value', attr => 1, attr => \'SCALAR', attr => { ... }
        while ($column_def =~ /(\w+)\s*=>\s*(?:['"]([^'"]+)['"]|(\d+)|\\['"]([^'"]+)['"]|\{([\s\S]*?)\})/g) {
            my $attr = $1;
            my $value = $2 // $3 // $4 // $5;
            
            if ($attr eq 'size' && $value =~ /^\d+$/) {
                $column_info->{$attr} = int($value);
            } elsif ($attr eq 'is_nullable' || $attr eq 'is_auto_increment') {
                $column_info->{$attr} = ($value eq '1' || $value eq 'true' || $value =~ /true/i) ? 1 : 0;
            } else {
                $column_info->{$attr} = $value;
            }
        }
        
        $columns->{$column_name} = $column_info;
    }
    
    # Fallback if the above robust regex fails for some reason
    if (scalar(keys %$columns) == 0) {
        while ($columns_text =~ /(\w+)\s*=>\s*\{([^}]+)\}/g) {
            my $column_name = $1;
            my $column_def = $2;
            my $column_info = {};
            while ($column_def =~ /(\w+)\s*=>\s*['"]?([^'",\s]+)['"]?/g) {
                $column_info->{$1} = $2;
            }
            $columns->{$column_name} = $column_info;
        }
    }
    
    return $columns;
}

# Compare schema between database table and Result file
sub compare_table_schema {
    my ($self, $c, $table_name, $db_tables, $result_files) = @_;
    
    my $comparison = {
        table_name => $table_name,
        database_table_exists => 0,
        result_file_exists => 0,
        has_differences => 0,
        column_differences => [],
        primary_key_differences => [],
        relationship_differences => [],
        unique_constraint_differences => [],
        database_schema => undef,
        result_file_schema => undef
    };
    
    # Check if database table exists
    $comparison->{database_table_exists} = grep { $_ eq $table_name } @$db_tables;
    
    # Check if Result file exists
    $comparison->{result_file_exists} = exists $result_files->{$table_name};
    
    # Get schemas if both exist
    if ($comparison->{database_table_exists}) {
        $comparison->{database_schema} = $self->get_database_table_schema($c, $table_name);
    }
    
    if ($comparison->{result_file_exists}) {
        $comparison->{result_file_schema} = $result_files->{$table_name};
    }
    
    # Compare if both exist
    if ($comparison->{database_table_exists} && $comparison->{result_file_exists}) {
        $self->compare_columns($comparison);
        $self->compare_primary_keys($comparison);
        $self->compare_unique_constraints($comparison);
        $self->compare_relationships($comparison);
        
        # Set has_differences flag
        $comparison->{has_differences} = (
            @{$comparison->{column_differences}} > 0 ||
            @{$comparison->{primary_key_differences}} > 0 ||
            @{$comparison->{relationship_differences}} > 0 ||
            @{$comparison->{unique_constraint_differences}} > 0
        );
    } elsif (!$comparison->{database_table_exists} || !$comparison->{result_file_exists}) {
        $comparison->{has_differences} = 1;
    }
    
    return $comparison;
}

# Compare columns between database and Result file
sub compare_columns {
    my ($self, $comparison) = @_;
    
    my $db_columns = $comparison->{database_schema}->{columns};
    my $result_columns = $comparison->{result_file_schema}->{columns};
    
    # Get all column names
    my %all_columns = ();
    foreach my $col (keys %$db_columns) { $all_columns{$col} = 1; }
    foreach my $col (keys %$result_columns) { $all_columns{$col} = 1; }
    
    foreach my $column_name (sort keys %all_columns) {
        my $db_col = $db_columns->{$column_name};
        my $result_col = $result_columns->{$column_name};
        
        if (!$db_col) {
            push @{$comparison->{column_differences}}, {
                column => $column_name,
                type => 'missing_in_database',
                result_file_definition => $result_col
            };
        } elsif (!$result_col) {
            push @{$comparison->{column_differences}}, {
                column => $column_name,
                type => 'missing_in_result_file',
                database_definition => $db_col
            };
        } else {
            # Compare column attributes
            my @differences = ();
            
            # Compare data type
            if (lc($db_col->{data_type}) ne lc($result_col->{data_type})) {
                push @differences, {
                    attribute => 'data_type',
                    database_value => $db_col->{data_type},
                    result_file_value => $result_col->{data_type}
                };
            }
            
            # Compare size
            if (defined($db_col->{size}) != defined($result_col->{size}) ||
                (defined($db_col->{size}) && defined($result_col->{size}) && 
                 $db_col->{size} ne $result_col->{size})) {
                push @differences, {
                    attribute => 'size',
                    database_value => $db_col->{size},
                    result_file_value => $result_col->{size}
                };
            }
            
            # Compare nullable
            if (($db_col->{is_nullable} || 0) != ($result_col->{is_nullable} || 0)) {
                push @differences, {
                    attribute => 'is_nullable',
                    database_value => $db_col->{is_nullable},
                    result_file_value => $result_col->{is_nullable}
                };
            }
            
            # Compare auto increment
            if (($db_col->{is_auto_increment} || 0) != ($result_col->{is_auto_increment} || 0)) {
                push @differences, {
                    attribute => 'is_auto_increment',
                    database_value => $db_col->{is_auto_increment},
                    result_file_value => $result_col->{is_auto_increment}
                };
            }
            
            if (@differences) {
                push @{$comparison->{column_differences}}, {
                    column => $column_name,
                    type => 'attribute_differences',
                    differences => \@differences,
                    database_definition => $db_col,
                    result_file_definition => $result_col
                };
            }
        }
    }
}

# Compare primary keys
sub compare_primary_keys {
    my ($self, $comparison) = @_;
    
    my $db_pks = $comparison->{database_schema}->{primary_keys};
    my $result_pks = $comparison->{result_file_schema}->{primary_keys};
    
    # Sort for comparison
    my @db_pks_sorted = sort @$db_pks;
    my @result_pks_sorted = sort @$result_pks;
    
    if (join(',', @db_pks_sorted) ne join(',', @result_pks_sorted)) {
        push @{$comparison->{primary_key_differences}}, {
            database_primary_keys => \@db_pks_sorted,
            result_file_primary_keys => \@result_pks_sorted
        };
    }
}

# Compare unique constraints
sub compare_unique_constraints {
    my ($self, $comparison) = @_;
    
    my $db_constraints = $comparison->{database_schema}->{unique_constraints};
    my $result_constraints = $comparison->{result_file_schema}->{unique_constraints};
    
    # This is a simplified comparison - you might want to make it more sophisticated
    if (@$db_constraints != @$result_constraints) {
        push @{$comparison->{unique_constraint_differences}}, {
            database_constraints => $db_constraints,
            result_file_constraints => $result_constraints
        };
    }
}

# Compare relationships (this is Result file specific)
sub compare_relationships {
    my ($self, $comparison) = @_;
    
    # For now, we'll just note if relationships exist in the Result file
    # but aren't reflected in the database foreign keys
    my $result_relationships = $comparison->{result_file_schema}->{relationships};
    my $db_foreign_keys = $comparison->{database_schema}->{foreign_keys};
    
    if (@$result_relationships > @$db_foreign_keys) {
        push @{$comparison->{relationship_differences}}, {
            type => 'missing_foreign_keys_in_database',
            result_file_relationships => $result_relationships,
            database_foreign_keys => $db_foreign_keys
        };
    }
}

# Apply selected schema changes
sub apply_schema_changes {
    my ($self, $c) = @_;
    
    my $changes = $c->req->param('changes');
    my $direction = $c->req->param('direction'); # 'db_to_result' or 'result_to_db'
    
    if (!$changes) {
        $c->flash->{error_msg} = "No changes selected to apply.";
        return;
    }
    
    try {
        my $changes_data = decode_json($changes);
        my $applied_changes = 0;
        
        foreach my $change (@$changes_data) {
            if ($direction eq 'db_to_result') {
                $self->apply_database_to_result_change($c, $change);
            } elsif ($direction eq 'result_to_db') {
                $self->apply_result_to_database_change($c, $change);
            }
            $applied_changes++;
        }
        
        $c->flash->{success_msg} = "Successfully applied $applied_changes changes.";
        
    } catch {
        my $error = "Error applying changes: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'apply_schema_changes', $error);
        $c->flash->{error_msg} = $error;
    };
}

# Apply change from database to Result file
sub apply_database_to_result_change {
    my ($self, $c, $change) = @_;
    
    # This would update the Result file based on database schema
    # Implementation depends on the specific change type
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'apply_database_to_result_change', 
        "Applying database to Result file change: " . encode_json($change));
}

# Apply change from Result file to database
sub apply_result_to_database_change {
    my ($self, $c, $change) = @_;
    
    # This would update the database schema based on Result file
    # Implementation depends on the specific change type
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'apply_result_to_database_change', 
        "Applying Result file to database change: " . encode_json($change));
}

# Generate Result file from database table
sub generate_result_file {
    my ($self, $c) = @_;
    
    my $table_name = $c->req->param('table_name');
    $table_name =~ s/[^a-zA-Z0-9_]//g if $table_name;

    if (!$table_name) {
        $c->flash->{error_msg} = "No table name specified for Result file generation.";
        return;
    }
    
    try {
        my $db_schema = $self->get_database_table_schema($c, $table_name);
        my $result_file_content = $self->_generate_result_file_content_basic($table_name, $db_schema);
        
        # Save the Result file
        my $result_file_path = $c->path_to('lib', 'Comserv', 'Model', 'Schema', 'Ency', 'Result', ucfirst($table_name) . '.pm');
        write_file($result_file_path, $result_file_content);
        
        $c->flash->{success_msg} = "Result file generated successfully for table '$table_name'.";
        
    } catch {
        my $error = "Error generating Result file: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'generate_result_file', $error);
        $c->flash->{error_msg} = $error;
    };
}

# Generate Result file content from database schema (basic/legacy version)
sub _generate_result_file_content_basic {
    my ($self, $table_name, $db_schema) = @_;
    
    my $class_name = ucfirst($table_name);
    my $content = "package Comserv::Model::Schema::Ency::Result::$class_name;\n";
    $content .= "use base 'DBIx::Class::Core';\n\n";
    $content .= "__PACKAGE__->table('$table_name');\n";
    $content .= "__PACKAGE__->add_columns(\n";
    
    # Add columns
    foreach my $column_name (sort keys %{$db_schema->{columns}}) {
        my $col = $db_schema->{columns}->{$column_name};
        $content .= "    $column_name => {\n";
        $content .= "        data_type => '$col->{data_type}',\n";
        
        if (defined $col->{size}) {
            $content .= "        size => $col->{size},\n";
        }
        
        if ($col->{is_nullable}) {
            $content .= "        is_nullable => 1,\n";
        }
        
        if ($col->{is_auto_increment}) {
            $content .= "        is_auto_increment => 1,\n";
        }
        
        if (defined $col->{default_value}) {
            $content .= "        default_value => '$col->{default_value}',\n";
        }
        
        $content .= "    },\n";
    }
    
    $content .= ");\n";
    
    # Add primary key
    if (@{$db_schema->{primary_keys}}) {
        my $pk_list = join(', ', map { "'$_'" } @{$db_schema->{primary_keys}});
        $content .= "__PACKAGE__->set_primary_key($pk_list);\n";
    }
    
    # Add unique constraints
    foreach my $constraint (@{$db_schema->{unique_constraints}}) {
        my $col_list = join(', ', map { "'$_'" } @{$constraint->{columns}});
        $content .= "__PACKAGE__->add_unique_constraint('$constraint->{name}' => [$col_list]);\n";
    }
    
    $content .= "\n1;\n";
    
    return $content;
}

# Git pull functionality
sub git_pull :Path('/admin/git_pull') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "Starting git_pull action");
    
    my $admin_auth_git = Comserv::Util::AdminAuth->new();
    unless ($admin_auth_git->check_admin_access($c, 'git_pull')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }
    
    # Check if this is a POST request (user confirmed the git pull)
    if ($c->req->method eq 'POST' && $c->req->param('confirm')) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
            "Git pull confirmed, executing");
        
        # Execute the git pull operation
        my ($success, $output, $warning) = $self->execute_git_pull($c);
        
        # Store the results in stash for the template
        $c->stash(
            output => $output,
            success_msg => $success ? "Git pull completed successfully." : undef,
            error_msg => $success ? undef : "Git pull failed. See output for details.",
            warning_msg => $warning
        );
    }
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller git_pull view - Template: admin/git_pull.tt";
    }
    
    # Set the template
    $c->stash(template => 'admin/git_pull.tt');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "Completed git_pull action");
}

# Execute the git pull operation
sub execute_git_pull {
    my ($self, $c) = @_;
    my $output = '';
    my $warning = undef;
    my $success = 0;
    
    # Path to the theme_mappings.json file
    my $theme_mappings_path = $c->path_to('root', 'static', 'config', 'theme_mappings.json');
    my $backup_path = "$theme_mappings_path.bak";
    
    # Check if theme_mappings.json exists
    my $theme_mappings_exists = -e $theme_mappings_path;
    
    try {
        # Backup theme_mappings.json if it exists
        if ($theme_mappings_exists) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
                "Backing up theme_mappings.json");
            copy($theme_mappings_path, $backup_path) or die "Failed to backup theme_mappings.json: $!";
            $output .= "Backed up theme_mappings.json to $backup_path\n";
        }
        
        # Check if there are local changes to theme_mappings.json
        my $has_local_changes = 0;
        if ($theme_mappings_exists) {
            my $git_status = `git -C ${\$c->path_to()} status --porcelain root/static/config/theme_mappings.json`;
            $has_local_changes = $git_status =~ /^\s*[AM]\s+root\/static\/config\/theme_mappings\.json/m;
            
            if ($has_local_changes) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
                    "Local changes detected in theme_mappings.json");
                $output .= "Local changes detected in theme_mappings.json\n";
                
                # Stash the changes
                my $stash_output = `git -C ${\$c->path_to()} stash push -- root/static/config/theme_mappings.json 2>&1`;
                $output .= "Stashed changes: $stash_output\n";
            }
        }
        
        # Execute git pull
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
            "Executing git pull");
        my $pull_output = `git -C ${\$c->path_to()} pull 2>&1`;
        $output .= "Git pull output:\n$pull_output\n";
        
        # Check if pull was successful
        if ($pull_output =~ /Already up to date|Fast-forward|Updating/) {
            $success = 1;
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_pull', 
                "Git pull failed: $pull_output");
            return (0, $output, "Git pull failed. See output for details.");
        }
        
        # Apply stashed changes if needed
        if ($has_local_changes) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
                "Applying stashed changes");
            my $stash_apply_output = `git -C ${\$c->path_to()} stash pop 2>&1`;
            $output .= "Applied stashed changes:\n$stash_apply_output\n";
            
            # Check for conflicts
            if ($stash_apply_output =~ /CONFLICT|error:/) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'execute_git_pull', 
                    "Conflicts detected when applying stashed changes");
                $warning = "Conflicts detected when applying stashed changes. You may need to manually resolve them.";
                
                # Restore from backup
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
                    "Restoring theme_mappings.json from backup");
                copy($backup_path, $theme_mappings_path) or die "Failed to restore from backup: $!";
                $output .= "Restored theme_mappings.json from backup due to conflicts\n";
            }
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
            "Git pull completed successfully");
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_pull', 
            "Error during git pull: $error");
        $output .= "Error: $error\n";
        return (0, $output, undef);
    };
    
    return ($success, $output, $warning);
}

# AJAX endpoint to sync table field to result file
sub sync_table_to_result :Path('/admin/sync_table_to_result') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_table_to_result',
        "Starting sync_table_to_result action");
    
    # Check if the user has admin role (using session-based check like create_table_from_result)
    my $has_admin_role = 0;
    if ($c->session->{username}) {
        if ($c->session->{username} eq 'Shanta') {
            $has_admin_role = 1;
        } else {
            my $roles = $c->session->{roles};
            if (ref($roles) eq 'ARRAY') {
                foreach my $role (@$roles) {
                    if (lc($role) eq 'admin') {
                        $has_admin_role = 1;
                        last;
                    }
                }
            } elsif (defined $roles && !ref($roles) && $roles =~ /\badmin\b/i) {
                $has_admin_role = 1;
            }
        }
    }
    
    unless ($has_admin_role) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied - admin role required' });
        $c->forward('View::JSON');
        return;
    }
    
    # Parse JSON request
    my $json_data;
    try {
        my $body = $c->req->body;
        if ($body) {
            local $/;
            my $json_text = <$body>;
            $json_data = decode_json($json_text);
        } else {
            die "No request body provided";
        }
    } catch {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => "Invalid JSON request: $_" });
        $c->forward('View::JSON');
        return;
    };
    
    my $table_name = $json_data->{table_name};
    my $field_name = $json_data->{field_name};
    my $database = $json_data->{database};
    
    unless ($table_name && $field_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters: table_name, field_name, database' });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_table_to_result',
            "Getting field info for table: $table_name, field: $field_name, database: $database");
        
        # Get table field info
        my $table_field_info = $self->get_table_field_info($c, $table_name, $field_name, $database);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_table_to_result',
            "Field info retrieved: " . Data::Dumper::Dumper($table_field_info));
        
        # Update result file with table values
        my $result = $self->update_result_field_from_table($c, $table_name, $field_name, $database, $table_field_info);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_table_to_result',
            "Result file updated successfully for field: $field_name");
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced table field '$field_name' to result file",
            field_info => $table_field_info
        });
        
    } catch {
        my $error = "Error syncing table to result: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_table_to_result', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

# AJAX endpoint to sync result field to table
sub sync_result_to_table :Path('/admin/sync_result_to_table') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_result_to_table',
        "Starting sync_result_to_table action");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'sync_result_to_table')) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    # Parse JSON request
    my $json_data;
    try {
        my $body = $c->req->body;
        if ($body) {
            local $/;
            my $json_text = <$body>;
            $json_data = decode_json($json_text);
        } else {
            die "No request body provided";
        }
    } catch {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => "Invalid JSON request: $_" });
        $c->forward('View::JSON');
        return;
    };
    
    my $table_name = $json_data->{table_name};
    my $field_name = $json_data->{field_name};
    my $database = $json_data->{database};
    
    unless ($table_name && $field_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters: table_name, field_name, database' });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        # Get result field info
        my $result_field_info = $self->get_result_field_info($c, $table_name, $field_name, $database);
        
        # Update table schema with result values
        my $result = $self->update_table_field_from_result($c, $table_name, $field_name, $database, $result_field_info);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced result field '$field_name' to table",
            field_info => $result_field_info
        });
        
    } catch {
        my $error = "Error syncing result to table: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_result_to_table', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

# Helper method to get table field information
sub get_table_field_info {
    my ($self, $c, $table_name, $field_name, $database) = @_;
    
    my $model_name = $database eq 'ency' ? 'DBEncy' : 'DBForager';
    my $schema = $c->model($model_name)->schema;
    
    # Get table information from database using DESCRIBE (same as get_ency_table_schema)
    my $dbh = $schema->storage->dbh;
    my $sth = $dbh->prepare("DESCRIBE $table_name");
    $sth->execute();
    
    my $field_info;
    while (my $row = $sth->fetchrow_hashref()) {
        if ($row->{Field} eq $field_name) {
            $field_info = {
                data_type => $row->{Type},
                size => undef,  # Will be parsed from Type
                is_nullable => ($row->{Null} eq 'YES' ? 1 : 0),
                is_auto_increment => ($row->{Extra} =~ /auto_increment/i ? 1 : 0),
                default_value => $row->{Default},
                extra => $row->{Extra},
            };
            
            # Parse size from Type (e.g., "varchar(255)" -> 255)
            if ($row->{Type} =~ /\((\d+)\)/) {
                $field_info->{size} = $1;
            }
            last;
        }
    }
    
    unless ($field_info) {
        die "Field '$field_name' not found in table '$table_name'";
    }
    
    return {
        data_type => $field_info->{data_type},
        size => $field_info->{size},
        is_nullable => $field_info->{is_nullable},
        is_auto_increment => $field_info->{is_auto_increment},
        default_value => $field_info->{default_value},
        extra => $field_info->{extra}
    };
}

# Enhanced helper method to normalize data types for comparison
sub normalize_data_type {
    my ($self, $data_type) = @_;
    
    return '' unless defined $data_type;
    
    # Store original for debugging
    my $original_type = $data_type;
    
    # Convert to lowercase for consistent comparison
    $data_type = lc($data_type);
    
    # Remove size specifications and constraints
    # Examples: varchar(255) -> varchar, int(11) -> int, decimal(10,2) -> decimal
    $data_type =~ s/\([^)]*\)//g;
    
    # Remove extra whitespace
    $data_type =~ s/^\s+|\s+$//g;
    
    # Handle unsigned/signed modifiers
    $data_type =~ s/\s+unsigned$//;
    $data_type =~ s/\s+signed$//;
    
    # Remove other common modifiers
    $data_type =~ s/\s+zerofill$//;
    $data_type =~ s/\s+binary$//;
    
    # Comprehensive type mapping for database-specific variations
    my %type_mapping = (
        # Integer types
        'int'           => 'integer',
        'int4'          => 'integer',
        'int8'          => 'bigint',
        'integer'       => 'integer',
        'bigint'        => 'bigint',
        'smallint'      => 'smallint',
        'tinyint'       => 'tinyint',
        'mediumint'     => 'integer',
        
        # String types
        'varchar'       => 'varchar',
        'char'          => 'char',
        'character'     => 'char',
        'text'          => 'text',
        'longtext'      => 'text',
        'mediumtext'    => 'text',
        'tinytext'      => 'text',
        'clob'          => 'text',
        
        # Boolean types
        'bool'          => 'boolean',
        'boolean'       => 'boolean',
        'bit'           => 'boolean',
        
        # Floating point types
        'float'         => 'real',
        'real'          => 'real',
        'double'        => 'double precision',
        'double precision' => 'double precision',
        'decimal'       => 'decimal',
        'numeric'       => 'decimal',
        
        # Date/time types
        'datetime'      => 'datetime',
        'timestamp'     => 'timestamp',
        'date'          => 'date',
        'time'          => 'time',
        'year'          => 'year',
        
        # Binary types
        'blob'          => 'blob',
        'longblob'      => 'blob',
        'mediumblob'    => 'blob',
        'tinyblob'      => 'blob',
        'binary'        => 'binary',
        'varbinary'     => 'varbinary',
        
        # JSON and other modern types
        'json'          => 'json',
        'jsonb'         => 'json',
        'uuid'          => 'uuid',
        'enum'          => 'enum',
        'set'           => 'set',
    );
    
    # Apply mapping or return normalized type
    my $normalized_type = $type_mapping{$data_type} || $data_type;
    
    return $normalized_type;
}

# Helper method to get result field information
sub get_result_field_info {
    my ($self, $c, $table_name, $field_name, $database) = @_;
    
    # Build result file path
    my $result_table_mapping = $self->build_result_table_mapping($c, $database);
    my $result_file_path;
    
    # Find the result file for this table (mapping key is lowercase table name)
    my $table_key = lc($table_name);
    if (exists $result_table_mapping->{$table_key}) {
        $result_file_path = $result_table_mapping->{$table_key}->{result_path};
    }
    
    unless ($result_file_path && -f $result_file_path) {
        my $error_msg = "Result file not found for table '$table_name'";
        
        # Add debug information if debug mode is enabled
        if ($c->session->{debug_mode}) {
            my $debug_info = "\nDEBUG INFO (get_result_field_info):\n";
            $debug_info .= "Table key searched: '$table_key'\n";
            $debug_info .= "Available tables: " . join(', ', keys %$result_table_mapping) . "\n";
            $debug_info .= "Result file path: " . ($result_file_path || 'undefined') . "\n";
            if ($result_file_path) {
                $debug_info .= "File exists: " . (-f $result_file_path ? 'YES' : 'NO') . "\n";
            }
            $error_msg .= $debug_info;
        }
        
        die $error_msg;
    }
    
    # Read and parse the result file
    my $content = read_file($result_file_path);
    
    # Parse the add_columns section to find the field
    if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
        my $columns_section = $1;
        
        my $field_info = {};

        # Helper: parse attributes from a field definition block.
        # Handles one level of nested braces (e.g. extra => { list => [...] } for ENUM).
        my $parse_field_def = sub {
            my ($field_def) = @_;
            my %info;
            if ($field_def =~ /data_type\s*=>\s*["']([^"']+)["']/) {
                $info{data_type} = $1;
            }
            if ($field_def =~ /size\s*=>\s*(\d+)/) {
                $info{size} = $1;
            }
            if ($field_def =~ /is_nullable\s*=>\s*([01])/) {
                $info{is_nullable} = $1;
            }
            if ($field_def =~ /is_auto_increment\s*=>\s*([01])/) {
                $info{is_auto_increment} = $1;
            }
            if ($field_def =~ /default_value\s*=>\s*["']([^"']*)["']/) {
                $info{default_value} = $1;
            }
            # Extract ENUM list from: extra => { list => [qw/val1 val2 .../] }
            if ($field_def =~ /extra\s*=>\s*\{[^}]*list\s*=>\s*\[qw.([^\]\/!|]+)[\/!|>)]\]/s) {
                $info{enum_list} = [ split /\s+/, $1 ];
            }
            return \%info;
        };

        # Regex that matches a brace-delimited block allowing one level of nesting.
        # Handles: extra => { list => [...] }  inside the field definition.
        my $block_re = qr/\{((?:[^{}]|\{[^{}]*\})*)\}/s;

        # Try hash format first: field_name => { ... }
        if ($columns_section =~ /(?:^|\s|,)\s*'?$field_name'?\s*=>?\s*$block_re/s) {
            $field_info = $parse_field_def->($1);
            return $field_info if %$field_info;
        }

        # Try array format: "field_name", { ... }
        if ($columns_section =~ /["']$field_name["']\s*,\s*$block_re/s) {
            $field_info = $parse_field_def->($1);
            return $field_info if %$field_info;
        }
    }
    
    my $error_msg = "Field '$field_name' not found in result file";
    
    # Add debug information if debug mode is enabled
    if ($c->session->{debug_mode}) {
        my $debug_info = "\nDEBUG INFO (get_result_field_info - field parsing):\n";
        $debug_info .= "Field name searched: '$field_name'\n";
        $debug_info .= "Result file path: '$result_file_path'\n";
        
        # Show a snippet of the add_columns section for debugging
        if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
            my $columns_section = $1;
            my $snippet = substr($columns_section, 0, 500);
            $snippet .= "..." if length($columns_section) > 500;
            $debug_info .= "add_columns section (first 500 chars): $snippet\n";
        } else {
            $debug_info .= "No add_columns section found in result file\n";
        }
        
        $error_msg .= $debug_info;
    }
    
    die $error_msg;
}

# Helper method to update result file with table field values
sub update_result_field_from_table {
    my ($self, $c, $table_name, $field_name, $database, $table_field_info) = @_;
    
    # Build result file path
    my $result_table_mapping = $self->build_result_table_mapping($c, $database);
    my $result_file_path;
    
    # Find the result file for this table (mapping key is lowercase table name)
    my $table_key = lc($table_name);
    if (exists $result_table_mapping->{$table_key}) {
        $result_file_path = $result_table_mapping->{$table_key}->{result_path};
    }
    
    unless ($result_file_path && -f $result_file_path) {
        my $error_msg = "Result file not found for table '$table_name'";
        
        # Add debug information if debug mode is enabled
        if ($c->session->{debug_mode}) {
            my $debug_info = "\nDEBUG INFO (update_result_field_from_table):\n";
            $debug_info .= "Table key searched: '$table_key'\n";
            $debug_info .= "Available tables: " . join(', ', keys %$result_table_mapping) . "\n";
            $debug_info .= "Result file path: " . ($result_file_path || 'undefined') . "\n";
            if ($result_file_path) {
                $debug_info .= "File exists: " . (-f $result_file_path ? 'YES' : 'NO') . "\n";
            }
            $error_msg .= $debug_info;
        }
        
        die $error_msg;
    }
    
    # Read the result file
    my $content = read_file($result_file_path);
    
    # Build new field definition
    my $new_field_def = "{\n        data_type => '$table_field_info->{data_type}'";
    
    if ($table_field_info->{size}) {
        $new_field_def .= ",\n        size => $table_field_info->{size}";
    }
    
    if ($table_field_info->{is_nullable}) {
        $new_field_def .= ",\n        is_nullable => 1";
    }
    
    if ($table_field_info->{is_auto_increment}) {
        $new_field_def .= ",\n        is_auto_increment => 1";
    }
    
    if (defined $table_field_info->{default_value}) {
        my $default = $table_field_info->{default_value};
        
        # Handle special timestamp defaults (scalar refs)
        if ($default =~ /CURRENT_TIMESTAMP/i) {
            if ($default =~ /ON UPDATE/i) {
                $new_field_def .= ",\n        default_value => \\'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'";
            } else {
                $new_field_def .= ",\n        default_value => \\'CURRENT_TIMESTAMP'";
            }
        }
        # Handle NULL default
        elsif (!defined $default || $default eq '') {
            # Skip - NULL is default when is_nullable => 1
        }
        # Handle numeric defaults
        elsif ($default =~ /^\d+$/) {
            $new_field_def .= ",\n        default_value => $default";
        }
        # Handle string defaults
        else {
            $default =~ s/'/\\'/g;  # Escape single quotes
            $new_field_def .= ",\n        default_value => '$default'";
        }
    }
    
    $new_field_def .= ",\n    }";
    
    # Update the field definition in the content
    if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
        my $columns_section = $1;
        my $updated = 0;
        
        # Try hash format: field_name => { ... } (handles multiline)
        # Match field_name => { ... } where { ... } can span multiple lines
        if ($columns_section =~ /(?:^|\n|\s|,)\s*'?$field_name'?\s*=>\s*\{.*?\}/s) {
            $columns_section =~ s/(?:^|\n|\s|,)\s*'?$field_name'?\s*=>\s*\{.*?\}/$field_name => $new_field_def/s;
            $updated = 1;
        }
        # Try array format: "field_name", { ... } (handles multiline)
        elsif ($columns_section =~ /["']$field_name["']\s*,\s*\{.*?\}/s) {
            $columns_section =~ s/["']$field_name["']\s*,\s*\{.*?\}/"$field_name", $new_field_def/s;
            $updated = 1;
        }
        # If not found, append it to the columns section
        else {
            # Find the last field definition to insert after
            if ($columns_section =~ /,\s*$/s) {
                $columns_section .= "\n    $field_name => $new_field_def";
            } else {
                $columns_section .= ",\n    $field_name => $new_field_def";
            }
            $updated = 1;
        }
        
        if ($updated) {
            # Replace in the full content
            $content =~ s/__PACKAGE__->add_columns\(\s*.*?\s*\);/__PACKAGE__->add_columns($columns_section\n);/s;
            
            # Write back to file
            write_file($result_file_path, $content);
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_result_field_from_table',
                "Updated field '$field_name' in result file '$result_file_path'");
            
            return 1;
        }
    }
    
    my $error_msg = "Could not update field '$field_name' in result file";
    
    # Add debug information if debug mode is enabled
    if ($c->session->{debug_mode}) {
        my $debug_info = "\nDEBUG INFO (update_result_field_from_table - field update):\n";
        $debug_info .= "Field name to update: '$field_name'\n";
        $debug_info .= "Result file path: '$result_file_path'\n";
        $debug_info .= "New field definition: $new_field_def\n";
        
        # Show a snippet of the add_columns section for debugging
        if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
            my $columns_section = $1;
            my $snippet = substr($columns_section, 0, 500);
            $snippet .= "..." if length($columns_section) > 500;
            $debug_info .= "add_columns section (first 500 chars): $snippet\n";
        } else {
            $debug_info .= "No add_columns section found in result file\n";
        }
        
        $error_msg .= $debug_info;
    }
    
    die $error_msg;
}

# Helper method to update table schema with result field values
sub update_table_field_from_result {
    my ($self, $c, $table_name, $field_name, $database, $result_field_info) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_table_field_from_result',
        "Adding/modifying column '$field_name' in table '$table_name' (db=$database)");

    my $dbh;
    if (lc($database) eq 'ency') {
        $dbh = $c->model('DBEncy')->schema->storage->dbh;
    } elsif (lc($database) eq 'forager') {
        $dbh = $c->model('DBForager')->schema->storage->dbh;
    } else {
        die "Unknown database '$database'";
    }

    my $data_type    = uc($result_field_info->{data_type} || 'VARCHAR');
    my $size         = $result_field_info->{size};
    my $is_nullable  = $result_field_info->{is_nullable};
    my $is_auto_inc  = $result_field_info->{is_auto_increment};
    my $default_val  = $result_field_info->{default_value};

    my $col_def = "`$field_name` ";

    if ($data_type eq 'INTEGER' || $data_type eq 'INT') {
        $col_def .= 'INT';
    } elsif ($data_type eq 'VARCHAR') {
        $col_def .= 'VARCHAR(' . ($size || 255) . ')';
    } elsif ($data_type eq 'TEXT') {
        $col_def .= 'TEXT';
    } elsif ($data_type eq 'TINYINT') {
        $col_def .= 'TINYINT';
    } elsif ($data_type eq 'BIGINT') {
        $col_def .= 'BIGINT';
    } elsif ($data_type eq 'TIMESTAMP') {
        $col_def .= 'TIMESTAMP';
    } elsif ($data_type eq 'DATETIME') {
        $col_def .= 'DATETIME';
    } elsif ($data_type eq 'DATE') {
        $col_def .= 'DATE';
    } elsif ($data_type eq 'BOOLEAN') {
        $col_def .= 'TINYINT(1)';
    } elsif ($data_type eq 'ENUM') {
        my $enum_list = $result_field_info->{enum_list};
        unless ($enum_list && ref($enum_list) eq 'ARRAY' && @$enum_list) {
            die "ENUM field '$field_name' has no list values in Result class (extra => { list => [...] } missing)";
        }
        my $values = join(',', map { "'$_'" } @$enum_list);
        $col_def .= "ENUM($values)";
    } else {
        $col_def .= $data_type;
        $col_def .= "($size)" if $size;
    }

    if ($is_auto_inc) {
        $col_def .= ' NOT NULL AUTO_INCREMENT';
    } elsif (defined $is_nullable && !$is_nullable) {
        $col_def .= ' NOT NULL';
    } else {
        $col_def .= ' NULL';
    }

    if (defined $default_val && $default_val ne '') {
        $col_def .= " DEFAULT '$default_val'";
    }

    my $check_sth = $dbh->prepare(
        "SELECT COUNT(*) FROM information_schema.COLUMNS " .
        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?"
    );
    $check_sth->execute($table_name, $field_name);
    my ($exists) = $check_sth->fetchrow_array;

    if ($is_auto_inc) {
        eval { $dbh->do("ALTER TABLE `$table_name` DROP PRIMARY KEY") };
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_table_field_from_result',
            "Dropped existing primary key (if any): $@") if $@;
    }

    my $sql;
    if ($exists) {
        $sql = "ALTER TABLE `$table_name` MODIFY COLUMN $col_def";
    } else {
        $sql = "ALTER TABLE `$table_name` ADD COLUMN $col_def";
    }

    if ($is_auto_inc) {
        $sql .= ", ADD PRIMARY KEY (`$field_name`)";
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_table_field_from_result',
        "Executing SQL: $sql");

    $dbh->do($sql);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_table_field_from_result',
        "Successfully executed: $sql");

    return 1;
}

sub create_table_from_result :Path('/admin/create_table_from_result') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
        "Starting create_table_from_result action");
    
    my $has_admin_role = 0;
    if ($c->session->{username}) {
        if ($c->session->{username} eq 'Shanta') {
            $has_admin_role = 1;
        } else {
            my $roles = $c->session->{roles};
            if (ref($roles) eq 'ARRAY') {
                foreach my $role (@$roles) {
                    if (lc($role) eq 'admin') {
                        $has_admin_role = 1;
                        last;
                    }
                }
            } elsif (defined $roles && !ref($roles) && $roles =~ /\badmin\b/i) {
                $has_admin_role = 1;
            }
        }
    }
    
    unless ($has_admin_role) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    my $result_class = $c->req->param('result_class');
    my $database = $c->req->param('database') || 'ency';
    
    unless ($result_class) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameter: result_class' });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        my $sql_statements = $self->generate_create_table_sql($c, $result_class, $database);
        
        my $schema;
        if (lc($database) eq 'ency') {
            $schema = $c->model('DBEncy')->schema;
        } elsif (lc($database) eq 'forager') {
            $schema = $c->model('DBForager')->schema;
        } else {
            die "Invalid database: $database";
        }
        
        unless ($schema) {
            die "Failed to get database schema for $database";
        }
        
        my $dbh = $schema->storage->dbh;
        my @executed = ();
        my @errors = ();
        
        foreach my $sql (@$sql_statements) {
            try {
                $dbh->do($sql);
                push @executed, $sql;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
                    "Executed SQL: $sql");
            } catch {
                my $error = "Failed to execute SQL: $sql - Error: $_";
                push @errors, $error;
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_table_from_result', $error);
            };
        }
        
        if (@errors) {
            $c->stash(json => { 
                success => 0, 
                error => 'Some SQL statements failed',
                executed => \@executed,
                errors => \@errors,
                sql_statements => $sql_statements
            });
        } else {
            $c->stash(json => { 
                success => 1, 
                message => "Successfully created table from $result_class",
                executed => \@executed,
                sql_statements => $sql_statements
            });
        }
        
    } catch {
        my $error = "Error creating table from Result: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_table_from_result', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

sub generate_create_table_sql {
    my ($self, $c, $result_class, $database) = @_;
    
    my $result_file_path = $self->find_result_file($c, $result_class, $database);
    unless ($result_file_path && -f $result_file_path) {
        die "Result file not found for $result_class in database $database";
    }
    
    my $schema = $self->parse_result_file_schema($c, $result_file_path);
    unless ($schema && $schema->{table_name}) {
        die "Failed to parse schema from Result file: $result_file_path";
    }
    
    my $table_name = $schema->{table_name};
    my @sql_statements = ();
    
    my $create_sql = "CREATE TABLE IF NOT EXISTS `$table_name` (\n";
    my @column_defs = ();
    my @indexes = ();
    my @constraints = ();
    
    foreach my $col_name (sort keys %{$schema->{columns}}) {
        my $col = $schema->{columns}->{$col_name};
        my $col_def = "  `$col_name` ";
        
        my $data_type = uc($col->{data_type});
        if ($data_type eq 'INTEGER') {
            $col_def .= 'INT';
        } elsif ($data_type eq 'VARCHAR') {
            my $size = $col->{size} || 255;
            $col_def .= "VARCHAR($size)";
        } elsif ($data_type eq 'TEXT') {
            $col_def .= 'TEXT';
        } elsif ($data_type eq 'TIMESTAMP') {
            $col_def .= 'TIMESTAMP';
        } elsif ($data_type eq 'DATETIME') {
            $col_def .= 'DATETIME';
        } elsif ($data_type eq 'DATE') {
            $col_def .= 'DATE';
        } elsif ($data_type eq 'TIME') {
            $col_def .= 'TIME';
        } elsif ($data_type eq 'BOOLEAN') {
            $col_def .= 'BOOLEAN';
        } elsif ($data_type eq 'ENUM') {
            if ($col->{extra} && $col->{extra}->{list}) {
                my $values = join(',', map { "'$_'" } @{$col->{extra}->{list}});
                $col_def .= "ENUM($values)";
            } else {
                $col_def .= "VARCHAR(50)";
            }
        } else {
            $col_def .= $data_type;
        }
        
        if ($col->{is_nullable} == 0 || !$col->{is_nullable}) {
            $col_def .= ' NOT NULL';
        }
        
        if ($col->{is_auto_increment}) {
            $col_def .= ' AUTO_INCREMENT';
        }
        
        if (defined $col->{default_value}) {
            my $default = $col->{default_value};
            if (ref($default) eq 'SCALAR') {
                $col_def .= " DEFAULT $$default";
            } elsif ($default =~ /^CURRENT_TIMESTAMP$/i) {
                $col_def .= " DEFAULT CURRENT_TIMESTAMP";
            } else {
                $col_def .= " DEFAULT '$default'";
            }
        }
        
        push @column_defs, $col_def;
    }
    
    if ($schema->{primary_key}) {
        my @pk_cols = ref($schema->{primary_key}) eq 'ARRAY' 
            ? @{$schema->{primary_key}} 
            : ($schema->{primary_key});
        my $pk_cols_str = join(', ', map { "`$_`" } @pk_cols);
        push @constraints, "  PRIMARY KEY ($pk_cols_str)";
    }
    
    if ($schema->{unique_constraints}) {
        foreach my $constraint_name (keys %{$schema->{unique_constraints}}) {
            my $cols = $schema->{unique_constraints}->{$constraint_name};
            my $cols_str = join(', ', map { "`$_`" } @$cols);
            push @constraints, "  UNIQUE KEY `$constraint_name` ($cols_str)";
        }
    }
    
    if ($schema->{indexes}) {
        foreach my $index_name (keys %{$schema->{indexes}}) {
            my $cols = $schema->{indexes}->{$index_name};
            my $cols_str = join(', ', map { "`$_`" } @$cols);
            push @indexes, "  KEY `$index_name` ($cols_str)";
        }
    }
    
    $create_sql .= join(",\n", @column_defs, @constraints, @indexes);
    $create_sql .= "\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;";
    
    push @sql_statements, $create_sql;
    
    if ($schema->{relationships}) {
        foreach my $rel_name (keys %{$schema->{relationships}}) {
            my $rel = $schema->{relationships}->{$rel_name};
            if ($rel->{type} eq 'belongs_to') {
                my $foreign_key = $rel->{foreign_key};
                my $foreign_table = $rel->{foreign_table};
                my $foreign_column = $rel->{foreign_column} || 'id';
                my $on_delete = $rel->{on_delete} || 'RESTRICT';
                
                my $fk_sql = "ALTER TABLE `$table_name` ADD CONSTRAINT `fk_${table_name}_${foreign_key}` ";
                $fk_sql .= "FOREIGN KEY (`$foreign_key`) REFERENCES `$foreign_table` (`$foreign_column`) ";
                $fk_sql .= "ON DELETE " . uc($on_delete) . ";";
                
                push @sql_statements, $fk_sql;
            }
        }
    }
    
    return \@sql_statements;
}

# AJAX endpoint to create a Result file from a database table
sub create_result_from_table :Path('/admin/create_result_from_table') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_result_from_table',
        "Starting create_result_from_table action");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'create_result_from_table')) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    # Parse JSON request
    my $json_data;
    try {
        my $body = $c->req->body;
        if ($body) {
            local $/;
            my $json_text = <$body>;
            $json_data = decode_json($json_text);
        } else {
            die "No request body provided";
        }
    } catch {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => "Invalid JSON request: $_" });
        $c->forward('View::JSON');
        return;
    };
    
    my $table_name = $json_data->{table_name};
    my $database = $json_data->{database};
    
    # Debug logging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_result_from_table',
        "Received parameters - table_name: " . ($table_name || 'UNDEFINED') . 
        ", database: " . ($database || 'UNDEFINED') . 
        ", JSON data: " . Data::Dumper::Dumper($json_data));
    
    unless ($table_name && $database) {
        my $error_msg = 'Missing required parameters: ';
        $error_msg .= 'table_name' unless $table_name;
        $error_msg .= ', database' unless $database;
        $error_msg .= " (received: table_name=" . ($table_name || 'UNDEFINED') . 
                     ", database=" . ($database || 'UNDEFINED') . ")";
        
        $c->response->status(400);
        $c->stash(json => { success => 0, error => $error_msg });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        # Get table schema from database
        my $table_schema;
        if ($database eq 'ency') {
            $table_schema = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $table_schema = $self->get_forager_table_schema($c, $table_name);
        } else {
            die "Invalid database: $database";
        }
        
        unless ($table_schema && $table_schema->{columns}) {
            die "Could not retrieve schema for table '$table_name' from database '$database'";
        }
        
        # Generate Result file content
        my $result_content = $self->generate_result_file_content($c, $table_name, $database, $table_schema);
        
        # Determine Result file path
        my $result_file_path = $self->get_result_file_path($c, $table_name, $database);
        
        # Create directory if it doesn't exist
        my $result_dir = dirname($result_file_path);
        unless (-d $result_dir) {
            make_path($result_dir) or die "Could not create directory '$result_dir': $!";
        }
        
        # Write Result file
        write_file($result_file_path, $result_content);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_result_from_table',
            "Successfully created Result file '$result_file_path' for table '$table_name'");
        
        $c->stash(json => {
            success => 1,
            message => "Successfully created Result file for table '$table_name'",
            result_file_path => $result_file_path,
            table_name => $table_name,
            database => $database
        });
        
    } catch {
        my $error = "Error creating Result file: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_result_from_table', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

# Helper method to generate Result file content from table schema
sub generate_result_file_content {
    my ($self, $c, $table_name, $database, $table_schema) = @_;
    
    # Convert table name to proper case for class name
    my $class_name = $self->table_name_to_class_name($table_name);
    
    # Determine the proper database namespace
    my $namespace = $database eq 'ency' ? 'Ency' : 'Forager';
    
    my $content = "package Comserv::Model::Schema::${namespace}::Result::${class_name};\n";
    $content .= "use base 'DBIx::Class::Core';\n\n";
    
    # Add table name
    $content .= "__PACKAGE__->table('$table_name');\n";
    
    # Add columns
    $content .= "__PACKAGE__->add_columns(\n";
    
    my @column_definitions;
    foreach my $column_name (sort keys %{$table_schema->{columns}}) {
        my $column_info = $table_schema->{columns}->{$column_name};
        
        my $column_def = "    $column_name => {\n";
        $column_def .= "        data_type => '$column_info->{data_type}',\n";
        
        if ($column_info->{size}) {
            $column_def .= "        size => $column_info->{size},\n";
        }
        
        if ($column_info->{is_nullable}) {
            $column_def .= "        is_nullable => 1,\n";
        }
        
        if ($column_info->{is_auto_increment}) {
            $column_def .= "        is_auto_increment => 1,\n";
        }
        
        if (defined $column_info->{default_value} && $column_info->{default_value} ne '') {
            $column_def .= "        default_value => '$column_info->{default_value}',\n";
        }
        
        $column_def .= "    }";
        push @column_definitions, $column_def;
    }
    
    $content .= join(",\n", @column_definitions) . "\n";
    $content .= ");\n\n";
    
    # Add primary key if available
    if ($table_schema->{primary_keys} && @{$table_schema->{primary_keys}}) {
        my $pk_list = join("', '", @{$table_schema->{primary_keys}});
        $content .= "__PACKAGE__->set_primary_key('$pk_list');\n\n";
    }
    
    # Add relationships placeholder (can be filled in manually later)
    $content .= "# Add relationships here\n";
    $content .= "# Example:\n";
    $content .= "# __PACKAGE__->belongs_to(\n";
    $content .= "#     'related_table',\n";
    $content .= "#     'Comserv::Model::Schema::${namespace}::Result::RelatedTable',\n";
    $content .= "#     'foreign_key_column'\n";
    $content .= "# );\n\n";
    
    $content .= "1;\n";
    
    return $content;
}

=head2 Docker Container Management Routes

=cut

sub _docker_env {
    my $home = $ENV{HOME} || '/home/shanta';
    my @candidates = (
        '/var/run/docker.sock',
        "$home/.docker/desktop/docker.sock",
        '/run/user/1000/docker.sock',
    );
    for my $sock (@candidates) {
        return "DOCKER_HOST=unix://$sock" if -S $sock;
    }
    return '';
}

sub _docker_bin {
    return '/usr/local/bin/docker' if -x '/usr/local/bin/docker';
    return '/usr/bin/docker'       if -x '/usr/bin/docker';
    return 'docker';
}

sub _ssh_auth_is_failure {
    my ($output) = @_;
    return 1 if $output =~ /Permission denied \(publickey|Authentication failed|Could not authenticate|sshpass:.*(denied|incorrect|failure)/i;
    return 0;
}

sub _run_ssh_cmd {
    my ($self, $c, $host_cmd, $ssh_host, $ssh_user) = @_;
    return ('ERROR: SSH host not specified', 1) unless $ssh_host;

    my ($resolved_host, $default_user, $ssh_port, $ssh_password) = $self->_resolve_ssh_target($ssh_host);
    $ssh_host   = $resolved_host || $ssh_host;
    $ssh_user ||= $default_user || 'ubuntu';
    $ssh_port   = int($ssh_port || 22);
    $ssh_port   = 22 unless $ssh_port > 0 && $ssh_port <= 65535;

    unless ($ssh_host =~ /^[a-zA-Z0-9_\-\.]+$/) {
        return ("ERROR: Invalid host format", 1);
    }

    my @ssh_opts = ('-p', $ssh_port, '-o', 'ConnectTimeout=12', '-o', 'StrictHostKeyChecking=no');
    my $escaped_cmd = $host_cmd;
    $escaped_cmd =~ s/'/'\\''/g;

    # Try SSH key first (no password in command line)
    my $key_out = `ssh @ssh_opts -o BatchMode=yes -o IdentitiesOnly=yes $ssh_user\@$ssh_host '$escaped_cmd' 2>&1`;
    my $key_exit = $? >> 8;
    return ($key_out, $key_exit) if $key_exit == 0;
    return ($key_out, $key_exit) unless _ssh_auth_is_failure($key_out);

    if (!$ssh_password) {
        return ("ERROR: SSH auth failed for $ssh_user\@$ssh_host and no password in ~/.comserv/secrets/ssh_credentials.json\n$key_out", 1);
    }

    local $ENV{SSHPASS} = $ssh_password;
    my $pw_out = `sshpass -e ssh @ssh_opts $ssh_user\@$ssh_host '$escaped_cmd' 2>&1`;
    my $pw_exit = $? >> 8;
    return ($pw_out, $pw_exit);
}

sub _run_ssh_stdin_cmd {
    my ($self, $ssh_host, $ssh_user, $remote_cmd, $stdin) = @_;
    return ('ERROR: SSH host not specified', 1) unless $ssh_host;

    my ($resolved_host, $default_user, $ssh_port, $ssh_password) = $self->_resolve_ssh_target($ssh_host);
    $ssh_host   = $resolved_host || $ssh_host;
    $ssh_user ||= $default_user || 'ubuntu';
    $ssh_port   = int($ssh_port || 22);
    $ssh_port   = 22 unless $ssh_port > 0 && $ssh_port <= 65535;

    unless ($ssh_host =~ /^[a-zA-Z0-9_\-\.]+$/) {
        return ("ERROR: Invalid host format", 1);
    }

    my $escaped_cmd = $remote_cmd;
    $escaped_cmd =~ s/'/'\\''/g;
    my @ssh_base = ('-p', $ssh_port, '-o', 'ConnectTimeout=12', '-o', 'StrictHostKeyChecking=no');

    my $run = sub {
        my ($use_pass) = @_;
        my @cmd = $use_pass
            ? ('sshpass', '-e', 'ssh', @ssh_base, "$ssh_user\@$ssh_host", $remote_cmd)
            : ('ssh', @ssh_base, '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', "$ssh_user\@$ssh_host", $remote_cmd);
        local $ENV{SSHPASS} = $ssh_password if $use_pass;
        open my $pipe, '|-', @cmd or return ("ERROR: cannot open ssh pipe: $!", 1);
        if (defined $stdin && length $stdin) {
            print $pipe $stdin;
        }
        close $pipe;
        my $exit = $? >> 8;
        return ('', $exit);
    };

    my ($out, $exit) = $run->(0);
    return ($out, $exit) if $exit == 0;

    return ("ERROR: SSH auth failed for $ssh_user\@$ssh_host (key-based)", $exit)
        unless $ssh_password;

    return $run->(1);
}

sub _install_device_agent_via_ssh {
    my ($self, $ssh_host, $ssh_user, $b64, $ingest_url, $ingest_token, $hostname_override) = @_;
    $b64 =~ s/\s+//g;

    my ($bin, $log, $upload_cmd);
    if ($ssh_user && $ssh_user eq 'root') {
        $bin = '/usr/local/bin/device_agent.sh';
        $log = '/var/log/comserv_device_agent.log';
        $upload_cmd = "mkdir -p /usr/local/bin && base64 -d > $bin && chmod +x $bin && echo Uploaded";
    } else {
        $bin = '$HOME/bin/device_agent.sh';
        $log = '$HOME/comserv_device_agent.log';
        $upload_cmd = 'mkdir -p "$HOME/bin" && base64 -d > "$HOME/bin/device_agent.sh" && chmod +x "$HOME/bin/device_agent.sh" && echo Uploaded';
    }

    my ($out1, $exit1) = $self->_run_ssh_stdin_cmd($ssh_host, $ssh_user, $upload_cmd, $b64);
    return ("SSH upload failed (exit $exit1). Check SSH credentials for $ssh_user\@$ssh_host.", $exit1) if $exit1 != 0;

    my $cron_line = sprintf(
        '*/5 * * * * INGEST_URL=%s INGEST_TOKEN=%s HOSTNAME_OVERRIDE=%s %s >> %s 2>&1',
        $ingest_url, $ingest_token, $hostname_override, $bin, $log,
    );
    $cron_line =~ s/'/'\\''/g;

    my $cron_cmd = join(' && ',
        "(crontab -l 2>/dev/null | grep -v device_agent.sh; echo '$cron_line') | crontab -",
        'echo "Cron installed"',
    );
    my ($out2, $exit2) = $self->_run_ssh_cmd(undef, $cron_cmd, $ssh_host, $ssh_user);
    return (join("\n", grep { defined && length } ($out1, $out2)), $exit2) if $exit2 != 0;

    my $test_cmd = "INGEST_URL='$ingest_url' INGEST_TOKEN='$ingest_token' HOSTNAME_OVERRIDE='$hostname_override' $bin || echo 'WARN: test run failed (cron will retry every 5 min)'";
    my ($out3, $exit3) = $self->_run_ssh_cmd(undef, $test_cmd, $ssh_host, $ssh_user);
    my $output = join("\n", grep { defined && length } ($out1, $out2, $out3));
    $output .= "\nInstalled on $ssh_user\@$ssh_host — agent cron active (every 5 min)."
        if $exit2 == 0;
    if ($exit3 != 0) {
        $output .= "\nNote: immediate test ingest failed; verify $ingest_url is reachable from $ssh_host.";
    }
    return ($output, 0);
}

sub _run_host_cmd_on_target {
    my ($self, $c, $host_cmd, $target) = @_;
    
    $target //= $c->req->params->{target} || 'workstation';
    $target = lc($target);
    
    if ($target eq 'workstation') {
        my $output = `$host_cmd 2>&1`;
        my $exit_code = $? >> 8;
        return ($output, $exit_code);
    }

    my ($ssh_host, $ssh_user, $ssh_port, $ssh_password) = $self->_resolve_ssh_target($target);
    unless ($ssh_host) {
        return ("ERROR: Unknown target '$target'", 1);
    }
    if (!$ssh_password) {
        return ("ERROR: SSH password required. Use Test Connection to save credentials first.", 1);
    }
    unless ($ssh_host =~ /^[a-zA-Z0-9_\-\.]+$/) {
        return ("ERROR: Invalid host format", 1);
    }

    my $escaped_cmd = $host_cmd;
    $escaped_cmd =~ s/'/'\\''/g;

    local $ENV{SSHPASS} = $ssh_password;
    my $cmd = qq(sshpass -e ssh -p $ssh_port -o ConnectTimeout=5 -o StrictHostKeyChecking=no $ssh_user\@$ssh_host '$escaped_cmd' 2>&1);
    my $output = `$cmd`;
    my $exit_code = $? >> 8;

    return ($output, $exit_code);
}

sub _run_docker_on_target {
    my ($self, $c, $docker_cmd, $target) = @_;
    
    $target //= $c->req->params->{target} || 'workstation';
    $target = lc($target);
    
    if ($target eq 'workstation') {
        my $denv  = _docker_env();
        my $docker = _docker_bin();
        return $self->_run_host_cmd_on_target($c, "$denv $docker $docker_cmd", $target);
    } else {
        return $self->_run_host_cmd_on_target($c, "docker $docker_cmd", $target);
    }
}

sub _query_system_diagnostics {
    my ($self, $c, $target) = @_;
    
    # 1. Docker Compose status
    my ($compose_out, $compose_code) = $self->_run_host_cmd_on_target($c, "docker compose version 2>&1 || docker-compose version 2>&1 || echo 'Not installed'", $target);
    chomp($compose_out);
    
    # 2. Starman process status
    my ($starman_out, $starman_code) = $self->_run_host_cmd_on_target($c, "ps aux | grep -i starman | grep -v grep || echo 'No starman processes found'", $target);
    
    # 3. Port bindings
    my ($ports_out, $ports_code) = $self->_run_host_cmd_on_target($c, "ss -tln || netstat -tln || echo 'Network utilities not available'", $target);
    my @active_ports;
    for my $line (split(/\n/, $ports_out)) {
        if ($line =~ /(?:^|[\s:])(5000|3000|3001)(?:\s|$|:)/) {
            push @active_ports, $1 unless grep { $_ eq $1 } @active_ports;
        }
    }
    
    # 4. Git status & log
    my $git_cmd = '';
    if ($target eq 'workstation') {
        $git_cmd = "git status -sb && echo '---' && git log -1 --format='%h - %an, %ar : %s'";
    } else {
        $git_cmd = "cd /opt/comserv/Comserv 2>/dev/null && git status -sb && echo '---' && git log -1 --format='%h - %an, %ar : %s' || echo 'Directory /opt/comserv/Comserv not found or not a git repo'";
    }
    my ($git_out, $git_code) = $self->_run_host_cmd_on_target($c, $git_cmd, $target);
    
    # 5. Backup images list
    my ($backups_out, $backups_code) = $self->_run_host_cmd_on_target($c, "docker images --format '{{.Repository}}:{{.Tag}} ({{.ID}})' | grep shantamcsbain/comserv-web-prod || echo 'No images found'", $target);
    my @backups;
    for my $line (split(/\n/, $backups_out)) {
        chomp($line);
        if ($line =~ /comserv-web-prod/i && $line !~ /latest/i) {
            push @backups, $line;
        }
    }
    
    # 6. Host stats
    my ($disk_out) = $self->_run_host_cmd_on_target($c, "df -h / | tail -n 1", $target);
    chomp($disk_out);
    my ($mem_out) = $self->_run_host_cmd_on_target($c, "free -m | grep Mem", $target);
    chomp($mem_out);
    my ($uptime_out) = $self->_run_host_cmd_on_target($c, "uptime", $target);
    chomp($uptime_out);
    
    return {
        compose_status  => $compose_out,
        starman_status  => $starman_out,
        active_ports    => \@active_ports,
        git_status      => $git_out,
        backups         => \@backups,
        disk            => $disk_out,
        memory          => $mem_out,
        uptime          => $uptime_out,
    };
}

sub docker :Path('/admin/docker') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker',
        "Docker overview page accessed by user: " . ($c->session->{username} || 'unknown'));

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'docker',
            "Access denied for docker overview");
        $c->response->status(403);
        $c->stash(template => 'admin/error.tt', error => 'Access denied');
        return;
    }

    $c->stash(
        template => 'admin/docker/index.tt',
        page_title => 'Docker Management',
    );
}

sub docker_containers :Path('/admin/docker-containers') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_containers',
        "Docker containers management page accessed");

    # CSC admin only - use AdminAuth (same pattern as all other admin actions)
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_containers')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'docker_containers',
            "Access denied: admin required");
        $c->flash->{error_msg} = "You need to be a CSC administrator to access Docker management.";
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return;
    }

    # Check if we're inside a Docker container
    my $docker_available = ! -f '/.dockerenv';


    $c->stash(
        template => 'admin/docker/docker_containers.tt',
        docker_available => $docker_available,
        authenticated => 1,
    );
}

sub docker_containers_working :Path('/admin/docker-containers-working') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_containers_working',
        "Docker containers working (production) page accessed");

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_containers')) {
        $c->flash->{error_msg} = "You need to be a CSC administrator to access Docker management.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }

    my $docker_available = ! -f '/.dockerenv';

    $c->stash(
        template => 'admin/docker/docker_containers_working.tt',
        docker_available => $docker_available,
        authenticated => 1,
    );
}

sub docker_containers_old :Path('/admin/docker-containers-old') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_containers_old',
        "Docker old containers management page accessed");

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_containers')) {
        $c->flash->{error_msg} = "You need to be a CSC administrator to access Docker management.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }

    my $docker_available = ! -f '/.dockerenv';

    $c->stash(
        template => 'admin/docker_containers_old.tt',
        docker_available => $docker_available,
        authenticated => 1,
    );
}

sub docker_list :Path('/admin/docker-list') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_list',
        "Docker list API called");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_list')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }

    # Check if we're inside a Docker container
    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }
    
    my $target = $c->req->params->{target} || 'workstation';
    my ($output, $exit_code) = $self->_run_docker_on_target($c, "ps --all --format json", $target);
    
    if ($exit_code != 0) {
        $c->response->body(encode_json({ success => \0, error => "Failed to execute docker ps on $target: $output" }));
        $c->response->content_type('application/json');
        return;
    }
    
    # Get image IDs to tags mapping on the server
    my %image_id_to_tags;
    my ($tags_out, $tags_exit) = $self->_run_docker_on_target($c, 'images --format "{{.ID}} {{.Tag}}"', $target);
    if ($tags_exit == 0) {
        foreach my $line (split /\n/, $tags_out) {
            if ($line =~ /^(\S+)\s+(.+)$/) {
                my ($id, $tag) = ($1, $2);
                $id =~ s/^sha256://g;
                my $short_id = substr($id, 0, 12);
                push @{$image_id_to_tags{$id}}, $tag;
                push @{$image_id_to_tags{$short_id}}, $tag unless $short_id eq $id;
            }
        }
    }

    # Parse JSON output (one JSON object per line from docker ps --format json)
    my @containers;
    foreach my $line (split /\n/, $output) {
        next unless $line =~ /^\{/;
        eval {
            my $container = decode_json($line);
            my $name = $container->{Names} || $container->{Name} || '';
            $name =~ s{^/}{};
            # Extract service name from compose label if present
            my $service = '';
            if (my $labels = $container->{Labels}) {
                ($service) = $labels =~ /com\.docker\.compose\.service=([^,]+)/;
            }
            $service ||= $name;
            # Parse ports string "0.0.0.0:3000->3000/tcp, ..." into array
            my @ports;
            if (my $ports_str = $container->{Ports}) {
                @ports = grep { /\d+:\d+/ } split(/,\s*/, $ports_str);
            }
            my $state = $container->{State} || 'unknown';
            my $container_info = {
                name    => $name,
                service => $service,
                state   => $state,
                status  => $container->{Status} || '',
                ports   => \@ports,
                image   => $container->{Image} || '',
                image_tags => [],
            };
            if (lc($state) eq 'running' || lc($state) eq 'up' || ($container->{Status} && $container->{Status} =~ /Up/i)) {
                # Get the running container's image ID
                my ($inspect_out, $inspect_exit) = $self->_run_docker_on_target($c, "inspect --format '{{.Image}}' $name", $target);
                if ($inspect_exit == 0) {
                    chomp $inspect_out;
                    $inspect_out =~ s/^'|'$//g; # Clean quotes
                    $inspect_out =~ s/^sha256://g;
                    my $short_id = substr($inspect_out, 0, 12);
                    if ($image_id_to_tags{$inspect_out}) {
                        $container_info->{image_tags} = $image_id_to_tags{$inspect_out};
                    } elsif ($image_id_to_tags{$short_id}) {
                        $container_info->{image_tags} = $image_id_to_tags{$short_id};
                    }
                }

                my ($version_out, $version_exit) = $self->_run_docker_on_target($c, "exec $name cat /opt/comserv/version.json", $target);
                if ($version_exit == 0 && $version_out =~ /^\{/) {
                    my $ver_data = eval { decode_json($version_out) };
                    if ($ver_data) {
                        $container_info->{build_info} = $ver_data;
                    }
                }
            }
            push @containers, $container_info;
        };
    }
    
    # Query available backup images on target
    my @backups;
    my ($images_output, $images_exit) = $self->_run_docker_on_target($c, 'images --format "{{.Repository}}:{{.Tag}} ({{.Size}})"', $target);
    if ($images_exit == 0) {
        foreach my $line (split /\n/, $images_output) {
            if ($line =~ /:backup-/) {
                $line =~ s/^(?:shantamcsbain\/)?comserv-web-prod://;
                push @backups, $line;
            }
        }
    }

    $c->response->body(encode_json({ success => 1, containers => \@containers, backups => \@backups, target => $target }));
    $c->response->content_type('application/json');
}

sub docker_volumes :Path('/admin/docker-volumes') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_volumes',
        "Docker volumes list API called");

    my $admin_auth_vol = Comserv::Util::AdminAuth->new();
    unless ($admin_auth_vol->check_admin_access($c, 'docker_volumes')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Authentication required"}');
        $c->response->content_type('application/json');
        return;
    }

    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }

    my $target = $c->req->params->{target} || 'workstation';
    my ($names_out, $names_exit) = $self->_run_docker_on_target($c, "volume ls -q", $target);

    if ($names_exit != 0) {
        $c->response->body(encode_json({ success => \0, error => "Failed to list Docker volumes on $target: $names_out" }));
        $c->response->content_type('application/json');
        return;
    }

    my @names = grep { $_ ne '' } split /\n/, $names_out;

    if (!@names) {
        $c->response->body(encode_json({ success => 1, volumes => [], target => $target }));
        $c->response->content_type('application/json');
        return;
    }

    my $names_str = join(' ', map { quotemeta($_) } @names);
    my ($inspect_out, $inspect_exit) = $self->_run_docker_on_target($c, "volume inspect $names_str", $target);

    my @volumes;
    eval {
        my $data = decode_json($inspect_out);
        foreach my $vol (@$data) {
            my $opts    = $vol->{Options} || {};
            my $is_nfs  = (lc($opts->{type} || '') eq 'nfs' || lc($opts->{type} || '') eq 'nfs4');
            my $nfs_addr = '';
            if ($is_nfs && $opts->{o}) {
                ($nfs_addr) = ($opts->{o} =~ /addr=([^,]+)/);
            }
            push @volumes, {
                name       => $vol->{Name}       || '',
                driver     => $vol->{Driver}     || 'local',
                mountpoint => $vol->{Mountpoint} || '',
                labels     => ref($vol->{Labels}) eq 'HASH'
                    ? join(', ', map { "$_=$vol->{Labels}{$_}" } keys %{$vol->{Labels}})
                    : ($vol->{Labels} || ''),
                scope      => $vol->{Scope}      || 'local',
                is_nfs     => $is_nfs ? \1 : \0,
                nfs_server => $nfs_addr,
                nfs_device => $opts->{device} || '',
            };
        }
    };

    $c->response->body(encode_json({ success => 1, volumes => \@volumes }));
    $c->response->content_type('application/json');
}

sub docker_restart :Path('/admin/docker-restart') :Args(1) {
    my ($self, $c, $service) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_restart',
        "Docker restart requested for service: $service");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_restart')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }

    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }
    
    $service =~ s/[^a-zA-Z0-9_\-]//g;
    my $target = $c->req->params->{target} || 'workstation';

    my $docker_cmd;
    if ($service eq 'all') {
        if ($target eq 'workstation') {
            $docker_cmd = "compose -f /home/shanta/PycharmProjects/comserv2/docker-compose.yml restart";
        } else {
            $docker_cmd = "compose -f /opt/comserv/Comserv/docker-compose.server.yml restart";
        }
    } else {
        $docker_cmd = "restart '$service'";
    }

    my ($output, $exit_code) = $self->_run_docker_on_target($c, $docker_cmd, $target);

    $c->response->body(encode_json({
        success   => $exit_code == 0 ? \1 : \0,
        stdout    => $output,
        exit_code => $exit_code,
        ($exit_code != 0 ? (error => $output) : ()),
    }));
    $c->response->content_type('application/json');
}

sub docker_start :Path('/admin/docker-start') :Args(1) {
    my ($self, $c, $service) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_start',
        "Docker start requested for service: $service");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_start')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }

    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }
    
    $service =~ s/[^a-zA-Z0-9_\-]//g;
    my $target = $c->req->params->{target} || 'workstation';

    my $docker_cmd;
    if ($service eq 'all') {
        if ($target eq 'workstation') {
            $docker_cmd = "compose -f /home/shanta/PycharmProjects/comserv2/docker-compose.yml start";
        } else {
            $docker_cmd = "compose -f /opt/comserv/Comserv/docker-compose.server.yml start";
        }
    } else {
        $docker_cmd = "start '$service'";
    }

    my ($output, $exit_code) = $self->_run_docker_on_target($c, $docker_cmd, $target);

    $c->response->body(encode_json({
        success   => $exit_code == 0 ? \1 : \0,
        stdout    => $output,
        exit_code => $exit_code,
        ($exit_code != 0 ? (error => $output) : ()),
    }));
    $c->response->content_type('application/json');
}

sub docker_stop :Path('/admin/docker-stop') :Args(1) {
    my ($self, $c, $service) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_stop',
        "Docker stop requested for service: $service");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_stop')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }

    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }
    
    $service =~ s/[^a-zA-Z0-9_\-]//g;
    my $target = $c->req->params->{target} || 'workstation';

    my $docker_cmd;
    if ($service eq 'all') {
        if ($target eq 'workstation') {
            $docker_cmd = "compose -f /home/shanta/PycharmProjects/comserv2/docker-compose.yml stop";
        } else {
            $docker_cmd = "compose -f /opt/comserv/Comserv/docker-compose.server.yml stop";
        }
    } else {
        $docker_cmd = "stop '$service'";
    }

    my ($output, $exit_code) = $self->_run_docker_on_target($c, $docker_cmd, $target);

    $c->response->body(encode_json({
        success   => $exit_code == 0 ? \1 : \0,
        stdout    => $output,
        exit_code => $exit_code,
        ($exit_code != 0 ? (error => $output) : ()),
    }));
    $c->response->content_type('application/json');
}

sub docker_up :Path('/admin/docker-up') :Args(1) {
    my ($self, $c, $service) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_up',
        "Docker up requested for service: $service");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_up')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }

    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }
    
    $service =~ s/[^a-zA-Z0-9_\-]//g;
    my $target = $c->req->params->{target} || 'workstation';

    my $docker_cmd;
    my $compose_target = $service eq 'all' ? '' : $service;
    if ($target eq 'workstation') {
        $docker_cmd = "compose -f /home/shanta/PycharmProjects/comserv2/docker-compose.yml up -d $compose_target";
    } else {
        $docker_cmd = "compose -f /opt/comserv/Comserv/docker-compose.server.yml up -d $compose_target";
    }

    my ($output, $exit_code) = $self->_run_docker_on_target($c, $docker_cmd, $target);
    
    $c->response->body(encode_json({
        success   => $exit_code == 0 ? \1 : \0,
        stdout    => $output,
        exit_code => $exit_code,
        ($exit_code != 0 ? (error => $output) : ()),
    }));
    $c->response->content_type('application/json');
}

sub docker_logs :Path('/admin/docker-logs') :Args(1) {
    my ($self, $c, $service) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_logs',
        "Docker logs requested for service: $service");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_logs')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }

    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }
    
    $service =~ s/[^a-zA-Z0-9_\-]//g;
    my $lines = int($c->req->params->{lines} || 100);
    $lines = 100 unless $lines > 0 && $lines <= 10000;
    
    my $target = $c->req->params->{target} || 'workstation';

    my $docker_cmd;
    if ($target eq 'workstation') {
        $docker_cmd = "compose -f /home/shanta/PycharmProjects/comserv2/docker-compose.yml logs --tail=$lines $service";
    } else {
        $docker_cmd = "logs --tail=$lines $service";
    }

    my ($output, $exit_code) = $self->_run_docker_on_target($c, $docker_cmd, $target);
    
    $c->response->body(encode_json({
        success => $exit_code == 0 ? \1 : \0,
        output => $output,
        exit_code => $exit_code
    }));
    $c->response->content_type('application/json');
}

sub docker_rebuild :Path('/admin/docker-rebuild') :Args(1) {
    my ($self, $c, $service) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_rebuild',
        "Docker rebuild requested for service: $service");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_rebuild')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }

    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }
    
    $service =~ s/[^a-zA-Z0-9_\-]//g;

    my $log_file  = "/tmp/docker-build-${service}.log";
    my $done_file = "/tmp/docker-build-${service}.done";
    my $pid_file  = "/tmp/docker-build-${service}.pid";

    unlink $done_file if -f $done_file;
    open(my $lf, '>', $log_file) or do {
        $c->response->body(encode_json({ success => \0, error => "Cannot write build log: $!" }));
        $c->response->content_type('application/json');
        return;
    };
    print $lf "=== Build started at " . scalar(localtime) . " ===\n";
    close $lf;

    my $disk_pct = `df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}'`;
    chomp $disk_pct;
    if ($disk_pct =~ /^\d+$/ && $disk_pct >= 90) {
        $c->response->body(encode_json({
            success => \0,
            error   => "Disk at ${disk_pct}% — not safe to build. Run Docker Cleanup first.",
        }));
        $c->response->content_type('application/json');
        return;
    }

    my $build_target = $service eq 'all' ? '' : $service;
    my $script = <<"SHELL";
#!/bin/bash
LOG="$log_file"
DONE="$done_file"
cd /home/shanta/PycharmProjects/comserv2

echo "--- Pre-build cleanup ---" >> "\$LOG"
docker image prune -f >> "\$LOG" 2>&1
docker builder prune -f --keep-storage 5GB >> "\$LOG" 2>&1

DISK=\$(df / | awk 'NR==2 {gsub(/%/,"",\$5); print \$5}')
echo "Disk before build: \${DISK}%" >> "\$LOG"

echo "--- Building $service ---" >> "\$LOG"
docker compose build --progress=plain $build_target >> "\$LOG" 2>&1
EXIT=\$?

echo "--- Post-build cleanup ---" >> "\$LOG"
docker image prune -f >> "\$LOG" 2>&1

DISK_AFTER=\$(df / | awk 'NR==2 {gsub(/%/,"",\$5); print \$5}')
echo "Disk after build: \${DISK_AFTER}%" >> "\$LOG"
echo "=== Build finished exit=\$EXIT at \$(date) ===" >> "\$LOG"
echo \$EXIT > "\$DONE"
SHELL

    my $script_file = "/tmp/docker-build-${service}.sh";
    open(my $sf, '>', $script_file) or do {
        $c->response->body(encode_json({ success => \0, error => "Cannot write build script: $!" }));
        $c->response->content_type('application/json');
        return;
    };
    print $sf $script;
    close $sf;
    chmod 0755, $script_file;

    my $pid = fork();
    if (!defined $pid) {
        $c->response->body(encode_json({ success => \0, error => "Fork failed: $!" }));
        $c->response->content_type('application/json');
        return;
    }
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>>', $log_file);
        open(STDERR, '>>', $log_file);
        exec($script_file);
        exit 1;
    }
    if (open(my $pf, '>', $pid_file)) { print $pf $pid; close $pf; }

    $c->response->body(encode_json({
        success  => \1,
        async    => \1,
        job_id   => $service,
        message  => "Build started for $service (PID $pid). Poll /admin/docker-rebuild-status/$service for progress.",
    }));
    $c->response->content_type('application/json');
}

sub docker_rebuild_status :Path('/admin/docker-rebuild-status') :Args(1) {
    my ($self, $c, $service) = @_;

    $c->response->content_type('application/json');

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_rebuild_status')) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => \0, error => 'Access denied' }));
        return;
    }

    $service =~ s/[^a-zA-Z0-9_\-]//g;

    my $log_file  = "/tmp/docker-build-${service}.log";
    my $done_file = "/tmp/docker-build-${service}.done";

    unless (-f $log_file) {
        $c->response->body(encode_json({ success => \0, error => "No build in progress for $service" }));
        return;
    }

    my $done     = -f $done_file;
    my $exit_val = 0;
    if ($done) {
        if (open my $df, '<', $done_file) { chomp($exit_val = <$df> // 0); close $df; }
    }

    my $output = '';
    if (open my $lf, '<', $log_file) {
        local $/;
        $output = <$lf>;
        close $lf;
    }

    $c->response->body(encode_json({
        success   => $done ? ($exit_val == 0 ? \1 : \0) : \1,
        done      => $done ? \1 : \0,
        exit_code => $exit_val + 0,
        output    => $output,
    }));
}

sub production_disk_cleanup :Path('/admin/production-disk-cleanup') :Args(0) {
    my ($self, $c) = @_;
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'production_disk_cleanup')) {
        $c->response->status(403);
        $c->response->content_type('application/json');
        $c->response->body(encode_json({ success => \0, error => 'Access denied' }));
        return;
    }

    my $target = $c->req->params->{target} || 'production1';
    my $script = File::Spec->catfile($c->config->{home}, '..', 'script', 'production-disk-cleanup.sh');
    $script = File::Spec->catfile($c->config->{home}, 'script', 'production-disk-cleanup.sh')
        unless -f $script;
    unless (-f $script) {
        $c->response->content_type('application/json');
        $c->response->body(encode_json({ success => \0, error => 'production-disk-cleanup.sh not found' }));
        return;
    }

    open my $sf, '<', $script or do {
        $c->response->content_type('application/json');
        $c->response->body(encode_json({ success => \0, error => "Cannot read $script" }));
        return;
    };
    local $/;
    my $script_body = <$sf>;
    close $sf;
    my $b64 = MIME::Base64::encode_base64($script_body, '');

    my ($output, $exit) = $self->_run_host_cmd_on_target($c,
        "echo '$b64' | base64 -d > /tmp/comserv-disk-cleanup.sh && chmod +x /tmp/comserv-disk-cleanup.sh && /tmp/comserv-disk-cleanup.sh",
        $target,
    );

    $c->response->content_type('application/json');
    $c->response->body(encode_json({
        success   => $exit == 0 ? \1 : \0,
        output    => $output,
        exit_code => $exit,
        target    => $target,
    }));
}

sub docker_prune :Path('/admin/docker-prune') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_prune',
        "Docker prune requested");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_prune')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }

    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }
    
    my $target = $c->req->params->{target} || 'workstation';
    my $output = '';
    
    # Remove stopped containers
    $output .= "=== Removing stopped containers ===\n";
    my ($o1, $e1) = $self->_run_docker_on_target($c, "container prune -f", $target);
    $output .= $o1;
    
    # Remove dangling images
    $output .= "\n=== Removing dangling images ===\n";
    my ($o2, $e2) = $self->_run_docker_on_target($c, "image prune -f", $target);
    $output .= $o2;
    
    # Remove unused networks
    $output .= "\n=== Removing unused networks ===\n";
    my ($o3, $e3) = $self->_run_docker_on_target($c, "network prune -f", $target);
    $output .= $o3;
    
    my $exit_code = ($e1 || $e2 || $e3) ? 1 : 0;
    
    my $result = {
        success => $exit_code == 0 ? \1 : \0,
        output => $output,
        exit_code => $exit_code
    };
    
    $c->response->body(encode_json($result));
    $c->response->content_type('application/json');
}

sub docker_diagnostics :Path('/admin/docker-diagnostics') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_diagnostics',
        "Docker system diagnostics requested");
        
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_diagnostics')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }
    
    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }
    
    my $target = $c->req->params->{target} || 'workstation';
    my $diagnostics = $self->_query_system_diagnostics($c, $target);
    
    my $result = {
        success     => \1,
        diagnostics => $diagnostics,
        target      => $target
    };
    
    $c->response->body(encode_json($result));
    $c->response->content_type('application/json');
}

sub docker_system_df :Path('/admin/docker-system-df') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_system_df',
        "Docker system df requested");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_system_df')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }

    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }
    
    my $target = $c->req->params->{target} || 'workstation';
    my ($output, $exit_code) = $self->_run_docker_on_target($c, "system df", $target);
    
    my $result = {
        success => $exit_code == 0 ? \1 : \0,
        output => $output,
        exit_code => $exit_code
    };
    
    $c->response->body(encode_json($result));
    $c->response->content_type('application/json');
}

sub docker_save_image :Path('/admin/docker-save-image') :Args(1) {
    my ($self, $c, $service) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_save_image',
        "Docker save image requested for service: $service");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_save_image')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }

    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }
    
    $service =~ s/[^a-zA-Z0-9_\-]//g;
    my $timestamp = time();
    my $export_dir = "$ENV{HOME}/docker-exports";
    system("mkdir -p $export_dir") unless -d $export_dir;
    
    my $image_name = "comserv2-$service";
    my $tar_file = "$export_dir/${image_name}_${timestamp}.tar";
    
    my $cmd = "docker save -o $tar_file $image_name 2>&1";
    my $output = `$cmd`;
    my $exit_code = $? >> 8;
    
    my $result = {
        success => $exit_code == 0 ? \1 : \0,
        output => $output,
        tar_file => $tar_file,
        exit_code => $exit_code
    };
    
    $c->response->body(encode_json($result));
    $c->response->content_type('application/json');
}

sub docker_test_ssh :Path('/admin/docker-test-ssh') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_test_ssh',
        "Docker SSH connection test requested");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_test_ssh')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }

    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }
    
    my $ssh_target = $c->req->params->{ssh_target} || '';
    my $ssh_port = $c->req->params->{ssh_port} || 22;
    my $ssh_password = $c->req->params->{ssh_password} || '';
    my $save_credentials = $c->req->params->{save_credentials} || '';
    my $docker_hub_username = $c->req->params->{docker_hub_username} || '';
    my $docker_hub_password = $c->req->params->{docker_hub_password} || '';

    # Validate ssh_target: must be user@hostname format with safe characters only
    unless ($ssh_target =~ /^[a-zA-Z0-9_\-]+\@[a-zA-Z0-9_\-\.]+$/) {
        $c->response->body('{"success": false, "error": "Invalid SSH target format (expected user@hostname)"}');
        $c->response->content_type('application/json');
        return;
    }
    # Validate port is a number
    $ssh_port = int($ssh_port);
    $ssh_port = 22 unless $ssh_port > 0 && $ssh_port <= 65535;
    
    if (!$ssh_target) {
        $c->response->body('{"success": false, "error": "SSH target not specified"}');
        $c->response->content_type('application/json');
        return;
    }
    
    if (!$ssh_password) {
        $c->response->body('{"success": false, "error": "SSH password required"}');
        $c->response->content_type('application/json');
        return;
    }
    
    # Check if sshpass is installed
    my $sshpass_check = `which sshpass 2>/dev/null`;
    unless ($sshpass_check) {
        $c->response->body('{"success": false, "error": "sshpass not installed. Install with: sudo apt-get install sshpass"}');
        $c->response->content_type('application/json');
        return;
    }
    
    # Use SSHPASS env var to avoid password on command line (prevents shell injection)
    local $ENV{SSHPASS} = $ssh_password;
    my $cmd = qq(sshpass -e ssh -p $ssh_port -o ConnectTimeout=5 -o StrictHostKeyChecking=no $ssh_target "echo 'SSH connection successful'; docker --version; docker compose version" 2>&1);
    my $output = `$cmd`;
    my $exit_code = $? >> 8;
    
    my $result = {
        success => $exit_code == 0 ? \1 : \0,
        output => $output,
        exit_code => $exit_code
    };
    
    # Save credentials if requested
    if ($save_credentials eq 'yes' && $exit_code == 0) {
        my $secrets_dir = "$ENV{HOME}/.comserv/secrets";
        my $credentials_file = "$secrets_dir/ssh_credentials.json";
        
        unless (-d $secrets_dir) {
            system("mkdir -p $secrets_dir");
            system("chmod 700 $secrets_dir");
        }
        
        my $credentials = {};
        if (-f $credentials_file && open my $rf, '<', $credentials_file) {
            local $/;
            my $json = <$rf>;
            close $rf;
            $credentials = eval { decode_json($json) } || {};
        }
        
        $credentials->{ssh_target} = $ssh_target;
        $credentials->{ssh_port} = $ssh_port;
        $credentials->{ssh_password} = $ssh_password;
        $credentials->{last_updated} = time();
        $credentials->{last_test_success} = time();
        
        if ($docker_hub_username) {
            $credentials->{docker_hub_username} = $docker_hub_username;
        }
        if ($docker_hub_password) {
            $credentials->{docker_hub_password} = $docker_hub_password;
        }
        
        if (open my $fh, '>', $credentials_file) {
            print $fh encode_json($credentials);
            close $fh;
            chmod 0600, $credentials_file;
            
            $result->{credentials_saved} = \1;
            $result->{credentials_path} = $credentials_file;
        }
    }
    
    $c->response->body(encode_json($result));
    $c->response->content_type('application/json');
}

sub emergency_restore :Path('/admin/emergency-restore') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'emergency_restore',
        "Emergency restore page requested by " . ($c->user ? $c->user->username : 'unknown'));

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'emergency_restore')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }

    my $backup_manager = Comserv::Util::BackupManager->new(app_dir => $c->config->{home});
    
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action') || '';
        
        if ($action eq 'restore_psgi') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'emergency_restore',
                "Emergency restore of comserv.psgi file triggered");
                
            my $res = $backup_manager->restore_psgi_file();
            if ($res->{success}) {
                $c->stash->{success_msg} = "comserv.psgi restored successfully.";
            } else {
                $c->stash->{error_msg} = "Failed to restore comserv.psgi: " . $res->{message};
            }
            $c->stash->{output} = $res->{output};
        }
        elsif ($action eq 'restore_file') {
            my $backup_path = $c->req->param('backup_path');
            my $target_file = $c->req->param('target_file');
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'emergency_restore',
                "Emergency restore of file '$target_file' from '$backup_path'");
                
            if ($backup_path && $target_file) {
                my $res = $backup_manager->restore_file_from_backup($backup_path, $target_file);
                if ($res->{success}) {
                    $c->stash->{success_msg} = "File '$target_file' restored successfully.";
                } else {
                    $c->stash->{error_msg} = "Failed to restore file: " . $res->{message};
                }
                $c->stash->{output} = $res->{output};
            } else {
                $c->stash->{error_msg} = "Backup path and target file are required.";
            }
        }
    }

    my $backup_contents = $backup_manager->get_backup_directory_contents();
    my $app_dir = $backup_manager->app_dir;
    my $psgi_path = $app_dir =~ m{/Comserv$} ? "$app_dir/comserv.psgi" : "$app_dir/Comserv/comserv.psgi";
    my $psgi_exists = -f $psgi_path;

    $c->stash(
        template => 'admin/emergency_restore.tt',
        backup_contents => $backup_contents,
        psgi_exists => $psgi_exists,
    );
}

sub docker_start_starman :Path('/admin/docker-start-starman') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_start_starman',
        "Manual host Starman startup requested from application");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_start_starman')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }
    
    my $target = $c->req->params->{target} || 'production1';
    
    # Load SSH password to support remote sudo authentication
    my $ssh_password = '';
    my $home = $ENV{HOME} || '/home/shanta';
    my $creds_file = "$home/.comserv/secrets/ssh_credentials.json";
    if (-f $creds_file && open my $cf, '<', $creds_file) {
        local $/;
        my $json = <$cf>;
        close $cf;
        my $creds = eval { decode_json($json) };
        if ($creds) {
            $ssh_password = $creds->{ssh_password} || '';
        }
    }
    
    my $escaped_password = $ssh_password;
    $escaped_password =~ s/'/'\\''/g;
    
    # Construct shell command to locate host code, stop failing container, and run daemonized Starman
    my $start_cmd = q(
        sudo() {
            echo '__SSH_PASSWORD__' | /usr/bin/sudo -S "$@"
        }

        HOST_APP_DIR=""
        for DIR in /opt/comserv/Comserv /home/ubuntu/comserv /home/shanta/PycharmProjects/comserv2; do
            if [ -d "$DIR" ]; then
                HOST_APP_DIR="$DIR"
                break
            fi
        done

        if [ -n "$HOST_APP_DIR" ]; then
            cd "$HOST_APP_DIR"
            PSGI_FILE=""
            for FILE in script/comserv_server.psgi script/comserv.psgi comserv_server.psgi comserv.psgi; do
                if [ -f "$FILE" ]; then
                    PSGI_FILE="$FILE"
                    break
                fi
            done
            
            if [ -n "$PSGI_FILE" ]; then
                # Stop any container running on 5000 to free port
                sudo docker stop comserv2-web-prod 2>/dev/null || docker stop comserv2-web-prod 2>/dev/null || true
                sudo docker rm -f comserv2-web-prod 2>/dev/null || docker rm -f comserv2-web-prod 2>/dev/null || true
                
                # Kill processes holding port 5000 to guarantee clean bind
                if command -v fuser &>/dev/null; then
                    sudo fuser -k -9 5000/tcp 2>/dev/null || fuser -k -9 5000/tcp 2>/dev/null || true
                fi
                
                export CATALYST_HOME="$HOST_APP_DIR"
                export CATALYST_ENV=production
                export COMSERV_LOG_DIR="$HOST_APP_DIR"
                export PERL_LOCAL_LIB_ROOT="$HOST_APP_DIR/local"
                export PERL5LIB="$HOST_APP_DIR/lib:$HOST_APP_DIR/local/lib/perl5:$PERL5LIB"

                if [ -f "script/comserv_server.psgi" ]; then
                    rm -f comserv.psgi 2>/dev/null || true
                    ln -sf script/comserv_server.psgi comserv.psgi || cp -f script/comserv_server.psgi comserv.psgi || true
                fi

                echo "Attempting to reset and start systemd starman.service..."
                sudo systemctl reset-failed starman.service 2>/dev/null || true
                sudo systemctl enable starman.service 2>/dev/null || true
                
                if sudo systemctl start starman.service 2>/dev/null && sleep 2 && sudo systemctl is-active starman.service &>/dev/null; then
                    echo "SUCCESS: Host Starman systemd service started and verified active!"
                else
                    echo "systemd service failed to start or verify. Falling back to manual process execution..."
                    
                    # Stop and disable systemd starman service if active to avoid restart conflicts
                    sudo systemctl stop starman.service 2>/dev/null || true
                    sudo systemctl disable starman.service 2>/dev/null || true

                    # Kill existing starman/plackup on host
                    sudo pkill -f starman 2>/dev/null || pkill -f starman 2>/dev/null || true
                    sudo pkill -f plackup 2>/dev/null || pkill -f plackup 2>/dev/null || true
                    sudo pkill -f comserv.*psgi 2>/dev/null || pkill -f comserv.*psgi 2>/dev/null || true
                    
                    # Try launching via various known starman locations/methods
                    STARTED=0
                    if [ -x "/usr/local/bin/starman" ]; then
                        if /usr/local/bin/starman -I"$HOST_APP_DIR/lib" -I"$HOST_APP_DIR/local/lib/perl5" --daemonize --listen ":5000" --workers 3 "$PSGI_FILE" >/tmp/host_starman_manual.log 2>&1; then
                            STARTED=1
                        fi
                    fi
                    
                    if [ "$STARTED" -eq 0 ]; then
                        if perl -I"$HOST_APP_DIR/lib" -I"$HOST_APP_DIR/local/lib/perl5" -Mlocal::lib=local -S starman --daemonize --listen ":5000" --workers 3 "$PSGI_FILE" >>/tmp/host_starman_manual.log 2>&1; then
                            STARTED=1
                        fi
                    fi
                    
                    if [ "$STARTED" -eq 0 ]; then
                        if starman -I"$HOST_APP_DIR/lib" -I"$HOST_APP_DIR/local/lib/perl5" --daemonize --listen ":5000" --workers 3 "$PSGI_FILE" >>/tmp/host_starman_manual.log 2>&1; then
                            STARTED=1
                        fi
                    fi
                    
                    if [ "$STARTED" -eq 1 ]; then
                        echo "SUCCESS: Host Starman manual process started on port 5000!"
                    else
                        echo "ERROR: Failed to start host Starman using any method. Log:"
                        cat /tmp/host_starman_manual.log 2>/dev/null || echo "No manual log file found."
                    fi
                fi
            else
                echo "ERROR: PSGI file not found under $HOST_APP_DIR"
            fi
        else
            echo "ERROR: Host application directory not found."
        fi
    );
    
    $start_cmd =~ s/__SSH_PASSWORD__/$escaped_password/g;
    
    my ($output, $exit_code) = $self->_run_host_cmd_on_target($c, $start_cmd, $target);
    
    if ($exit_code != 0 || $output =~ /ERROR:/) {
        $c->response->body(encode_json({ success => \0, error => $output || "SSH command failed" }));
    } else {
        $c->response->body(encode_json({ success => \1, message => $output }));
    }
    $c->response->content_type('application/json');
}

sub docker_load_credentials :Path('/admin/docker-load-credentials') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_load_credentials')) {
        $c->response->status(403);
        $c->response->body('{"success": false}');
        $c->response->content_type('application/json');
        return;
    }

    my $creds_file = ($ENV{HOME} || '/home/shanta') . '/.comserv/secrets/ssh_credentials.json';
    my $creds = {};
    if (-f $creds_file && open my $fh, '<', $creds_file) {
        local $/;
        my $json = <$fh>;
        close $fh;
        $creds = eval { decode_json($json) } || {};
    }

    $c->response->body(encode_json({
        success      => \1,
        ssh_target   => $creds->{ssh_target}   || 'ubuntu@192.168.1.126',
        ssh_port     => $creds->{ssh_port}     || 22,
        ssh_password => $creds->{ssh_password} || '',
    }));
    $c->response->content_type('application/json');
}

sub docker_deploy_to_production :Path('/admin/docker-deploy-to-production') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_deploy_to_production',
        "Docker Hub build+push+deploy requested by " . ($c->user ? $c->user->username : 'unknown'));

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_deploy_to_production')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied: admin required"}');
        $c->response->content_type('application/json');
        return;
    }

    my $current_deploy_log_id = $c->req->params->{deploy_log_id} || 0;

    my $active_deploy_log = eval {
        my $now = DateTime->now(time_zone => 'local');
        my $today = $now->ymd;
        my $threshold_time = $now->clone->subtract(minutes => 20)->hms;
        my %search_params = (
            status     => 2,
            abstract   => { -like => '%Docker%Deploy%' },
            start_date => $today,
            start_time => { '>=', $threshold_time },
        );
        if ($current_deploy_log_id) {
            $search_params{record_id} = { '!=' => $current_deploy_log_id };
        }
        $c->model('DBEncy')->resultset('Log')->search(\%search_params, {
            rows => 1,
            order_by => { -desc => 'record_id' }
        })->first;
    };

    if ($active_deploy_log) {
        my $act_user = $active_deploy_log->username || 'unknown';
        my $act_time = $active_deploy_log->start_time || 'unknown';
        $c->response->body(encode_json({
            success => 0,
            error   => "A deployment is already in progress by $act_user (started at $act_time today)!"
        }));
        $c->response->content_type('application/json');
        return;
    }

    if (-f '/.dockerenv') {
        $c->response->body('{"success": false, "error": "Cannot manage Docker from inside a container"}');
        $c->response->content_type('application/json');
        return;
    }

    my $pid_file_check = '/tmp/comserv-hub-deploy.pid';
    if (-f $pid_file_check && open my $pf_fh, '<', $pid_file_check) {
        my $chk_pid = <$pf_fh>;
        close $pf_fh;
        if ($chk_pid && $chk_pid =~ /^\d+$/ && kill(0, $chk_pid)) {
            $c->response->body(encode_json({ success => 0, error => "A deployment is already in progress (PID $chk_pid)!" }));
            $c->response->content_type('application/json');
            return;
        }
    }

    my $ssh_target    = $c->req->params->{ssh_target}   || 'ubuntu@192.168.1.126';
    my $form_password = $c->req->params->{ssh_password} || '';
    my $deploy_mode   = $c->req->params->{deploy_mode}   || 'full';
    if ($c->req->params->{quick_deploy}) {
        $deploy_mode = 'quick';
    }
    my $quick_deploy  = ($deploy_mode ne 'full') ? 1 : 0;

    my $ssh_password = '';
    my $docker_hub_username = '';
    my $docker_hub_password = '';
    my $home     = $ENV{HOME} || '/home/shanta';
    my $creds_file = "$home/.comserv/secrets/ssh_credentials.json";
    if (-f $creds_file && open my $cf, '<', $creds_file) {
        local $/;
        my $json = <$cf>;
        close $cf;
        my $creds = eval { decode_json($json) };
        if ($creds) {
            $ssh_password        = $creds->{ssh_password} if $creds->{ssh_password};
            $ssh_target          = $creds->{ssh_target} if $creds->{ssh_target};
            $docker_hub_username = $creds->{docker_hub_username} if $creds->{docker_hub_username};
            $docker_hub_password = $creds->{docker_hub_password} if $creds->{docker_hub_password};
        }
    }
    $ssh_password ||= $form_password;

    if (!$ssh_password) {
        $c->response->body('{"success": false, "error": "SSH password required — use Test Connection to save credentials first"}');
        $c->response->content_type('application/json');
        return;
    }

    my ($ssh_user, $ssh_host) = $ssh_target =~ /^([a-zA-Z0-9_\-]+)\@([a-zA-Z0-9_\-\.]+)$/;
    unless ($ssh_user && $ssh_host) {
        $c->response->body('{"success": false, "error": "SSH target must be user\@hostname"}');
        $c->response->content_type('application/json');
        return;
    }

    my $comserv_dir  = $c->config->{home};
    my $repo_dir     = $comserv_dir;
    $repo_dir =~ s/\/Comserv$//;
    my $prod_compose = 'docker-compose.prod.yml';
    my $hub_image    = 'shantamcsbain/comserv-web-prod:latest';

    my $deploy_log_dir = "$repo_dir/deploy-logs";
    mkdir $deploy_log_dir unless -d $deploy_log_dir;

    my @t_stamp = localtime();
    my $ts = sprintf('%04d%02d%02d-%02d%02d%02d',
        $t_stamp[5]+1900, $t_stamp[4]+1, $t_stamp[3],
        $t_stamp[2], $t_stamp[1], $t_stamp[0]);
    my $log_file     = "$deploy_log_dir/deploy-$ts.log";
    my $latest_link  = "$deploy_log_dir/latest.log";
    my $pid_file     = '/tmp/comserv-hub-deploy.pid';
    my $logpath_file = '/tmp/comserv-hub-deploy.logpath';

    unlink $logpath_file;
    unlink $pid_file;
    if (open my $lp, '>', $logpath_file) { print $lp $log_file; close $lp; }

    my $git_commit = `cd '$repo_dir' && git rev-parse --short HEAD 2>/dev/null`; chomp $git_commit;
    my $git_branch = `cd '$repo_dir' && git rev-parse --abbrev-ref HEAD 2>/dev/null`; chomp $git_branch;
    my $git_subject = `cd '$repo_dir' && git log -1 --pretty=%s 2>/dev/null`; chomp $git_subject;
    my $deploy_user = $c->session->{username} || 'system';
    my @t = gmtime(); my $build_date = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
    my $build_host = `hostname 2>/dev/null`; chomp $build_host;

    my $version_data = {
        commit     => $git_commit  || 'unknown',
        branch     => $git_branch  || 'unknown',
        build_date => $build_date,
        build_host => $build_host  || 'workstation',
    };
    if (open my $vf, '>', "$comserv_dir/version.json") {
        print $vf encode_json($version_data);
        close $vf;
    }

    Comserv::Util::DeployStatus::write_record(
        comserv_home     => $comserv_dir,
        status           => 'build_started',
        commit           => $git_commit,
        branch           => $git_branch,
        commit_subject   => $git_subject,
        deployed_by      => $deploy_user,
        target_host      => $ssh_host,
        method           => 'docker_hub',
        build_host       => $build_host,
        image            => $hub_image,
        log_file         => $log_file,
        notes            => 'Image build/push started from admin docker deploy',
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_deploy_to_production',
        "Starting deploy: commit=$git_commit branch=$git_branch image=$hub_image target=$ssh_target log=$log_file");

    my $pid = fork();
    if (!defined $pid) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'docker_deploy_to_production',
            "Failed to fork background deploy process");
        $c->response->body('{"success": false, "error": "Failed to fork background process"}');
        $c->response->content_type('application/json');
        return;
    }

    if ($pid == 0) {
        open(STDOUT, '>', $log_file) or _exit(1);
        open(STDERR, '>&STDOUT')     or _exit(1);
        $| = 1;

        my $child_exit = sub {
            my $code = shift;
            unlink $pid_file if -f $pid_file;
            _exit($code);
        };

        print "=== Comserv Production Deploy via Docker Hub ===\n";
        print "Started   : " . scalar(localtime) . "\n";
        print "Commit    : $git_commit ($git_branch)\n";
        print "Build date: $build_date\n";
        print "Image     : $hub_image\n";
        print "SSH target: $ssh_target\n";
        print "Log file  : $log_file\n";
        print "Mode      : " . ($quick_deploy ? "QUICK DEPLOY (Skip build/push)" : "FULL DEPLOY (Build + Push + Deploy)") . "\n";
        print "=" x 60 . "\n\n";

        print "--- Step 0a: Auto-commit and push local changes ---\n";
        local $ENV{COMSERV_GIT_REPO_ROOT} = $repo_dir;
        local $ENV{COMSERV_DEPLOY_USER}   = $deploy_user;
        my $git_sync_exit = system('bash', "$comserv_dir/script/deploy.sh", '--pre-build-git-sync');
        $git_sync_exit >>= 8;
        if ($git_sync_exit != 0) {
            print "\n❌ PRE-BUILD GIT SYNC FAILED (exit $git_sync_exit)\n";
            print "Resolve git commit/push errors, then re-run Auto Deploy.\n";
            $child_exit->(1);
        }
        $git_commit  = `git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null`; chomp $git_commit;
        $git_subject  = `git -C "$repo_dir" log -1 --pretty=%s 2>/dev/null`; chomp $git_subject;
        print "Building/deploying from commit: $git_commit ($git_subject)\n\n";
        if (open my $vf, '>', "$comserv_dir/version.json") {
            print $vf encode_json({
                commit     => $git_commit || 'unknown',
                branch     => $git_branch || 'unknown',
                build_date => $build_date,
                build_host => $build_host || 'workstation',
            });
            close $vf;
        }

        unless ($quick_deploy) {
            print "--- Pre-flight: Checking Docker Hub credentials ---\n";

            my $logged_in     = 0;
            my $creds_method  = 'unknown';
            my $docker_cfg    = ($ENV{HOME} || '/home/shanta') . '/.docker/config.json';
            if (open my $dcf, '<', $docker_cfg) {
                local $/; my $raw = <$dcf>; close $dcf;
                my $dcfg = eval { decode_json($raw) } || {};
                my $creds_store = $dcfg->{credsStore} || '';
                my $auths       = $dcfg->{auths}       || {};

                if ($creds_store) {
                    $creds_method = "credential helper (credsStore: $creds_store)";
                    my $helper = "docker-credential-$creds_store";
                    my $cred_out = `echo 'https://index.docker.io/v1/' | $helper get 2>/dev/null`;
                    if ($cred_out && $cred_out =~ /"Username"\s*:\s*"([^"]+)"/) {
                        print "✅ Logged in via $creds_method as: $1\n\n";
                        $logged_in = 1;
                    } else {
                        print "⚠️  Credential helper ($helper) did not return credentials\n";
                    }
                } elsif (exists $auths->{'https://index.docker.io/v1/'}) {
                    $creds_method = 'config.json auth entry';
                    print "✅ Docker Hub auth entry found in config.json\n\n";
                    $logged_in = 1;
                } else {
                    print "⚠️  No Docker Hub credentials found in $docker_cfg\n";
                }
            } else {
                print "⚠️  Cannot read $docker_cfg\n";
            }

            unless ($logged_in) {
                print "   Push may fail — run: docker login -u shantamcsbain\n";
                print "   (continuing anyway)\n";
            }
            print "\n";

            print "--- Step 0: Routine cleanup of local containers on Workstation ---\n";
            if (-f "$comserv_dir/script/docker-cleanup.sh") {
                print "    Running: $comserv_dir/script/docker-cleanup.sh\n\n";
                my $cleanup_exit = system('bash', "$comserv_dir/script/docker-cleanup.sh");
                $cleanup_exit >>= 8;
                if ($cleanup_exit != 0) {
                    print "⚠️  Local cleanup script exited with code $cleanup_exit\n\n";
                } else {
                    print "✅ Local cleanup completed successfully\n\n";
                }
            } else {
                print "⚠️  Local cleanup script not found at $comserv_dir/script/docker-cleanup.sh\n\n";
            }

            print "--- Step 1: Building production image ($hub_image) ---\n";
            print "    compose: $comserv_dir/$prod_compose\n\n";
            my $build_exit = system('docker', 'compose',
                '-f', "$comserv_dir/$prod_compose",
                '--project-directory', $comserv_dir,
                'build', '--progress=plain');
            $build_exit >>= 8;
            if ($build_exit != 0) {
                print "\n❌ BUILD FAILED (exit $build_exit)\n";
                $child_exit->(1);
            }
            print "\n✅ Build complete\n\n";

            print "--- Step 1b: Stale-build check ---\n";
            my $fetch_out = `git -C "$repo_dir" fetch origin main 2>&1`;
            chomp(my $post_build_commit = `git -C "$repo_dir" rev-parse origin/main 2>/dev/null`);
            chomp(my $new_commits_raw   = `git -C "$repo_dir" rev-list --count "$git_commit"..origin/main 2>/dev/null`);
            my $new_commits = ($new_commits_raw =~ /^\d+$/) ? $new_commits_raw + 0 : 0;
            if ($new_commits > 0) {
                print "⚠️  WARNING: $new_commits new commit(s) merged into main WHILE this build was running.\n";
                print "   Build captured: $git_commit\n";
                print "   main is now at: $post_build_commit\n";
                print "   The pushed image will NOT contain these commits:\n";
                my $new_log = `git -C "$repo_dir" log --oneline "$git_commit"..origin/main 2>/dev/null`;
                print "$new_log\n";
                print "   Recommendation: cancel, merge main, and re-run Auto Deploy.\n";
                print "   Continuing push anyway (image is still valid, just not latest).\n\n";
            } else {
                print "✅ main has not advanced — build is current ($git_commit)\n\n";
            }

            print "--- Step 2: Pushing to Docker Hub ($hub_image) ---\n";
            if ($docker_hub_username && $docker_hub_password) {
                print "🔐 Attempting automatic Docker Hub login for $docker_hub_username...\n";
                my $login_cmd = sprintf("echo %s | docker login -u %s --password-stdin 2>&1",
                    quotemeta($docker_hub_password), quotemeta($docker_hub_username));
                my $login_out = `$login_cmd`;
                my $login_exit = $? >> 8;
                if ($login_exit == 0) {
                    print "✅ Automatic Docker Hub login successful!\n\n";
                } else {
                    print "⚠️  Automatic Docker Hub login failed (exit $login_exit):\n$login_out\n\n";
                }
            }

            my $push_exit = system('docker', 'compose',
                '-f', "$comserv_dir/$prod_compose",
                '--project-directory', $comserv_dir,
                'push');
            $push_exit >>= 8;
            if ($push_exit != 0) {
                print "\n❌ PUSH FAILED (exit $push_exit)\n";
                print "Fix: run 'docker login -u shantamcsbain' on the workstation terminal\n";
                print "     then click Auto Deploy again\n";
                $child_exit->(1);
            }
            print "\n✅ Push to Docker Hub complete — $hub_image updated\n\n";
        }

        print "--- Step 3: Publishing production deploy files to $ssh_target ---\n";
        my $escaped_password = $ssh_password;
        $escaped_password =~ s/'/'\\''/g;

        local $ENV{SSHPASS} = $ssh_password;

        # Copy to /tmp first to bypass write permission restrictions on /opt/comserv/Comserv/
        print "    Copying deploy.sh to remote /tmp...\n";
        my $scp1 = system('sshpass', '-e', 'scp',
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            "$comserv_dir/script/deploy.sh",
            "$ssh_target:/tmp/deploy.sh");
        $scp1 >>= 8;
        if ($scp1 != 0) {
            print "\n❌ FAILED TO COPY DEPLOY SCRIPT (exit $scp1)\n";
            $child_exit->(1);
        }

        print "    Copying docker-compose.server.yml to remote /tmp...\n";
        my $scp2 = system('sshpass', '-e', 'scp',
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            "$comserv_dir/script/docker-compose.server.yml",
            "$ssh_target:/tmp/docker-compose.prod.yml");
        $scp2 >>= 8;
        if ($scp2 != 0) {
            print "\n❌ FAILED TO COPY DOCKER COMPOSE CONFIG (exit $scp2)\n";
            $child_exit->(1);
        }

        # Move to /opt/comserv/Comserv/ with sudo
        print "    Moving files to final remote destinations with sudo...\n";
        my $move_cmd = "echo '$escaped_password' | sudo -S cp /tmp/deploy.sh /opt/comserv/Comserv/deploy.sh && " .
                       "echo '$escaped_password' | sudo -S chmod +x /opt/comserv/Comserv/deploy.sh && " .
                       "echo '$escaped_password' | sudo -S cp /tmp/docker-compose.prod.yml /opt/comserv/Comserv/docker-compose.prod.yml";
        my $move_exit = system('sshpass', '-e', 'ssh',
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            $ssh_target,
            $move_cmd);
        $move_exit >>= 8;
        if ($move_exit != 0) {
            print "\n❌ MOVING REMOTE FILES FAILED (exit $move_exit)\n";
            $child_exit->(1);
        }
        print "✅ Production deploy files published\n\n";

        print "--- Step 4: Triggering deploy on $ssh_target ---\n";
        print "    Running: /opt/comserv/Comserv/deploy.sh\n";
        my $ssh_cmd = "echo '$escaped_password' | sudo -S DEPLOY_MODE='$deploy_mode' /opt/comserv/Comserv/deploy.sh";
        my $ssh_exit = system('sshpass', '-e', 'ssh',
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            $ssh_target,
            $ssh_cmd);
        $ssh_exit >>= 8;
        if ($ssh_exit != 0) {
            print "\n⚠️  SSH TRIGGER FAILED (exit $ssh_exit)\n";
            print "Retrying with DEPLOY_MODE=lib_sync (git pull + docker cp lib + restart)...\n";
            my $lib_sync_cmd = "echo '$escaped_password' | sudo -S DEPLOY_MODE=lib_sync /opt/comserv/Comserv/deploy.sh";
            my $lib_sync_exit = system('sshpass', '-e', 'ssh',
                '-o', 'StrictHostKeyChecking=no',
                '-o', 'UserKnownHostsFile=/dev/null',
                $ssh_target,
                $lib_sync_cmd);
            $lib_sync_exit >>= 8;
            if ($lib_sync_exit == 0) {
                print "\n✅ Production Perl lib synced via lib_sync fallback\n";
                $ssh_exit = 0;
            } else {
                print "\n❌ lib_sync fallback also failed (exit $lib_sync_exit)\n";
                print "Manual: ssh $ssh_target 'sudo DEPLOY_MODE=lib_sync /opt/comserv/Comserv/deploy.sh'\n";
            }
        } else {
            print "\n✅ Production server deploy triggered successfully\n";
        }
        print "\n";

        print "=== DEPLOYMENT COMPLETE at " . scalar(localtime) . " ===\n";
        print "Log saved: $log_file\n";

        unlink $latest_link if -l $latest_link;
        symlink $log_file, $latest_link;

        my $deploy_status = ($ssh_exit != 0) ? 'trigger_failed' : 'success';
        Comserv::Util::DeployStatus::write_record(
            comserv_home     => $comserv_dir,
            status           => $deploy_status,
            commit           => $git_commit,
            branch           => $git_branch,
            commit_subject   => $git_subject,
            deployed_by      => $deploy_user,
            target_host      => $ssh_host,
            method           => 'docker_hub',
            build_host       => $build_host,
            image            => $hub_image,
            log_file         => $log_file,
            notes            => $deploy_status eq 'success'
                ? 'Production deploy.sh completed on remote host'
                : 'Remote deploy.sh trigger failed — cron may deploy within 10 minutes',
        );
        print "Deploy status written: $comserv_dir/DEPLOY_STATUS.json ($deploy_status, commit $git_commit)\n";

        $child_exit->($ssh_exit != 0 ? 2 : 0);
    }

    if (open my $fh, '>', $pid_file) { print $fh $pid; close $fh; }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_deploy_to_production',
        "Background deploy forked: pid=$pid log=$log_file");

    $c->response->body(encode_json({
        success  => \1,
        message  => 'Deployment started in background',
        log_file => $log_file,
        image    => $hub_image,
    }));
    $c->response->content_type('application/json');
}

sub docker_deploy_status :Path('/admin/docker-deploy-status') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_deploy_status')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied"}');
        $c->response->content_type('application/json');
        return;
    }

    my $logpath_file = '/tmp/comserv-hub-deploy.logpath';
    my $pid_file     = '/tmp/comserv-hub-deploy.pid';

    my $log_file = '';
    if (-f $logpath_file && open my $lp, '<', $logpath_file) {
        chomp($log_file = <$lp>);
        close $lp;
    }

    my $output = '';
    if ($log_file && -f $log_file && open my $fh, '<', $log_file) {
        local $/;
        $output = <$fh>;
        close $fh;
    }

    my $is_running = 0;
    if (-f $pid_file && open my $fh, '<', $pid_file) {
        my $pid = <$fh>;
        close $fh;
        chomp $pid if defined $pid;
        $is_running = 1 if $pid && $pid =~ /^\d+$/ && kill(0, $pid);
    }

    $c->response->body(encode_json({
        success    => \1,
        output     => $output,
        is_running => $is_running ? \1 : \0,
        log_file   => $log_file,
    }));
    $c->response->content_type('application/json');
}

sub docker_deploy_history :Path('/admin/docker-deploy-history') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_deploy_history')) {
        $c->response->status(403);
        $c->response->body('{"success": false, "error": "Access denied"}');
        $c->response->content_type('application/json');
        return;
    }

    my $home         = $ENV{HOME} || '/home/shanta';
    my $deploy_log_dir = "$home/PycharmProjects/comserv2/deploy-logs";
    my $latest_link    = "$deploy_log_dir/latest.log";

    my @logs = ();
    if (-d $deploy_log_dir) {
        opendir my $dh, $deploy_log_dir or do {};
        my @files = sort { $b cmp $a }
                    grep { /^deploy-\d{8}-\d{6}\.log$/ }
                    readdir $dh;
        closedir $dh;
        @logs = map { "$deploy_log_dir/$_" } @files[0..4];
        @logs = grep { -f $_ } @logs;
    }

    my $latest_content = '';
    my $latest_file    = '';
    if (-f $latest_link && -l $latest_link) {
        $latest_file = readlink($latest_link) || '';
    } elsif (@logs) {
        $latest_file = $logs[0];
    }
    if ($latest_file && -f $latest_file && open my $fh, '<', $latest_file) {
        local $/;
        $latest_content = <$fh>;
        close $fh;
    }

    $c->response->body(encode_json({
        success        => \1,
        latest_file    => $latest_file,
        latest_content => $latest_content,
        log_files      => \@logs,
    }));
    $c->response->content_type('application/json');
}

sub docker_ssh_terminal :Path('/admin/docker-ssh-terminal') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_ssh_terminal',
        "SSH Terminal WebSocket requested");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'docker_ssh_terminal')) {
        $c->response->status(403);
        $c->response->status(403);
        $c->response->body('Access denied: admin required');
        return;
    }

    # Get parameters from query string
    my $ssh_target = $c->req->params->{ssh_target} || 'ubuntu@192.168.1.126';
    my $ssh_port = $c->req->params->{ssh_port} || 22;
    my $ssh_password = $c->req->params->{ssh_password} || '';
    
    # Check if this is a WebSocket upgrade request
    my $upgrade = $c->req->header('Upgrade') || '';
    my $connection = $c->req->header('Connection') || '';
    
    unless ($upgrade eq 'websocket' && $connection =~ /Upgrade/i) {
        $c->response->status(400);
        $c->response->body('WebSocket upgrade required');
        return;
    }
    
    # Load saved credentials if no password provided
    if (!$ssh_password) {
        my $credentials_file = "$ENV{HOME}/.comserv/secrets/ssh_credentials.json";
        if (-f $credentials_file) {
            if (open my $fh, '<', $credentials_file) {
                local $/;
                my $json = <$fh>;
                close $fh;
                my $creds = eval { decode_json($json) };
                $ssh_password = $creds->{ssh_password} if $creds;
            }
        }
    }
    
    unless ($ssh_password) {
        $c->response->status(400);
        $c->response->body('SSH password required');
        return;
    }
    
    # Import WebSocket modules
    require Protocol::WebSocket::Handshake::Server;
    require AnyEvent;
    require AnyEvent::Handle;
    
    # Get the raw IO handle
    my $io = $c->req->io_fh;
    
    # Perform WebSocket handshake
    my $hs = Protocol::WebSocket::Handshake::Server->new;
    
    # Parse the handshake from request headers
    my $env = $c->req->env;
    my $handshake_request = 
        "GET " . $env->{REQUEST_URI} . " HTTP/1.1\r\n" .
        "Host: " . $env->{HTTP_HOST} . "\r\n" .
        "Upgrade: " . ($env->{HTTP_UPGRADE} || 'websocket') . "\r\n" .
        "Connection: " . ($env->{HTTP_CONNECTION} || 'Upgrade') . "\r\n" .
        "Sec-WebSocket-Key: " . ($env->{HTTP_SEC_WEBSOCKET_KEY} || '') . "\r\n" .
        "Sec-WebSocket-Version: " . ($env->{HTTP_SEC_WEBSOCKET_VERSION} || '13') . "\r\n" .
        "\r\n";
    
    $hs->parse($handshake_request);
    
    # Send handshake response
    my $handshake_response = $hs->to_string;
    print $io $handshake_response;
    
    # Create AnyEvent handle for WebSocket
    my $handle = AnyEvent::Handle->new(
        fh => $io,
        on_error => sub {
            my ($hdl, $fatal, $msg) = @_;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'websocket_error',
                "WebSocket error: $msg");
            $hdl->destroy;
        }
    );
    
    # Spawn SSH process
    require IPC::Run3;
    
    my $ssh_cmd;
    if ($ssh_password) {
        $ssh_cmd = ['sshpass', '-p', $ssh_password, 'ssh', '-p', $ssh_port, 
                    '-o', 'StrictHostKeyChecking=no', 
                    '-o', 'UserKnownHostsFile=/dev/null',
                    $ssh_target];
    } else {
        $ssh_cmd = ['ssh', '-p', $ssh_port, $ssh_target];
    }
    
    # Use pseudo-terminal for interactive SSH
    require IO::Pty;
    my $pty = IO::Pty->new;
    
    my $pid = fork();
    
    if (!defined $pid) {
        $c->response->status(500);
        $c->response->body('Failed to fork SSH process');
        return;
    }
    
    if ($pid == 0) {
        # Child process
        $pty->make_slave_controlling_terminal();
        my $slave = $pty->slave();
        
        close STDIN;
        close STDOUT;
        close STDERR;
        
        open STDIN, '<&', $slave->fileno() or die "Can't redirect STDIN: $!";
        open STDOUT, '>&', $slave->fileno() or die "Can't redirect STDOUT: $!";
        open STDERR, '>&', $slave->fileno() or die "Can't redirect STDERR: $!";
        
        exec(@$ssh_cmd) or die "Can't exec SSH: $!";
    }
    
    # Parent process - proxy between WebSocket and PTY
    $pty->close_slave();
    $pty->set_raw();
    
    # Create frame parser
    require Protocol::WebSocket::Frame;
    my $frame = Protocol::WebSocket::Frame->new;
    
    # Declare pty_watcher variable for use in closure
    my $pty_watcher;
    
    # Read from PTY and send to WebSocket
    $pty_watcher = AnyEvent->io(
        fh => $pty,
        poll => 'r',
        cb => sub {
            my $buf;
            my $n = sysread($pty, $buf, 4096);
            if ($n) {
                my $ws_frame = Protocol::WebSocket::Frame->new(buffer => $buf, type => 'binary');
                $handle->push_write($ws_frame->to_bytes);
            } elsif (defined $n) {
                # EOF - SSH process exited
                $handle->destroy;
                undef $pty_watcher;
                waitpid($pid, 0);
            }
        }
    );
    
    # Read from WebSocket and send to PTY
    $handle->on_read(sub {
        my ($hdl) = @_;
        
        $frame->append(delete $hdl->{rbuf});
        
        while (my $message = $frame->next_bytes) {
            # Write to PTY
            syswrite($pty, $message);
        }
    });
    
    # Clean up on disconnect
    $handle->on_eof(sub {
        undef $pty_watcher;
        undef $handle;
        kill 'TERM', $pid if $pid;
        waitpid($pid, 0) if $pid;
    });
    
    # Enter event loop - this blocks until connection closes
    my $cv = AnyEvent->condvar;
    
    # Set up cleanup when connection ends
    my $cleanup = sub {
        undef $pty_watcher;
        $handle->destroy if $handle;
        kill 'TERM', $pid if $pid;
        waitpid($pid, 0) if $pid;
        $cv->send;
    };
    
    # Monitor SSH process
    my $child_watcher = AnyEvent->child(
        pid => $pid,
        cb => sub {
            my ($pid, $status) = @_;
            $cleanup->();
        }
    );
    
    # Wait for connection to close
    $cv->recv;
    
    # Prevent template rendering
    $c->detach();
}

sub end : Private {
    my ($self, $c) = @_;
    
    # Skip template rendering for WebSocket endpoints
    if ($c->req->path =~ m{/admin/(?:docker-ssh-terminal|system-shell-terminal|ssh_terminal_status|ssh_terminal_start_ttyd|shell_run_command|ttyd-proxy)} ) {
        return;
    }
    if ($c->action && ($c->action->name || '') =~ /^ttyd_proxy/) {
        return;
    }
    
    # Skip rendering for redirects and no-content responses
    my $status = $c->response->status || 0;
    return if $status >= 300 && $status < 400;
    return if $status == 204;

    # Normal template rendering for other requests
    $c->forward($c->view('TT')) unless $c->response->body;
}

# Helper method to convert table name to class name
sub table_name_to_class_name {
    my ($self, $table_name) = @_;
    
    # Convert snake_case or plural table names to PascalCase class names
    # Examples: user_sites -> UserSite, sites -> Site, network_devices -> NetworkDevice
    
    # Remove common plural suffixes and convert to singular
    my $singular = $table_name;
    $singular =~ s/s$// if $singular =~ /[^s]s$/;  # Remove trailing 's' but not 'ss'
    $singular =~ s/ies$/y/;  # categories -> category
    $singular =~ s/ves$/f/;  # leaves -> leaf
    
    # Convert to PascalCase
    my @words = split /_/, $singular;
    my $class_name = join '', map { ucfirst(lc($_)) } @words;
    
    return $class_name;
}

# Connect to the new MySQL Docker server and return database/table information.
# Credentials are read exclusively from environment variables (loaded from Comserv/.env).
sub get_migration_mysql_info {
    my ($self, $c) = @_;

    my $host     = $ENV{MIGRATION_MYSQL_HOST}     || '192.168.1.20';
    my $port     = $ENV{MIGRATION_MYSQL_PORT}     || 3307;
    my $user     = $ENV{MIGRATION_MYSQL_USER}     || 'root';
    my $password = $ENV{MIGRATION_MYSQL_PASSWORD} // '';

    unless ($password) {
        my $home = $ENV{HOME} || '';
        my $dbi_file = "$home/.comserv/secrets/dbi/db_production_mysql.json";
        if (-f $dbi_file) {
            eval {
                local $/;
                open my $fh, '<', $dbi_file or die $!;
                my $data = JSON::decode_json(<$fh>);
                close $fh;
                my ($cfg) = values %$data;
                $password = $cfg->{password} // '' if ref $cfg eq 'HASH';
                $host     = $cfg->{host}     if ref $cfg eq 'HASH' && $cfg->{host};
                $port     = $cfg->{port}     if ref $cfg eq 'HASH' && $cfg->{port};
                $user     = $cfg->{username} if ref $cfg eq 'HASH' && $cfg->{username};
            };
        }
    }

    unless ($password) {
        return {
            connection_status => 'error',
            error => 'MIGRATION_MYSQL_PASSWORD not set — add it to Comserv/.env or set credentials in the db_production_mysql server entry',
            databases => [],
        };
    }

    my $result = { connection_status => 'unknown', databases => [] };

    try {
        my $dsn = "DBI:mysql:host=$host;port=$port";
        my $dbh = DBI->connect($dsn, $user, $password, {
            RaiseError => 1, PrintError => 0, AutoCommit => 1, mysql_connect_timeout => 5,
        });

        my $sth = $dbh->prepare("SHOW DATABASES");
        $sth->execute();
        my @databases;
        while (my ($db_name) = $sth->fetchrow_array()) {
            next if $db_name =~ /^(information_schema|performance_schema|sys|mysql)$/i;

            my $db_entry = { name => $db_name, tables => [], table_count => 0, error => undef };

            eval {
                # Get all tables in this database
                my $tbl_sth = $dbh->prepare(
                    "SELECT TABLE_NAME 
                     FROM information_schema.TABLES 
                     WHERE TABLE_SCHEMA = ? AND TABLE_TYPE = 'BASE TABLE'
                     ORDER BY TABLE_NAME"
                );
                $tbl_sth->execute($db_name);

                my @tables;
                while (my ($tname) = $tbl_sth->fetchrow_array()) {
                    # Fetch column details for this table
                    my $col_sth = $dbh->prepare(
                        "SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE, COLUMN_DEFAULT
                         FROM information_schema.COLUMNS
                         WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
                         ORDER BY ORDINAL_POSITION"
                    );
                    $col_sth->execute($db_name, $tname);

                    my @cols;
                    while (my ($col_name, $data_type, $char_max_len, $is_nullable, $col_default) = $col_sth->fetchrow_array()) {
                        push @cols, {
                            column_name              => $col_name,
                            data_type                => $data_type,
                            character_maximum_length => $char_max_len,
                            is_nullable              => $is_nullable,
                            column_default           => $col_default,
                        };
                    }

                    push @tables, {
                        name      => $tname,
                        columns   => \@cols,
                        col_count => scalar(@cols),
                    };
                }

                $db_entry->{tables}      = \@tables;
                $db_entry->{table_count} = scalar(@tables);
            };
            if ($@) {
                $db_entry->{error} = "Failed to query database metadata: $@";
            }

            push @databases, $db_entry;
        }
        $dbh->disconnect();

        $result->{connection_status} = 'connected';
        $result->{databases} = \@databases;
        $result->{host} = "$host:$port";

    } catch {
        $result->{connection_status} = 'error';
        $result->{error} = "MySQL connection failed: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_migration_mysql_info', $result->{error});
    };

    return $result;
}

# Connect to the new PostgreSQL Docker server and return database/table information.
# Credentials are read exclusively from environment variables (loaded from Comserv/.env).
sub get_migration_postgres_info {
    my ($self, $c) = @_;

    my $host     = $ENV{MIGRATION_POSTGRES_HOST}     || '192.168.1.20';
    my $port     = $ENV{MIGRATION_POSTGRES_PORT}     || 5433;
    my $user     = $ENV{MIGRATION_POSTGRES_USER}     || 'postgres';
    my $password = $ENV{MIGRATION_POSTGRES_PASSWORD} // '';

    unless ($password) {
        my $home = $ENV{HOME} || '';
        my $dbi_file = "$home/.comserv/secrets/dbi/db_production_postgres.json";
        if (-f $dbi_file) {
            eval {
                local $/;
                open my $fh, '<', $dbi_file or die $!;
                my $data = JSON::decode_json(<$fh>);
                close $fh;
                my ($cfg) = values %$data;
                $password = $cfg->{password} // '' if ref $cfg eq 'HASH';
                $host     = $cfg->{host}     if ref $cfg eq 'HASH' && $cfg->{host};
                $port     = $cfg->{port}     if ref $cfg eq 'HASH' && $cfg->{port};
                $user     = $cfg->{username} if ref $cfg eq 'HASH' && $cfg->{username};
            };
        }
    }

    unless ($password) {
        return {
            connection_status => 'error',
            error => 'MIGRATION_POSTGRES_PASSWORD not set — add it to Comserv/.env or set credentials in the db_production_postgres server entry',
            databases => [],
        };
    }

    my $result = { connection_status => 'unknown', databases => [] };

    try {
        my $dsn = "DBI:Pg:host=$host;port=$port";
        my $dbh = DBI->connect($dsn, $user, $password, {
            RaiseError => 1, PrintError => 0, AutoCommit => 1,
        });

        my $sth = $dbh->prepare("SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname");
        $sth->execute();
        my @db_names;
        while (my ($db_name) = $sth->fetchrow_array()) {
            next if $db_name eq 'postgres';
            push @db_names, $db_name;
        }
        $dbh->disconnect();

        # Now connect to each database and fetch its schema
        my @databases;
        for my $db_name (@db_names) {
            my $db_entry = { name => $db_name, tables => [], table_count => 0, error => undef };
            eval {
                my $db_dbh = DBI->connect("DBI:Pg:dbname=$db_name;host=$host;port=$port",
                    $user, $password, { RaiseError => 1, PrintError => 0, AutoCommit => 1 });
                my $tsth = $db_dbh->prepare(
                    "SELECT t.tablename, COUNT(c.column_name)::int AS col_count
                     FROM pg_tables t
                     LEFT JOIN information_schema.columns c
                       ON c.table_schema = 'public' AND c.table_name = t.tablename
                     WHERE t.schemaname = 'public'
                     GROUP BY t.tablename
                     ORDER BY t.tablename");
                $tsth->execute();
                my @tables;
                while (my ($tname, $col_count) = $tsth->fetchrow_array()) {
                    # Fetch column details
                    my $csth = $db_dbh->prepare(
                        "SELECT column_name, data_type, character_maximum_length,
                                is_nullable, column_default
                         FROM information_schema.columns
                         WHERE table_schema = 'public' AND table_name = ?
                         ORDER BY ordinal_position");
                    $csth->execute($tname);
                    my @cols;
                    while (my $col = $csth->fetchrow_hashref()) {
                        push @cols, $col;
                    }
                    push @tables, { name => $tname, col_count => $col_count, columns => \@cols };
                }
                $db_dbh->disconnect();
                $db_entry->{tables}      = \@tables;
                $db_entry->{table_count} = scalar @tables;
            };
            $db_entry->{error} = $@ if $@;
            push @databases, $db_entry;
        }

        $result->{connection_status} = 'connected';
        $result->{databases} = \@databases;
        $result->{host} = "$host:$port";

    } catch {
        $result->{connection_status} = 'error';
        my $err = "$_";
        $result->{error} = "PostgreSQL connection failed: $err";
        my $level = ($err =~ /No route to host|Connection refused|timeout/i) ? 'warn' : 'error';
        $self->logging->log_with_details($c, $level, __FILE__, __LINE__, 'get_migration_postgres_info', $result->{error});
    };

    return $result;
}

# Helper method to determine Result file path
sub get_result_file_path {
    my ($self, $c, $table_name, $database) = @_;
    
    my $class_name = $self->table_name_to_class_name($table_name);
    my $namespace = $database eq 'ency' ? 'Ency' : 'Forager';
    
    # Build the file path
    my $base_path = $c->path_to('lib', 'Comserv', 'Model', 'Schema', $namespace, 'Result');
    my $result_file_path = File::Spec->catfile($base_path, "$class_name.pm");
    
    return $result_file_path;
}

# Page Migration action: Forager -> Ency
sub migrate_pages :Path('/admin/migrate_pages') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'migrate_pages', 
        "Starting migrate_pages action");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'migrate_pages')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }
    
    my $action = $c->req->param('action') || '';
    
    if ($action eq 'preview') {
        my $preview_data = $self->_preview_page_migration($c);
        $c->stash(
            show_preview => 1,
            preview_data => $preview_data,
            template => 'admin/migrate_pages.tt'
        );
    }
    elsif ($action eq 'migrate') {
        my @selected_ids = $c->req->param('selected_pages');
        my $result = $self->_perform_page_migration($c, \@selected_ids);
        $c->stash(
            show_result => 1,
            migration_result => $result,
            template => 'admin/migrate_pages.tt'
        );
    }
    else {
        $c->stash(
            template => 'admin/migrate_pages.tt'
        );
    }
}

# Helper method to preview page migration
sub _preview_page_migration {
    my ($self, $c) = @_;
    
    my @forager_pages;
    eval {
        @forager_pages = $c->model('DBForager')->resultset('Page')->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_preview_page_migration', 
            "Error fetching Forager pages: $@");
        return {
            total_count => 0,
            issues_count => 0,
            mapping_issues => [{ error => "Failed to load Forager pages: $@" }],
            forager_pages => []
        };
    }
    
    my $total_count = scalar @forager_pages;
    my $issues_count = 0;
    my @mapping_issues;
    
    foreach my $f_page (@forager_pages) {
        my @issues;
        
        # Check required fields
        push @issues, "Missing sitename" unless $f_page->sitename;
        push @issues, "Missing menu" unless $f_page->menu;
        push @issues, "Missing page_code" unless $f_page->page_code;
        
        # Check duplicate page_code in Ency.page for the same site.
        if ($f_page->page_code) {
            my $exists = $c->model('DBEncy')->resultset('Page')->search({
                sitename  => $f_page->sitename || 'CSC',
                page_code => $f_page->page_code,
            }, { rows => 1 })->single;
            if ($exists) {
                push @issues, "Page code already exists in destination for site " . ($f_page->sitename || 'CSC');
            }
        }
        
        if (@issues) {
            $issues_count++;
            push @mapping_issues, {
                page => $f_page,
                issues => \@issues
            };
        }
    }
    
    return {
        total_count => $total_count,
        issues_count => $issues_count,
        mapping_issues => \@mapping_issues,
        forager_pages => \@forager_pages
    };
}

# Helper method to perform page migration
sub _perform_page_migration {
    my ($self, $c, $selected_ids) = @_;
    
    my $migrated_count = 0;
    my $skipped_count = 0;
    my $error_count = 0;
    my @migration_log;
    my @errors;
    
    foreach my $id (@$selected_ids) {
        my $f_page = eval { $c->model('DBForager')->resultset('Page')->find({ record_id => $id }) };
        unless ($f_page) {
            $error_count++;
            push @errors, "Could not find Forager page with record_id: $id";
            next;
        }
        
        # Safety checks
        my $exists = eval {
            $c->model('DBEncy')->resultset('Page')->search({
                sitename  => $f_page->sitename || 'CSC',
                page_code => $f_page->page_code,
            }, { rows => 1 })->single;
        };
        if ($exists) {
            $skipped_count++;
            push @migration_log, "Skipped duplicate: " . ($f_page->sitename || 'CSC') . "/" . $f_page->page_code;
            next;
        }
        
        # Build page data
        my $page_data = {
            sitename => $f_page->sitename || 'CSC',
            menu => $f_page->menu || 'Main',
            page_code => $f_page->page_code,
            title => $f_page->app_title || $f_page->page_code,
            body => $f_page->body || '',
            description => $f_page->description,
            keywords => $f_page->keywords,
            link_order => $f_page->link_order || 0,
            status => $f_page->status || 'active',
            roles => 'public', # default
            created_by => $f_page->username_of_poster || 'migrated',
        };
        
        eval {
            $c->model('DBEncy')->resultset('Page')->create($page_data);
            $migrated_count++;
            push @migration_log, "Successfully migrated: " . $f_page->page_code;
        };
        if ($@) {
            $error_count++;
            push @errors, "Failed to migrate " . $f_page->page_code . ": $@";
        }
    }
    
    return {
        migrated_count => $migrated_count,
        skipped_count => $skipped_count,
        error_count => $error_count,
        migration_log => \@migration_log,
        errors => \@errors
    };
}

# Admin: Page Management UI
sub pages :Path('/admin/pages') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'pages', 
        "Starting admin pages action");
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'pages')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }
    
    my $action = $c->req->param('action') || '';
    my $current_sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    
    # Handle deletion
    if ($action eq 'delete') {
        my $id = $c->req->param('id');
        my $page = eval { $c->model('DBEncy')->resultset('Page')->find({ id => $id }) };
        if ($page) {
            # Site isolation check: non-CSC admins can only delete pages from their own site
            if ($current_sitename ne 'CSC' && $page->sitename ne $current_sitename) {
                $c->flash->{error_msg} = "Access denied: You can only delete pages belonging to your own site.";
            } else {
                my $code = $page->page_code;
                eval {
                    $page->delete;
                    $c->flash->{success_msg} = "Page '$code' deleted successfully.";
                };
                if ($@) {
                    $c->flash->{error_msg} = "Failed to delete page: $@";
                }
            }
        } else {
            $c->flash->{error_msg} = "Page not found for deletion.";
        }
        $c->response->redirect($c->uri_for('/admin/pages'));
        return;
    }
    
    my $show_form = undef;
    my $page_item = {};
    
    my $pages_ctrl = $c->controller('Pages');

    if ($action eq 'create') {
        $show_form = 'create';
        my $clone_id = $c->req->param('clone_id');
        if ($clone_id) {
            my $cloned = eval { $c->model('DBEncy')->resultset('Page')->find({ id => $clone_id }) };
            if ($cloned) {
                $page_item = {
                    sitename    => $current_sitename,
                    menu        => $cloned->menu || 'Main',
                    page_code   => $cloned->page_code,
                    title       => $cloned->title . ' (Copy)',
                    body        => $cloned->body,
                    description => $cloned->description,
                    keywords    => $cloned->keywords,
                    link_order  => $cloned->link_order || 0,
                    status      => 'active',
                    roles       => $cloned->roles || 'public',
                };
            }
        }
        unless (keys %$page_item) {
            $page_item = {
                sitename => $current_sitename,
                menu => 'Main',
                status => 'active',
                roles => 'public',
            };
        }
    }
    elsif ($action eq 'edit') {
        my $id = $c->req->param('id');
        my $page = eval { $c->model('DBEncy')->resultset('Page')->find({ id => $id }) };
        if ($page) {
            # Site isolation check: non-CSC admins can only edit pages from their own site
            if ($current_sitename ne 'CSC' && $page->sitename ne $current_sitename) {
                $c->flash->{error_msg} = "Access denied: You can only edit pages belonging to your own site.";
            } else {
                $show_form = 'edit';
                $page_item = $page;
            }
        } else {
            $c->flash->{error_msg} = "Page not found for editing.";
        }
    }
    elsif ($action eq 'save') {
        $pages_ctrl->ensure_page_submenu_column($c) if $pages_ctrl;
        my $params = $c->req->params;
        my $id = $params->{id};
        
        my $allowed_sites = $pages_ctrl
            ? $pages_ctrl->admin_available_sites($c)
            : [ $current_sitename ];
        my %allowed_site = map { $_ => 1 } @$allowed_sites;

        my $target_sitename = $params->{sitename} || $current_sitename;
        unless ($allowed_site{$target_sitename}) {
            $c->stash(error_msg => "Invalid site '$target_sitename'. Choose a site you have access to.");
            $show_form = $id ? 'edit' : 'create';
            $page_item = $params;
        }
        elsif ($current_sitename ne 'CSC' && $target_sitename ne $current_sitename) {
            $c->stash(error_msg => "Access denied: You can only save pages belonging to your own site.");
            $show_form = $id ? 'edit' : 'create';
            $page_item = $params;
        } else {
            my $page_data = {
                sitename => $target_sitename,
                menu => $params->{menu} || 'Main',
                submenu => $params->{submenu} || '',
                page_code => $params->{page_code},
                title => $params->{title},
                body => $params->{body} || '',
                description => $params->{description},
                keywords => $params->{keywords},
                link_order => $params->{link_order} || 0,
                status => $params->{status} || 'active',
                roles => $params->{roles} || 'public',
                share_with => $params->{share_with} || '',
            };
            
            my $success = 0;
            if ($id) {
                # Editing existing page
                my $page = eval { $c->model('DBEncy')->resultset('Page')->find({ id => $id }) };
                if ($page) {
                    if ($current_sitename ne 'CSC' && $page->sitename ne $current_sitename) {
                        $c->stash(error_msg => "Access denied: You can only modify pages belonging to your own site.");
                        $show_form = 'edit';
                        $page_item = $params;
                    } else {
                        eval {
                            $page->update($page_data);
                            $c->flash->{success_msg} = "Page updated successfully.";
                            $success = 1;
                        };
                        if ($@) {
                            $c->stash(error_msg => "Error updating page: $@");
                            $show_form = 'edit';
                            $page_item = $params;
                        }
                    }
                } else {
                    $c->stash(error_msg => "Page not found to update.");
                }
            } else {
                # Creating new page
                $page_data->{created_by} = $c->session->{username} || 'admin';
                eval {
                    $c->model('DBEncy')->resultset('Page')->create($page_data);
                    $c->flash->{success_msg} = "Page created successfully.";
                    $success = 1;
                };
                if ($@) {
                    $c->stash(error_msg => "Error creating page: $@");
                    $show_form = 'create';
                    $page_item = $params;
                }
            }
            
            if ($success) {
                $c->response->redirect($c->uri_for('/admin/pages'));
                return;
            }
        }
    }
    
    # Fetch pages according to site context for list display
    my @pages;
    eval {
        if ($current_sitename eq 'CSC') {
            @pages = $c->model('DBEncy')->resultset('Page')->all;
        } else {
            # Regular site admins see their own pages + shared pages
            @pages = $c->model('DBEncy')->resultset('Page')->search({
                '-or' => [
                    { sitename => $current_sitename },
                    { share_with => 'all' },
                    { share_with => { 'like' => "%$current_sitename%" } }
                ]
            })->all;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'pages', 
            "Error fetching Ency pages: $@");
        $c->stash(error_msg => "Error fetching pages: $@") unless $c->stash->{error_msg};
    }
    
    # Standard roles drop down
    my @available_roles = ('public', 'member', 'coop', 'it', 'helpdesk', 'admin');
    # Fetch site-specific custom roles
    eval {
        my $roles_rs = $c->model('DBEncy')->resultset('SiteRole')->search({
            sitename => [ $current_sitename, 'All' ]
        });
        while (my $r = $roles_rs->next) {
            push @available_roles, $r->role_name;
        }
    };
    
    # Unique roles list
    my %seen;
    @available_roles = grep { !$seen{$_}++ } @available_roles;
    
    # Fetch all sites for the dropdown check list (Cross-Site Page Sharing)
    my @sites_list;
    eval {
        my $sites_rs = $c->model('DBEncy')->resultset('Site')->all;
        while (my $s = $sites_rs->next) {
            push @sites_list, $s->name;
        }
    };

    my $available_sites = $pages_ctrl
        ? $pages_ctrl->admin_available_sites($c)
        : [ $current_sitename ];

    my $form_sitename = ref($page_item) ? $page_item->sitename : ($page_item->{sitename} || $current_sitename);
    my %form_extras;
    if ($show_form && $pages_ctrl) {
        %form_extras = %{ $pages_ctrl->admin_page_form_extras($c, $form_sitename) };
    }
    
    $c->stash(
        pages => \@pages,
        show_form => $show_form,
        page_item => $page_item,
        current_site => $current_sitename,
        available_roles => \@available_roles,
        available_sites => $available_sites,
        all_sites => \@sites_list,
        sites_list => \@sites_list,
        is_csc => (lc($current_sitename) eq 'csc'),
        %form_extras,
        template => 'admin/pages.tt'
    );
}

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

use Comserv::Util::DevServerControl;
use Comserv::Util::BranchServerControl;
use Comserv::Util::UserPreferences;

sub dev_server_status :Path('/admin/dev_server/status') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    my $ctrl = Comserv::Util::DevServerControl->new;
    $c->response->body(encode_json($ctrl->status));
}

sub dev_server_start :Path('/admin/dev_server/start') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    my $ctrl = Comserv::Util::DevServerControl->new;
    my $cmd  = $c->req->param('command');
    my $res  = $ctrl->start($cmd);
    $c->response->body(encode_json($res));
}

sub dev_server_stop :Path('/admin/dev_server/stop') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    my $ctrl = Comserv::Util::DevServerControl->new;
    my $res  = $ctrl->stop;
    $c->response->body(encode_json($res));
}

sub branch_server_action :Path('/admin/branch_server_action') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    my $action = $c->req->param('action') || '';
    my $branch = $c->req->param('branch') || '';
    my $port   = $c->req->param('port')   || '';
    return $c->response->body(encode_json({ok=>0,error=>'Missing branch or port'}))
        unless $branch && $port;

    my $ctrl = Comserv::Util::BranchServerControl->new;

    if ($action eq 'start') {
        my $res = $ctrl->start($branch, $port);
        $c->response->body(encode_json($res));
    }
    elsif ($action eq 'stop') {
        my $res = $ctrl->stop($branch, $port);
        $c->response->body(encode_json($res));
    }
    elsif ($action eq 'restart') {
        my $res = $ctrl->restart($branch, $port);
        $c->response->body(encode_json($res));
    }
    elsif ($action eq 'open') {
        my $res = $ctrl->open_or_start($branch, $port);
        $c->response->body(encode_json($res));
    }
    else {
        $c->response->body(encode_json({ok=>0, error=>'Unknown action'}));
    }
}

__PACKAGE__->meta->make_immutable;

1;

package Comserv::Controller::Coding;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use Comserv::Util::Logging;
use Comserv::Util::CodingAccess;
use JSON qw(decode_json encode_json);
use Try::Tiny;
use POSIX qw(WNOHANG);


BEGIN { extends 'Catalyst::Controller'; }

sub logging {
    my ($self) = @_;
    return $self->{_logging} ||= Comserv::Util::Logging->new();
}

sub _coding_workstation_allowed {
    my ($self, $c) = @_;
    return Comserv::Util::CodingAccess::workstation_allowed($c);
}

sub _deny_json {
    my ($self, $c, $status, $error) = @_;
    $c->response->status($status || 403);
    $c->response->content_type('application/json');
    $c->response->body(encode_json({ success => JSON::false, error => $error }));
}

sub _ai_ctrl {
    my ($self, $c) = @_;
    return $c->model('AI')->config;
}

=head2 terminal_status

GET /coding/terminal_status — whether the interactive coding terminal is available.

=cut

sub terminal_status :Local :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $allowed = $self->_coding_workstation_allowed($c);
    my $cfg = $self->_ai_ctrl($c);
    my $root = $cfg ? $cfg->_project_root_path($c) : '';
    my $interactive_ws = $cfg && $cfg->can('_interactive_ws_available')
        ? ($cfg->_interactive_ws_available($c) ? 1 : 0) : 0;

    $c->response->body(encode_json({
        success          => JSON::true,
        allowed          => $allowed ? JSON::true : JSON::false,
        username         => $c->session->{username} || '',
        host             => $c->req->uri->host || '',
        project_root     => $root,
        terminal_ws_path => '/coding/terminal_ws',
        cli_mode         => $interactive_ws ? 'pty' : 'http',
        interactive_ws_available => $interactive_ws ? JSON::true : JSON::false,
        hint             => $allowed
            ? ($interactive_ws
                ? 'Interactive PTY shell — run grok, ollama, git, prove, etc.'
                : 'HTTP CLI tab — Grok, Ollama, and shell via /ai endpoints (works on :3000 Docker).')
            : 'Coding CLI requires Shanta on workstation.local, workstation.zero, or 172.30.131.126',
    }));
}

=head2 run_command

POST /coding/run_command — one-shot command in project root (non-interactive fallback).

=cut

sub run_command :Local :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    unless ($self->_coding_workstation_allowed($c)) {
        $self->_deny_json($c, 403, 'Coding commands require Shanta on http://172.30.131.126:PORT/');
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

    my $cfg = $self->_ai_ctrl($c);
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
    my $home    = $cfg->_grok_home();

    local $ENV{XAI_API_KEY} = $api_key if $api_key;
    local $ENV{GROK_API_KEY} = $api_key if $api_key;
    local $ENV{GROK_MODEL}   = 'grok-4.3';
    local $ENV{HOME}     = $home || $ENV{HOME};
    local $ENV{USER}     = 'shanta';
    local $ENV{LOGNAME}  = 'shanta';
    local $ENV{PATH}     = join ':', grep { $_ && -d $_ }
        ("$home/.local/bin", "$home/.grok/bin", '/usr/local/bin', '/usr/bin', '/bin');
    local $ENV{TERM}     = 'xterm-256color';
    local $ENV{LANG}     = $ENV{LANG} || 'en_US.UTF-8';
    local $ENV{LC_ALL}   = $ENV{LC_ALL} || 'en_US.UTF-8';

    my $output = qx($cmd 2>&1) // '';
    my $exit_val = ($? == -1) ? -1 : ($? >> 8);

    $c->response->body(encode_json({
        success   => JSON::true,
        output    => $output,
        exit_code => $exit_val,
    }));
}

sub _pty_resize {
    my ($pty, $cols, $rows) = @_;
    return unless defined $cols && defined $rows && $cols > 0 && $rows > 0;
    eval {
        require IO::Tty;
        IO::Tty::set_winsize($pty, $rows, $cols);
    };
    if ($@) {
        eval {
            require 'sys/ioctl.ph';
            ioctl($pty, &TIOCSWINSZ, pack('S4', $rows, $cols, 0, 0));
        };
    }
}

sub _coding_shell_env {
    my ($self, $c) = @_;
    my $cfg = $self->_ai_ctrl($c);
    return {
        root    => $cfg ? $cfg->_project_root_path($c) : '/home/shanta/PycharmProjects/comserv2',
        home    => $cfg ? $cfg->_grok_home() : '/home/shanta',
        api_key => $cfg ? $cfg->_grok_cli_api_key($c) : undef,
    };
}

sub _spawn_coding_shell {
    my ($self, $pty, $env) = @_;
    $env ||= {};
    my $root = $env->{root} || '/home/shanta/PycharmProjects/comserv2';
    my $home = $env->{home} || '/home/shanta';
    my $api_key = $env->{api_key};

    my $path = join ':', grep { $_ && -d $_ }
        ("$home/.local/bin", "$home/.grok/bin", '/usr/local/bin', '/usr/bin', '/bin');

    my $shell = -x '/bin/bash' ? '/bin/bash' : ($ENV{SHELL} || '/bin/sh');

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        $pty->make_slave_controlling_terminal();
        my $slave = $pty->slave();

        close STDIN;
        close STDOUT;
        close STDERR;

        open STDIN,  '<&', $slave->fileno() or die "Can't redirect STDIN: $!";
        open STDOUT, '>&', $slave->fileno() or die "Can't redirect STDOUT: $!";
        open STDERR, '>&', $slave->fileno() or die "Can't redirect STDERR: $!";

        $ENV{HOME}        = $home;
        $ENV{USER}        = 'shanta';
        $ENV{LOGNAME}     = 'shanta';
        $ENV{PATH}        = $path;
        $ENV{TERM}        = 'xterm-256color';
        $ENV{LANG}        = $ENV{LANG} || 'en_US.UTF-8';
        $ENV{LC_ALL}      = $ENV{LC_ALL} || 'en_US.UTF-8';
        $ENV{PS1}         = '\[\033[01;32m\]\u@workstation\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ ';
        $ENV{XAI_API_KEY} = $api_key if $api_key;
        $ENV{GROK_API_KEY} = $api_key if $api_key;

        chdir $root or chdir $home or die "chdir failed: $!";

        if ($env->{login_shell}) {
            exec($shell, '-l') or exec($shell, '-i') or exec($shell) or die "Can't exec shell: $!";
        }
        elsif ($shell =~ /bash/) {
            exec($shell, '--noprofile', '--norc', '-i') or exec($shell, '-i') or exec($shell) or die "Can't exec shell: $!";
        }
        exec($shell) or die "Can't exec shell: $!";
    }

    return $pid;
}

sub _terminal_relay_child {
    my ($self, $io, $env) = @_;
    $env ||= {};

    require AnyEvent;
    require AnyEvent::Handle;
    require IO::Pty;
    require Protocol::WebSocket::Frame;

    my $handle = AnyEvent::Handle->new(
        fh => $io,
        on_error => sub {
            my ($hdl, $fatal, $msg) = @_;
            warn "coding terminal WebSocket error: $msg\n";
            $hdl->destroy;
        }
    );

    my $pty = IO::Pty->new;
    my $pid = eval { $self->_spawn_coding_shell($pty, $env) };
    if ($@ || !defined $pid) {
        warn "coding terminal failed to spawn shell: " . ($@ || 'unknown') . "\n";
        return;
    }

    warn "coding terminal shell started pid=$pid\n";

    $pty->close_slave();
    $pty->set_raw();
    $self->_pty_resize($pty, 120, 30);

    my $frame = Protocol::WebSocket::Frame->new;
    my $pty_watcher;

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
                # PTY EOF — confirm child exited before tearing down the socket
                my $dead = waitpid($pid, WNOHANG);
                if ($dead == $pid || $dead == -1) {
                    $handle->destroy;
                    undef $pty_watcher;
                    waitpid($pid, 0) if $dead == $pid;
                }
            }
        }
    );

    $handle->on_read(sub {
        my ($hdl) = @_;
        $frame->append(delete $hdl->{rbuf});
        while (my $message = $frame->next_bytes) {
            next unless defined $message && length $message;
            if (substr($message, 0, 1) eq "\x01") {
                my $ctrl = eval { decode_json(substr($message, 1)) };
                if ($ctrl && ref $ctrl eq 'HASH' && ($ctrl->{type} || '') eq 'resize') {
                    $self->_pty_resize($pty, $ctrl->{cols}, $ctrl->{rows});
                }
                next;
            }
            my $offset = 0;
            my $len = length($message);
            while ($offset < $len) {
                my $w = syswrite($pty, $message, $len - $offset, $offset);
                last unless defined $w && $w > 0;
                $offset += $w;
            }
        }
    });

    my $cv = AnyEvent->condvar;
    my $cleanup = sub {
        my ($why) = @_;
        warn "coding terminal relay cleanup: $why\n";
        undef $pty_watcher;
        $handle->destroy if $handle;
        kill 'TERM', $pid if $pid;
        waitpid($pid, 0) if $pid;
        $cv->send;
    };

    $handle->on_eof(sub { $cleanup->('websocket eof') });

    AnyEvent->child(
        pid => $pid,
        cb => sub { $cleanup->('shell exited') },
    );

    $cv->recv;
}

=head2 terminal_ws

WebSocket PTY terminal at /coding/terminal_ws — interactive grok/ollama shell on the workstation.

=cut

sub terminal_ws :Path('/coding/terminal_ws') :Args(0) {
    my ($self, $c) = @_;

    my $req_host = lc($c->req->uri->host || '');
    $req_host =~ s/:\d+\z//;

    unless ($self->_coding_workstation_allowed($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'terminal_ws', "Coding terminal denied for host=$req_host user="
                . ($c->session->{username} || ''));
        $c->response->status(403);
        $c->response->body('Access denied: Shanta on 172.30.131.126 only');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'terminal_ws', "Coding terminal WebSocket upgrade host=$req_host");

    my $upgrade = $c->req->header('Upgrade') || '';
    my $connection = $c->req->header('Connection') || '';

    unless ($upgrade eq 'websocket' && $connection =~ /Upgrade/i) {
        $c->response->status(400);
        $c->response->body('WebSocket upgrade required');
        return;
    }

    require Protocol::WebSocket::Handshake::Server;
    require AnyEvent;
    require AnyEvent::Handle;
    require IO::Pty;

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
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'terminal_ws', 'WebSocket handshake failed to complete');
        $c->response->status(400);
        $c->response->body('WebSocket handshake failed');
        return;
    }

    print $io $hs->to_string;
    $io->flush if $io->can('flush');
    $c->detach();

    my $shell_env = $self->_coding_shell_env($c);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'terminal_ws', 'Terminal relay started (same process)');
    $self->_terminal_relay_child($io, $shell_env);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'terminal_ws', 'Terminal relay ended');
}

sub end : Private {
    my ($self, $c) = @_;
    return if $c->req->path =~ m{/coding/terminal_ws};
    my $path = $c->req->path || '';
    return if $path =~ m{^/admin/};
    return if $path =~ m{dev-preview};
    return if $path =~ m{^/home/} || $path =~ m{^/[a-zA-Z]:/} || $path =~ m{/script$};
    # Also skip any path that looks like a filesystem path (contains /script/ or similar)
    return if $path =~ m{/script/};
    my $status = $c->response->status || 0;
    return if $status >= 300 && $status < 400;
    return if $status == 204;
    $c->forward($c->view('TT')) unless $c->response->body;
}

# Resolve an error stack trace path (handles ../ and searches the codebase)
sub _resolve_error_file {
    my ($self, $c, $error_text) = @_;
    return unless $error_text;

    # Extract file path from typical Perl error: "at /path/file.pm line 68"
    if ($error_text =~ /at\s+([^\s]+?)\s+line\s+\d+/i) {
        my $raw_path = $1;

        # Resolve .. segments
        my $resolved = $raw_path;
        $resolved =~ s{script/\.\./}{};
        $resolved =~ s{/\./}{/}g;
        while ($resolved =~ s{[^/]+/\.\./}{}) {}

        # If the resolved path exists on disk, return it
        if (-f $resolved) {
            return $resolved;
        }

        # Otherwise search the project root for a file with the same basename
        my ($basename) = $raw_path =~ m{([^/]+)$};
        if ($basename) {
            my $root = $self->_project_root_path($c);
            require File::Find;
            my @matches;
            File::Find::find(sub {
                return unless -f $_;
                push @matches, $File::Find::name if $_ eq $basename;
            }, $root);
            return $matches[0] if @matches;
        }
    }
    return undef;
}

__PACKAGE__->meta->make_immutable;

1;

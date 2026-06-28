package Comserv::Util::SystemInfo;

# CRITICAL: Debug Bar System Information Module - DO NOT REMOVE
# This module provides hostname, IP, and system info used by the debug bar
# to display server diagnostics to admins and debug mode users.
# Removing this breaks Root.pm debug bar rendering and admin page visibility.

use strict;
use warnings;
use Socket;
use Sys::Hostname;
use Comserv::Util::Logging;

my $logging = Comserv::Util::Logging->instance;

=head1 NAME

Comserv::Util::SystemInfo - Utility functions for system information

=head1 DESCRIPTION

This module provides utility functions for retrieving system information
such as hostname, IP address, etc.

=head1 METHODS

=head2 get_server_hostname

Returns the hostname of the server

=cut

sub get_server_hostname {
    my $name = hostname();
    # CRITICAL: Ensure return value is never empty - must be valid hostname or 'Unknown'
    if (!$name || $name eq '') {
        return 'Unknown';
    }
    return $name;
}

=head2 get_server_ip

Returns the IP address of the server

=cut

sub get_server_ip {
    my $ip;

    # Method 0: Operator-supplied override via env var (highest priority)
    if ($ENV{CATALYST_SERVER_IP} && $ENV{CATALYST_SERVER_IP} ne '') {
        return $ENV{CATALYST_SERVER_IP};
    }

    # Method 1: Use the OS routing table to find the IP used for outbound traffic
    # This works on any machine without hard-coded IPs.
    eval {
        # Try modern 'ip route' first (Linux)
        my $out = `ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print \$7; exit}'`;
        chomp $out;
        if ($out && $out =~ /^\d+\.\d+\.\d+\.\d+$/ && $out ne '127.0.0.1') {
            $ip = $out;
        }
    };

    # Method 2: Fallback – parse 'hostname -I' (works on most Linux distros)
    unless ($ip) {
        eval {
            my $out = `hostname -I 2>/dev/null | awk '{print \$1}'`;
            chomp $out;
            if ($out && $out =~ /^\d+\.\d+\.\d+\.\d+$/ && $out ne '127.0.0.1') {
                $ip = $out;
            }
        };
    }

    # Method 3: Socket trick (connect to public DNS, read local address)
    unless ($ip) {
        eval {
            socket(my $sock, PF_INET, SOCK_DGRAM, 0) or die;
            connect($sock, sockaddr_in(53, inet_aton('8.8.8.8')));
            my $local = getsockname($sock);
            my (undef, $addr) = sockaddr_in($local);
            $ip = inet_ntoa($addr);
            close($sock);
            $ip = undef if $ip eq '127.0.0.1';
        };
    }

    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'get_server_ip', "Error: $@");
    }

    return $ip || 'Unknown';
}

=head2 get_system_info

Returns a hash of system information

=cut

sub get_system_info {
    my $hostname = get_server_hostname();
    my $ip = get_server_ip();
    
    return {
        hostname => $hostname,
        ip => $ip,
        os => $^O,
        perl_version => $^V,
    };
}

=head2 get_app_workflow

Returns the name of the application directory (workflow)

=cut

sub get_app_workflow {
    my ($class, $app_home) = @_;
    
    return 'main' if !$app_home;
    
    my $workflow = 'main';
    eval {
        require File::Basename;
        require Cwd;
        
        my $parent   = File::Basename::dirname($app_home);
        my $resolved = Cwd::abs_path($parent) || $parent;

        # Zenflow worktree paths contain /.zenflow/worktrees/<branch-name>/
        # e.g. /home/user/.zenflow/worktrees/planningsystem-59ae/Comserv
        if ($resolved =~ m{/\.zenflow/worktrees/([^/]+)}) {
            $workflow = $1;
        }
        # Otherwise this is main / production — leave as 'main'
    };
    
    return $workflow || 'main';
}

1;
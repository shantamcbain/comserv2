package Comserv::Util::SystemInfo;

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
    return hostname();
}

=head2 get_server_ip

Returns the IP address of the server

=cut

sub get_server_ip {
    my $ip;
    
    # Try multiple methods to get the server IP
    
    # Method 1: Use Socket to get IP from hostname
    eval {
        my $hostname = hostname();
        $ip = inet_ntoa(scalar gethostbyname($hostname || 'localhost'));
        
        # Skip localhost addresses
        if ($ip eq '127.0.0.1' || $ip eq '::1') {
            $ip = undef;
        }
    };
    
    if ($@ || !$ip) {
        # Method 2: Parse ifconfig/ip addr output
        eval {
            my $cmd = -x '/sbin/ifconfig' ? '/sbin/ifconfig' : 
                     (-x '/bin/ifconfig' ? '/bin/ifconfig' : 
                     (-x '/usr/bin/ip' ? '/usr/bin/ip addr' : ''));
            
            if ($cmd) {
                my $output = `$cmd`;
                # Look for non-loopback IPv4 addresses
                while ($output =~ /inet (?:addr:)?(\d+\.\d+\.\d+\.\d+).*?(?:netmask|Mask)/g) {
                    my $found_ip = $1;
                    # Skip localhost addresses
                    if ($found_ip ne '127.0.0.1') {
                        $ip = $found_ip;
                        last;
                    }
                }
                
                # If no IPv4 address found, try IPv6
                if (!$ip && $output =~ /inet6 (?:addr:)?([0-9a-f:]+)/) {
                    my $found_ip = $1;
                    # Skip localhost addresses
                    if ($found_ip ne '::1') {
                        $ip = $found_ip;
                    }
                }
            }
        };
    }
    
    # Method 3: Try to get IP by connecting to a public server
    if ($@ || !$ip) {
        eval {
            # Create a UDP socket
            socket(my $socket, PF_INET, SOCK_DGRAM, 0) or die "socket: $!";
            # We don't actually connect, just set the destination
            connect($socket, sockaddr_in(53, inet_aton("8.8.8.8")));
            # Get our own sockaddr_in
            my $sockaddr = getsockname($socket);
            # Extract the IP
            my ($port, $address) = sockaddr_in($sockaddr);
            $ip = inet_ntoa($address);
            close($socket);
            
            # Skip localhost addresses
            if ($ip eq '127.0.0.1' || $ip eq '::1') {
                $ip = undef;
            }
        };
    }
    
    # Log any errors
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'get_server_ip', "Error getting server IP: $@");
    }
    
    # Return the IP or a default message
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

1;
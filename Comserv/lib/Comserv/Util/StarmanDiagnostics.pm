package Comserv::Util::StarmanDiagnostics;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use POSIX qw(strftime);
use File::Spec;
use Cwd;

=head1 NAME

Comserv::Util::StarmanDiagnostics - Web-safe Starman service diagnostics

=head1 DESCRIPTION

This module provides comprehensive diagnostics for Starman service without
requiring interactive sudo commands. It focuses on checks that can be performed
safely from a web interface.

=cut

has 'logger' => (
    is => 'rw',
    isa => 'Object',
    required => 0,
);

# Execute comprehensive Starman diagnostics
sub execute_diagnostics {
    my ($self, $app_root) = @_;
    
    my $results = {
        timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),
        checks => [],
        summary => {},
        recommendations => []
    };
    
    try {
        # Check 1: Service file existence (read-only check)
        my $service_check = $self->check_service_file_exists();
        push @{$results->{checks}}, $service_check;
        
        # Check 2: Port availability (no sudo required)
        my $port_check = $self->check_port_availability();
        push @{$results->{checks}}, $port_check;
        
        # Check 3: Configuration files (file system checks)
        my $config_check = $self->check_configuration($app_root);
        push @{$results->{checks}}, $config_check;
        
        # Check 4: Dependencies (Perl module checks)
        my $deps_check = $self->check_dependencies();
        push @{$results->{checks}}, $deps_check;
        
        # Check 5: File permissions (read-only checks)
        my $perms_check = $self->check_file_permissions($app_root);
        push @{$results->{checks}}, $perms_check;
        
        # Check 6: System resources (read-only system info)
        my $resources_check = $self->check_system_resources();
        push @{$results->{checks}}, $resources_check;
        
        # Check 7: Application status (process checks)
        my $app_check = $self->check_application_status($app_root);
        push @{$results->{checks}}, $app_check;
        
        # Check 8: PSGI file validation
        my $psgi_check = $self->check_psgi_file($app_root);
        push @{$results->{checks}}, $psgi_check;
        
        # Generate summary
        my $total_checks = scalar(@{$results->{checks}});
        my $passed_checks = grep { $_->{status} eq 'pass' } @{$results->{checks}};
        my $failed_checks = grep { $_->{status} eq 'fail' } @{$results->{checks}};
        my $warning_checks = grep { $_->{status} eq 'warning' } @{$results->{checks}};
        
        $results->{summary} = {
            total => $total_checks,
            passed => $passed_checks,
            failed => $failed_checks,
            warnings => $warning_checks,
            overall_status => $failed_checks > 0 ? 'critical' : ($warning_checks > 0 ? 'warning' : 'healthy')
        };
        
        # Generate recommendations based on failed checks
        foreach my $check (@{$results->{checks}}) {
            if (($check->{status} eq 'fail' || $check->{status} eq 'warning') && $check->{recommendation}) {
                push @{$results->{recommendations}}, {
                    type => $check->{status} eq 'fail' ? 'danger' : 'warning',
                    message => $check->{recommendation},
                    check_name => $check->{name}
                };
            }
        }
        
    } catch {
        my $error = $_;
        $self->_log_error("Diagnostics failed: $error");
        
        push @{$results->{checks}}, {
            name => 'Diagnostic System Error',
            status => 'fail',
            message => "Diagnostic system encountered an error: $error",
            details => '',
            recommendation => 'Check system logs and ensure proper permissions'
        };
    };
    
    return $results;
}

# Check if service file exists (read-only)
sub check_service_file_exists {
    my ($self) = @_;
    
    my $check = {
        name => 'Starman Service File',
        status => 'unknown',
        message => '',
        details => '',
        recommendation => ''
    };
    
    try {
        my $service_file = '/etc/systemd/system/starman.service';
        my $service_exists = -f $service_file;
        my $service_readable = -r $service_file;
        
        if ($service_exists) {
            $check->{status} = 'pass';
            $check->{message} = 'Starman systemd service file exists';
            $check->{details} = "Service file found at: $service_file" . 
                               ($service_readable ? " (readable)" : " (not readable by web user)");
        } else {
            $check->{status} = 'fail';
            $check->{message} = 'Starman systemd service file does not exist';
            $check->{details} = "Service file not found at: $service_file";
            $check->{recommendation} = 'Create a systemd service file for Starman. This requires system administrator privileges.';
        }
        
    } catch {
        $check->{status} = 'fail';
        $check->{message} = 'Error checking service file';
        $check->{details} = "Error: $_";
    };
    
    return $check;
}

# Check port availability (no sudo required)
sub check_port_availability {
    my ($self) = @_;
    
    my $check = {
        name => 'Port Availability',
        status => 'unknown',
        message => '',
        details => '',
        recommendation => ''
    };
    
    try {
        # Common Starman ports to check
        my @ports_to_check = (5000, 3000, 8080, 8000);
        my @port_status = ();
        
        foreach my $port (@ports_to_check) {
            # Use netstat without sudo - it shows listening ports
            my $netstat_output = `netstat -tuln 2>/dev/null | grep :$port`;
            chomp $netstat_output;
            
            # Try to get process info if available (may not work without privileges)
            my $lsof_output = `lsof -i :$port 2>/dev/null`;
            chomp $lsof_output;
            
            if ($netstat_output) {
                push @port_status, {
                    port => $port,
                    status => 'occupied',
                    details => $netstat_output . ($lsof_output ? "\n$lsof_output" : "")
                };
            } else {
                push @port_status, {
                    port => $port,
                    status => 'available',
                    details => 'Port appears to be free'
                };
            }
        }
        
        my $available_ports = grep { $_->{status} eq 'available' } @port_status;
        
        if ($available_ports > 0) {
            $check->{status} = 'pass';
            $check->{message} = "Found $available_ports available port(s) for Starman";
        } else {
            $check->{status} = 'warning';
            $check->{message} = 'All common ports appear to be occupied';
            $check->{recommendation} = 'Consider using a different port (e.g., 5001, 5002) or check if services can be stopped';
        }
        
        $check->{details} = join("\n", map { "Port $_->{port}: $_->{status}" . ($_->{details} ? " - $_->{details}" : "") } @port_status);
        
    } catch {
        $check->{status} = 'fail';
        $check->{message} = 'Error checking port availability';
        $check->{details} = "Error: $_";
    };
    
    return $check;
}

# Check configuration files
sub check_configuration {
    my ($self, $app_root) = @_;
    
    my $check = {
        name => 'Application Configuration',
        status => 'unknown',
        message => '',
        details => '',
        recommendation => ''
    };
    
    try {
        my @config_issues = ();
        my @config_found = ();
        
        # Ensure we have a valid app root
        unless ($app_root && -d $app_root) {
            $check->{status} = 'fail';
            $check->{message} = 'Invalid application root directory';
            $check->{details} = "App root: " . ($app_root || 'undefined');
            return $check;
        }
        
        # Check for application script
        my $app_script = File::Spec->catfile($app_root, 'script', 'comserv_server.pl');
        if (-f $app_script) {
            if (-x $app_script) {
                push @config_found, "Application script: $app_script (executable)";
            } else {
                push @config_issues, "Application script not executable: $app_script";
            }
        } else {
            push @config_issues, "Application script missing: $app_script";
        }
        
        # Check for PSGI file
        my $psgi_file = File::Spec->catfile($app_root, 'comserv.psgi');
        if (-f $psgi_file) {
            push @config_found, "PSGI file: $psgi_file";
        } else {
            push @config_issues, "PSGI file not found: $psgi_file (can be auto-generated)";
        }
        
        # Check for configuration files
        my @config_files = (
            File::Spec->catfile($app_root, 'comserv.conf'),
            File::Spec->catfile($app_root, 'comserv_local.conf')
        );
        
        foreach my $config_file (@config_files) {
            if (-f $config_file) {
                push @config_found, "Config file: $config_file";
            }
        }
        
        # Check lib directory
        my $lib_dir = File::Spec->catdir($app_root, 'lib');
        if (-d $lib_dir && -r $lib_dir) {
            push @config_found, "Library directory accessible: $lib_dir";
        } else {
            push @config_issues, "Library directory not accessible: $lib_dir";
        }
        
        # Check application directory permissions
        if (-r $app_root && -x $app_root) {
            push @config_found, "Application directory accessible: $app_root";
        } else {
            push @config_issues, "Application directory not accessible: $app_root";
        }
        
        if (@config_issues == 0) {
            $check->{status} = 'pass';
            $check->{message} = 'Application configuration looks good';
        } elsif (@config_found > @config_issues) {
            $check->{status} = 'warning';
            $check->{message} = 'Configuration has minor issues';
            $check->{recommendation} = 'Fix configuration issues for optimal Starman operation';
        } else {
            $check->{status} = 'fail';
            $check->{message} = 'Significant configuration issues found';
            $check->{recommendation} = 'Fix configuration issues before starting Starman service';
        }
        
        $check->{details} = "Found:\n" . join("\n", @config_found) . 
                           (@config_issues ? "\n\nIssues:\n" . join("\n", @config_issues) : "");
        
    } catch {
        $check->{status} = 'fail';
        $check->{message} = 'Error checking configuration';
        $check->{details} = "Error: $_";
    };
    
    return $check;
}

# Check dependencies (Perl modules)
sub check_dependencies {
    my ($self) = @_;
    
    my $check = {
        name => 'Starman Dependencies',
        status => 'unknown',
        message => '',
        details => '',
        recommendation => ''
    };
    
    try {
        my @deps_status = ();
        my @missing_deps = ();
        my @installed_deps = ();
        
        # Check for Starman module
        eval { require Starman; };
        if ($@) {
            push @missing_deps, 'Starman';
            push @deps_status, "Starman: NOT INSTALLED";
        } else {
            push @installed_deps, 'Starman';
            push @deps_status, "Starman: INSTALLED (version " . ($Starman::VERSION || 'unknown') . ")";
        }
        
        # Check for Plack
        eval { require Plack; };
        if ($@) {
            push @missing_deps, 'Plack';
            push @deps_status, "Plack: NOT INSTALLED";
        } else {
            push @installed_deps, 'Plack';
            push @deps_status, "Plack: INSTALLED (version " . ($Plack::VERSION || 'unknown') . ")";
        }
        
        # Check for Catalyst::Engine::PSGI
        eval { require Catalyst::Engine::PSGI; };
        if ($@) {
            push @missing_deps, 'Catalyst::Engine::PSGI';
            push @deps_status, "Catalyst::Engine::PSGI: NOT INSTALLED";
        } else {
            push @installed_deps, 'Catalyst::Engine::PSGI';
            push @deps_status, "Catalyst::Engine::PSGI: INSTALLED";
        }
        
        # Check for HTTP::Server::PSGI (Starman dependency)
        eval { require HTTP::Server::PSGI; };
        if ($@) {
            push @missing_deps, 'HTTP::Server::PSGI';
            push @deps_status, "HTTP::Server::PSGI: NOT INSTALLED";
        } else {
            push @installed_deps, 'HTTP::Server::PSGI';
            push @deps_status, "HTTP::Server::PSGI: INSTALLED";
        }
        
        if (@missing_deps == 0) {
            $check->{status} = 'pass';
            $check->{message} = 'All Starman dependencies are installed';
        } elsif (@installed_deps > 0) {
            $check->{status} = 'warning';
            $check->{message} = 'Some dependencies missing: ' . join(', ', @missing_deps);
            $check->{recommendation} = 'Install missing dependencies using: cpanm ' . join(' ', @missing_deps);
        } else {
            $check->{status} = 'fail';
            $check->{message} = 'All dependencies missing: ' . join(', ', @missing_deps);
            $check->{recommendation} = 'Install all dependencies using: cpanm ' . join(' ', @missing_deps);
        }
        
        $check->{details} = join("\n", @deps_status);
        
    } catch {
        $check->{status} = 'fail';
        $check->{message} = 'Error checking dependencies';
        $check->{details} = "Error: $_";
    };
    
    return $check;
}

# Check file permissions (read-only checks)
sub check_file_permissions {
    my ($self, $app_root) = @_;
    
    my $check = {
        name => 'File Permissions',
        status => 'unknown',
        message => '',
        details => '',
        recommendation => ''
    };
    
    try {
        my @perm_checks = ();
        my @perm_issues = ();
        
        # Check application directory ownership and permissions
        if (-d $app_root) {
            my @stat = stat($app_root);
            my $uid = $<;
            my $gid = $(;
            
            if ($stat[4] == $uid) {
                push @perm_checks, "Application directory owned by current user";
            } else {
                push @perm_issues, "Application directory not owned by current user (may cause issues)";
            }
            
            if (-r $app_root && -x $app_root) {
                push @perm_checks, "Application directory is readable and executable";
            } else {
                push @perm_issues, "Application directory lacks proper permissions";
            }
        }
        
        # Check script permissions
        my $app_script = File::Spec->catfile($app_root, 'script', 'comserv_server.pl');
        if (-f $app_script) {
            if (-x $app_script) {
                push @perm_checks, "Application script is executable";
            } else {
                push @perm_issues, "Application script is not executable";
            }
        }
        
        # Check lib directory permissions
        my $lib_dir = File::Spec->catdir($app_root, 'lib');
        if (-d $lib_dir) {
            if (-r $lib_dir && -x $lib_dir) {
                push @perm_checks, "Library directory is accessible";
            } else {
                push @perm_issues, "Library directory is not accessible";
            }
        }
        
        if (@perm_issues == 0) {
            $check->{status} = 'pass';
            $check->{message} = 'File permissions look good';
        } else {
            $check->{status} = 'warning';
            $check->{message} = 'Some permission issues detected';
            $check->{recommendation} = 'Fix file permissions using chmod/chown commands (requires appropriate privileges)';
        }
        
        $check->{details} = join("\n", @perm_checks) . 
                           (@perm_issues ? "\n\nIssues:\n" . join("\n", @perm_issues) : "");
        
    } catch {
        $check->{status} = 'fail';
        $check->{message} = 'Error checking permissions';
        $check->{details} = "Error: $_";
    };
    
    return $check;
}

# Check system resources (read-only)
sub check_system_resources {
    my ($self) = @_;
    
    my $check = {
        name => 'System Resources',
        status => 'unknown',
        message => '',
        details => '',
        recommendation => ''
    };
    
    try {
        my @resource_info = ();
        my @resource_warnings = ();
        
        # Check memory (no sudo required)
        my $free_output = `free -m 2>/dev/null`;
        if ($free_output =~ /Mem:\s+(\d+)\s+(\d+)\s+(\d+)/) {
            my ($total, $used, $free) = ($1, $2, $3);
            my $usage_percent = int(($used / $total) * 100);
            
            push @resource_info, "Memory: ${used}MB used / ${total}MB total (${usage_percent}%)";
            
            if ($usage_percent > 90) {
                push @resource_warnings, "High memory usage: ${usage_percent}%";
            } elsif ($usage_percent > 80) {
                push @resource_warnings, "Moderate memory usage: ${usage_percent}%";
            }
        }
        
        # Check disk space (no sudo required)
        my $df_output = `df -h . 2>/dev/null | tail -1`;
        if ($df_output =~ /(\d+)%/) {
            my $disk_usage = $1;
            push @resource_info, "Disk usage: ${disk_usage}%";
            
            if ($disk_usage > 90) {
                push @resource_warnings, "Critical disk usage: ${disk_usage}%";
            } elsif ($disk_usage > 80) {
                push @resource_warnings, "High disk usage: ${disk_usage}%";
            }
        }
        
        # Check load average (no sudo required)
        my $uptime_output = `uptime 2>/dev/null`;
        if ($uptime_output =~ /load average:\s*([\d\.]+),\s*([\d\.]+),\s*([\d\.]+)/) {
            my ($load1, $load5, $load15) = ($1, $2, $3);
            push @resource_info, "Load average: $load1, $load5, $load15";
            
            # Get CPU count for comparison
            my $cpu_count = `nproc 2>/dev/null` || 1;
            chomp $cpu_count;
            
            if ($load1 > $cpu_count * 2) {
                push @resource_warnings, "Very high load average: $load1 (CPUs: $cpu_count)";
            } elsif ($load1 > $cpu_count) {
                push @resource_warnings, "High load average: $load1 (CPUs: $cpu_count)";
            }
        }
        
        if (@resource_warnings == 0) {
            $check->{status} = 'pass';
            $check->{message} = 'System resources look healthy';
        } else {
            $check->{status} = 'warning';
            $check->{message} = 'Resource concerns detected';
            $check->{recommendation} = 'Monitor system resources and consider optimization or hardware upgrades';
        }
        
        $check->{details} = join("\n", @resource_info) . 
                           (@resource_warnings ? "\n\nWarnings:\n" . join("\n", @resource_warnings) : "");
        
    } catch {
        $check->{status} = 'fail';
        $check->{message} = 'Error checking system resources';
        $check->{details} = "Error: $_";
    };
    
    return $check;
}

# Check application status (process checks)
sub check_application_status {
    my ($self, $app_root) = @_;
    
    my $check = {
        name => 'Application Status',
        status => 'unknown',
        message => '',
        details => '',
        recommendation => ''
    };
    
    try {
        my @app_info = ();
        my @status_notes = ();
        
        # Check if development server is running
        my $dev_server = `ps aux | grep 'comserv_server.pl' | grep -v grep`;
        chomp $dev_server;
        if ($dev_server) {
            push @app_info, "Development server is running:";
            push @app_info, $dev_server;
            push @status_notes, "Development server active - may conflict with Starman on same port";
        } else {
            push @app_info, "Development server is not running";
        }
        
        # Check if any Starman processes are running
        my $starman_processes = `ps aux | grep starman | grep -v grep`;
        chomp $starman_processes;
        if ($starman_processes) {
            push @app_info, "Starman processes found:";
            push @app_info, $starman_processes;
        } else {
            push @app_info, "No Starman processes running";
        }
        
        # Check if any PSGI processes are running
        my $psgi_processes = `ps aux | grep '\.psgi' | grep -v grep`;
        chomp $psgi_processes;
        if ($psgi_processes) {
            push @app_info, "PSGI processes found:";
            push @app_info, $psgi_processes;
        }
        
        # Check application directory
        if (-d $app_root) {
            push @app_info, "Application directory: $app_root (exists)";
        } else {
            push @app_info, "Application directory: $app_root (NOT FOUND)";
            push @status_notes, "Application directory missing - critical issue";
        }
        
        if (@status_notes > 0) {
            $check->{status} = 'warning';
            $check->{message} = 'Application status has concerns';
            $check->{recommendation} = join('; ', @status_notes);
        } else {
            $check->{status} = 'pass';
            $check->{message} = 'Application status looks normal';
        }
        
        $check->{details} = join("\n", @app_info);
        
    } catch {
        $check->{status} = 'fail';
        $check->{message} = 'Error checking application status';
        $check->{details} = "Error: $_";
    };
    
    return $check;
}

# Check PSGI file
sub check_psgi_file {
    my ($self, $app_root) = @_;
    
    my $check = {
        name => 'PSGI File Validation',
        status => 'unknown',
        message => '',
        details => '',
        recommendation => ''
    };
    
    try {
        my $psgi_file = File::Spec->catfile($app_root, 'comserv.psgi');
        
        if (-f $psgi_file) {
            # Try to read and validate the PSGI file
            open(my $fh, '<', $psgi_file) or die "Cannot read PSGI file: $!";
            my $content = do { local $/; <$fh> };
            close($fh);
            
            my @validation_results = ();
            
            # Basic validation checks
            if ($content =~ /use\s+Comserv/) {
                push @validation_results, "✓ Uses Comserv module";
            } else {
                push @validation_results, "⚠ Does not use Comserv module";
            }
            
            if ($content =~ /->psgi_app/) {
                push @validation_results, "✓ Calls psgi_app method";
            } else {
                push @validation_results, "⚠ Does not call psgi_app method";
            }
            
            if ($content =~ /\$app\s*;?\s*$/) {
                push @validation_results, "✓ Returns app variable";
            } else {
                push @validation_results, "⚠ May not return app properly";
            }
            
            my $warnings = grep { /⚠/ } @validation_results;
            
            if ($warnings == 0) {
                $check->{status} = 'pass';
                $check->{message} = 'PSGI file looks valid';
            } else {
                $check->{status} = 'warning';
                $check->{message} = 'PSGI file has potential issues';
                $check->{recommendation} = 'Review PSGI file structure and consider regenerating it';
            }
            
            $check->{details} = "PSGI file: $psgi_file\nValidation results:\n" . join("\n", @validation_results);
            
        } else {
            $check->{status} = 'fail';
            $check->{message} = 'PSGI file does not exist';
            $check->{details} = "Expected location: $psgi_file";
            $check->{recommendation} = 'Create a PSGI file for Starman deployment';
        }
        
    } catch {
        $check->{status} = 'fail';
        $check->{message} = 'Error validating PSGI file';
        $check->{details} = "Error: $_";
    };
    
    return $check;
}

# Generate PSGI file content
sub generate_psgi_content {
    my ($self, $app_name) = @_;
    
    $app_name ||= 'Comserv';
    
    return qq{#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "\$FindBin::Bin/lib";

use $app_name;

my \$app = $app_name->apply_default_middlewares($app_name->psgi_app);
\$app;
};
}

# Generate systemd service content
sub generate_service_content {
    my ($self, $app_root, $options) = @_;
    
    $options ||= {};
    
    my $user = $options->{user} || getpwuid($<);
    my $group = $options->{group} || getgrgid($();
    my $port = $options->{port} || 5000;
    my $workers = $options->{workers} || 5;
    my $starman_path = $options->{starman_path} || '/usr/local/bin/starman';
    
    # Try to find starman in common locations
    unless (-x $starman_path) {
        my @possible_paths = (
            '/usr/local/bin/starman',
            '/usr/bin/starman',
            `which starman 2>/dev/null`
        );
        
        foreach my $path (@possible_paths) {
            chomp $path;
            if ($path && -x $path) {
                $starman_path = $path;
                last;
            }
        }
    }
    
    return qq{[Unit]
Description=Starman HTTP Server for Comserv
After=network.target

[Service]
Type=simple
User=$user
Group=$group
WorkingDirectory=$app_root
Environment=PERL5LIB=$app_root/lib
ExecStart=$starman_path --listen :$port --workers $workers $app_root/comserv.psgi
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=mixed
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
};
}

# Private logging method
sub _log_error {
    my ($self, $message) = @_;
    
    if ($self->logger) {
        $self->logger->log_error($message);
    } else {
        warn "StarmanDiagnostics: $message\n";
    }
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
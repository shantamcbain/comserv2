package Comserv::Util::StarmanServiceManager;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use POSIX qw(strftime);
use File::Spec;
use File::Path qw(make_path);
use Cwd;

=head1 NAME

Comserv::Util::StarmanServiceManager - Web-safe Starman service management

=head1 DESCRIPTION

This module provides service management capabilities that work safely from
a web interface without requiring interactive sudo commands. It focuses on
operations that can be performed by the web user or provides clear instructions
for system administrators.

=cut

has 'logger' => (
    is => 'rw',
    isa => 'Object',
    required => 0,
);

has 'diagnostics' => (
    is => 'ro',
    isa => 'Comserv::Util::StarmanDiagnostics',
    lazy => 1,
    default => sub {
        require Comserv::Util::StarmanDiagnostics;
        return Comserv::Util::StarmanDiagnostics->new();
    }
);

# Get comprehensive service status (web-safe)
sub get_service_status {
    my ($self, $app_root) = @_;
    
    my $status = {
        timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),
        service_state => 'unknown',
        process_info => {},
        recommendations => [],
        available_actions => []
    };
    
    try {
        # Check if service file exists
        my $service_file = '/etc/systemd/system/starman.service';
        $status->{service_file_exists} = -f $service_file;
        
        # Get process information (no sudo required)
        my $process_info = $self->_get_process_info();
        $status->{process_info} = $process_info;
        
        # Determine service state based on available information
        if ($process_info->{starman_running}) {
            $status->{service_state} = 'running';
            push @{$status->{recommendations}}, {
                type => 'success',
                message => 'Starman processes are running',
                action => 'Service appears to be operational'
            };
        } elsif ($process_info->{dev_server_running}) {
            $status->{service_state} = 'dev_mode';
            push @{$status->{recommendations}}, {
                type => 'info',
                message => 'Development server is running instead of Starman',
                action => 'Stop development server before starting Starman service'
            };
        } else {
            $status->{service_state} = 'stopped';
            push @{$status->{recommendations}}, {
                type => 'warning',
                message => 'No Starman processes detected',
                action => 'Service may be stopped or not configured'
            };
        }
        
        # Add available actions based on current state
        $self->_add_available_actions($status);
        
    } catch {
        my $error = $_;
        $self->_log_error("Error getting service status: $error");
        
        push @{$status->{recommendations}}, {
            type => 'danger',
            message => "Error checking service status: $error",
            action => 'Check system logs for details'
        };
    };
    
    return $status;
}

# Create PSGI file
sub create_psgi_file {
    my ($self, $app_root, $options) = @_;
    
    my $result = {
        success => 0,
        message => '',
        details => '',
        file_path => ''
    };
    
    try {
        my $psgi_file = File::Spec->catfile($app_root, 'comserv.psgi');
        $result->{file_path} = $psgi_file;
        
        # Check if file already exists
        if (-f $psgi_file) {
            $result->{success} = 1;
            $result->{message} = 'PSGI file already exists';
            $result->{details} = "File found at: $psgi_file";
            return $result;
        }
        
        # Generate PSGI content
        my $content = $self->diagnostics->generate_psgi_content($options->{app_name});
        
        # Write PSGI file
        open(my $fh, '>', $psgi_file) or die "Cannot create PSGI file: $!";
        print $fh $content;
        close($fh);
        
        # Make it executable
        chmod 0755, $psgi_file;
        
        $result->{success} = 1;
        $result->{message} = 'PSGI file created successfully';
        $result->{details} = "Created: $psgi_file\nContent:\n$content";
        
    } catch {
        my $error = $_;
        $self->_log_error("Error creating PSGI file: $error");
        
        $result->{message} = "Failed to create PSGI file: $error";
        $result->{details} = $error;
    };
    
    return $result;
}

# Generate service file content and provide installation instructions
sub prepare_service_file {
    my ($self, $app_root, $options) = @_;
    
    my $result = {
        success => 0,
        message => '',
        details => '',
        service_content => '',
        installation_commands => []
    };
    
    try {
        # Generate service content
        my $service_content = $self->diagnostics->generate_service_content($app_root, $options);
        $result->{service_content} = $service_content;
        
        # Prepare installation commands
        my $service_file = '/etc/systemd/system/starman.service';
        
        push @{$result->{installation_commands}}, {
            description => 'Create service file (requires root privileges)',
            command => "sudo tee $service_file > /dev/null << 'EOF'\n$service_content\nEOF"
        };
        
        push @{$result->{installation_commands}}, {
            description => 'Reload systemd daemon',
            command => 'sudo systemctl daemon-reload'
        };
        
        push @{$result->{installation_commands}}, {
            description => 'Enable service to start on boot',
            command => 'sudo systemctl enable starman'
        };
        
        push @{$result->{installation_commands}}, {
            description => 'Start the service',
            command => 'sudo systemctl start starman'
        };
        
        $result->{success} = 1;
        $result->{message} = 'Service file prepared successfully';
        $result->{details} = 'Service file content generated. Use the provided commands to install it.';
        
    } catch {
        my $error = $_;
        $self->_log_error("Error preparing service file: $error");
        
        $result->{message} = "Failed to prepare service file: $error";
        $result->{details} = $error;
    };
    
    return $result;
}

# Install dependencies (web-safe approach)
sub install_dependencies {
    my ($self, $options) = @_;
    
    my $result = {
        success => 0,
        message => '',
        details => '',
        installation_commands => [],
        manual_steps => []
    };
    
    try {
        # Check current dependency status
        my $deps_check = $self->diagnostics->check_dependencies();
        
        if ($deps_check->{status} eq 'pass') {
            $result->{success} = 1;
            $result->{message} = 'All dependencies are already installed';
            $result->{details} = $deps_check->{details};
            return $result;
        }
        
        # Extract missing dependencies from the check
        my @missing_deps = ();
        if ($deps_check->{details} =~ /NOT INSTALLED/m) {
            my @lines = split(/\n/, $deps_check->{details});
            foreach my $line (@lines) {
                if ($line =~ /^(\w+(?:::\w+)*): NOT INSTALLED/) {
                    push @missing_deps, $1;
                }
            }
        }
        
        if (@missing_deps > 0) {
            # Provide installation commands
            push @{$result->{installation_commands}}, {
                description => 'Install missing Perl modules using cpanm',
                command => 'cpanm ' . join(' ', @missing_deps)
            };
            
            push @{$result->{installation_commands}}, {
                description => 'Alternative: Install using system package manager (Ubuntu/Debian)',
                command => 'sudo apt-get install ' . join(' ', map { "lib" . lc($_) . "-perl" } @missing_deps)
            };
            
            # Try to install automatically if cpanm is available and we have write permissions
            my $cpanm_available = `which cpanm 2>/dev/null`;
            chomp $cpanm_available;
            
            if ($cpanm_available && -x $cpanm_available) {
                my $install_output = '';
                my $install_success = 1;
                
                foreach my $dep (@missing_deps) {
                    my $output = `cpanm --notest $dep 2>&1`;
                    my $exit_code = $? >> 8;
                    
                    $install_output .= "Installing $dep:\n$output\n\n";
                    
                    if ($exit_code != 0) {
                        $install_success = 0;
                    }
                }
                
                if ($install_success) {
                    $result->{success} = 1;
                    $result->{message} = 'Dependencies installed successfully';
                } else {
                    $result->{message} = 'Some dependencies failed to install automatically';
                    push @{$result->{manual_steps}}, 'Check the installation output and install failed dependencies manually';
                }
                
                $result->{details} = $install_output;
            } else {
                $result->{message} = 'Dependencies need to be installed manually';
                push @{$result->{manual_steps}}, 'Install cpanm first: curl -L https://cpanmin.us | perl - App::cpanminus';
                push @{$result->{manual_steps}}, 'Then run the provided installation commands';
            }
        }
        
    } catch {
        my $error = $_;
        $self->_log_error("Error installing dependencies: $error");
        
        $result->{message} = "Failed to install dependencies: $error";
        $result->{details} = $error;
    };
    
    return $result;
}

# Fix file permissions (web-safe approach)
sub fix_permissions {
    my ($self, $app_root) = @_;
    
    my $result = {
        success => 0,
        message => '',
        details => '',
        fixed_items => [],
        manual_steps => []
    };
    
    try {
        my @fixed = ();
        my @manual = ();
        
        # Try to fix permissions we can fix
        my $app_script = File::Spec->catfile($app_root, 'script', 'comserv_server.pl');
        if (-f $app_script && !-x $app_script) {
            if (chmod 0755, $app_script) {
                push @fixed, "Made application script executable: $app_script";
            } else {
                push @manual, "Make application script executable: chmod +x $app_script";
            }
        }
        
        # Check PSGI file permissions
        my $psgi_file = File::Spec->catfile($app_root, 'comserv.psgi');
        if (-f $psgi_file && !-x $psgi_file) {
            if (chmod 0755, $psgi_file) {
                push @fixed, "Made PSGI file executable: $psgi_file";
            } else {
                push @manual, "Make PSGI file executable: chmod +x $psgi_file";
            }
        }
        
        # Check directory permissions
        my @dirs_to_check = ($app_root, File::Spec->catdir($app_root, 'lib'));
        foreach my $dir (@dirs_to_check) {
            if (-d $dir && (!-r $dir || !-x $dir)) {
                # Try to fix if we own the directory
                my @stat = stat($dir);
                if ($stat[4] == $<) {
                    if (chmod 0755, $dir) {
                        push @fixed, "Fixed directory permissions: $dir";
                    } else {
                        push @manual, "Fix directory permissions: chmod 755 $dir";
                    }
                } else {
                    push @manual, "Fix directory permissions (requires owner/root): chmod 755 $dir";
                }
            }
        }
        
        $result->{fixed_items} = \@fixed;
        $result->{manual_steps} = \@manual;
        
        if (@fixed > 0 && @manual == 0) {
            $result->{success} = 1;
            $result->{message} = 'All permission issues fixed automatically';
        } elsif (@fixed > 0) {
            $result->{success} = 1;
            $result->{message} = 'Some permissions fixed, manual steps required for others';
        } elsif (@manual > 0) {
            $result->{message} = 'Permission fixes require manual intervention';
        } else {
            $result->{success} = 1;
            $result->{message} = 'No permission issues found';
        }
        
        $result->{details} = "Fixed automatically:\n" . join("\n", @fixed) . 
                            (@manual ? "\n\nRequires manual action:\n" . join("\n", @manual) : "");
        
    } catch {
        my $error = $_;
        $self->_log_error("Error fixing permissions: $error");
        
        $result->{message} = "Failed to fix permissions: $error";
        $result->{details} = $error;
    };
    
    return $result;
}

# Execute auto-repair (web-safe)
sub execute_auto_repair {
    my ($self, $app_root, $options) = @_;
    
    my $result = {
        timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime),
        success => 0,
        message => '',
        repairs => [],
        summary => {}
    };
    
    try {
        # Run diagnostics first
        my $diagnostics = $self->diagnostics->execute_diagnostics($app_root);
        
        # Repair 1: Create PSGI file if missing
        my $psgi_check = (grep { $_->{name} eq 'PSGI File Validation' && $_->{status} eq 'fail' } @{$diagnostics->{checks}})[0];
        if ($psgi_check) {
            my $psgi_repair = $self->create_psgi_file($app_root, $options);
            push @{$result->{repairs}}, {
                name => 'Create PSGI File',
                success => $psgi_repair->{success},
                message => $psgi_repair->{message},
                details => $psgi_repair->{details}
            };
        }
        
        # Repair 2: Install dependencies
        my $deps_check = (grep { $_->{name} eq 'Starman Dependencies' && $_->{status} ne 'pass' } @{$diagnostics->{checks}})[0];
        if ($deps_check) {
            my $deps_repair = $self->install_dependencies($options);
            push @{$result->{repairs}}, {
                name => 'Install Dependencies',
                success => $deps_repair->{success},
                message => $deps_repair->{message},
                details => $deps_repair->{details},
                manual_steps => $deps_repair->{manual_steps} || []
            };
        }
        
        # Repair 3: Fix permissions
        my $perms_check = (grep { $_->{name} eq 'File Permissions' && $_->{status} eq 'warning' } @{$diagnostics->{checks}})[0];
        if ($perms_check) {
            my $perms_repair = $self->fix_permissions($app_root);
            push @{$result->{repairs}}, {
                name => 'Fix Permissions',
                success => $perms_repair->{success},
                message => $perms_repair->{message},
                details => $perms_repair->{details},
                manual_steps => $perms_repair->{manual_steps} || []
            };
        }
        
        # Generate summary
        my $successful_repairs = grep { $_->{success} } @{$result->{repairs}};
        my $total_repairs = scalar(@{$result->{repairs}});
        
        $result->{summary} = {
            total_repairs => $total_repairs,
            successful => $successful_repairs,
            failed => $total_repairs - $successful_repairs
        };
        
        if ($total_repairs == 0) {
            $result->{success} = 1;
            $result->{message} = 'No repairs needed - system looks good';
        } elsif ($successful_repairs == $total_repairs) {
            $result->{success} = 1;
            $result->{message} = 'All repairs completed successfully';
        } elsif ($successful_repairs > 0) {
            $result->{success} = 1;
            $result->{message} = 'Some repairs completed, manual steps may be required';
        } else {
            $result->{message} = 'Auto-repair could not fix issues automatically';
        }
        
    } catch {
        my $error = $_;
        $self->_log_error("Auto-repair failed: $error");
        
        $result->{message} = "Auto-repair encountered an error: $error";
        push @{$result->{repairs}}, {
            name => 'Auto-Repair Error',
            success => 0,
            message => $error,
            details => ''
        };
    };
    
    return $result;
}

# Get process information (no sudo required)
sub _get_process_info {
    my ($self) = @_;
    
    my $info = {
        starman_running => 0,
        dev_server_running => 0,
        processes => []
    };
    
    try {
        # Check for Starman processes
        my $starman_ps = `ps aux | grep starman | grep -v grep`;
        chomp $starman_ps;
        if ($starman_ps) {
            $info->{starman_running} = 1;
            push @{$info->{processes}}, {
                type => 'starman',
                details => $starman_ps
            };
        }
        
        # Check for development server
        my $dev_ps = `ps aux | grep 'comserv_server.pl' | grep -v grep`;
        chomp $dev_ps;
        if ($dev_ps) {
            $info->{dev_server_running} = 1;
            push @{$info->{processes}}, {
                type => 'development',
                details => $dev_ps
            };
        }
        
        # Check for any PSGI processes
        my $psgi_ps = `ps aux | grep '\.psgi' | grep -v grep`;
        chomp $psgi_ps;
        if ($psgi_ps) {
            push @{$info->{processes}}, {
                type => 'psgi',
                details => $psgi_ps
            };
        }
        
    } catch {
        $self->_log_error("Error getting process info: $_");
    };
    
    return $info;
}

# Add available actions based on current state
sub _add_available_actions {
    my ($self, $status) = @_;
    
    # Always available actions
    push @{$status->{available_actions}}, {
        name => 'Run Diagnostics',
        action => 'diagnose',
        class => 'btn-info',
        description => 'Perform comprehensive system diagnostics'
    };
    
    push @{$status->{available_actions}}, {
        name => 'Auto Repair',
        action => 'auto_repair',
        class => 'btn-primary',
        description => 'Attempt to fix common issues automatically'
    };
    
    # State-specific actions
    if (!$status->{service_file_exists}) {
        push @{$status->{available_actions}}, {
            name => 'Prepare Service File',
            action => 'prepare_service',
            class => 'btn-success',
            description => 'Generate systemd service file and installation instructions'
        };
    }
    
    if ($status->{process_info}->{dev_server_running}) {
        push @{$status->{available_actions}}, {
            name => 'Stop Dev Server',
            action => 'stop_dev_server',
            class => 'btn-warning',
            description => 'Stop development server to free up resources'
        };
    }
}

# Private logging method
sub _log_error {
    my ($self, $message) = @_;
    
    if ($self->logger) {
        $self->logger->log_error($message);
    } else {
        warn "StarmanServiceManager: $message\n";
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
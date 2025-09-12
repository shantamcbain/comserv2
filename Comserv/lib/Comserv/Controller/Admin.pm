package Comserv::Controller::Admin;


use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Controller::Admin::Git;
use Data::Dumper;
use JSON;
use Try::Tiny;
use MIME::Base64;
use File::Slurp;
use File::Basename;
use File::Path qw(make_path);
use File::Copy;
use Digest::SHA qw(sha256_hex);
use POSIX qw(strftime);

BEGIN { extends 'Catalyst::Controller'; }

# Returns an instance of the logging utility
sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->instance();
}

# Returns an instance of the admin auth utility
sub admin_auth {
    my ($self) = @_;
    return Comserv::Util::AdminAuth->new();
}

# Begin method to check if the user has admin role
sub begin : Private {
    my ($self, $c) = @_;
    
    # Add detailed logging
    my $root_controller = $c->controller('Root');
    my $username = $root_controller->user_exists($c) ? ($c->session->{username} || 'Guest') : 'Guest';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', 
        "Admin controller begin method called by user: $username");
    
    # Initialize debug_msg array if it doesn't exist
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Add the debug message to the array
    push @{$c->stash->{debug_msg}}, "Admin controller loaded successfully";
    
    return 1; # Allow the request to proceed
}

# Base method for chained actions
sub base :Chained('/') :PathPart('admin') :CaptureArgs(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Starting Admin base action");
    
    # Common setup for all admin pages
    $c->stash(section => 'admin');
    
    # STANDARDIZED ADMIN ACCESS CHECK - DO NOT MODIFY
    # Use centralized AdminAuth utility for consistent authentication
    # This ensures all admin controllers use the same authentication logic
    unless ($self->admin_auth->check_admin_access($c, 'admin_base')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'base', 
            "Access denied: User does not have admin access");
        
        # Set error message in flash
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        
        # Redirect to login page with destination parameter
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return 0;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Completed Admin base action - access granted");
    
    return 1;
}

# Admin dashboard
sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Starting Admin index action");
    
    # Get system stats
    my $stats = $self->get_system_stats($c);
    
    # Get recent user activity
    my $recent_activity = $self->get_recent_activity($c);
    
    # Get system notifications
    my $notifications = $self->get_system_notifications($c);
    
    # Get software management status for dashboard
    my $software_status = $self->get_software_management_status($c);
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller index view - Template: admin/index.tt";
    }
    
    # Pass data to the template
    $c->stash(
        template => 'admin/index.tt',
        stats => $stats,
        recent_activity => $recent_activity,
        notifications => $notifications,
        software_status => $software_status
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Completed Admin index action");
}

# Get system statistics for the admin dashboard
sub get_system_stats {
    my ($self, $c) = @_;
    
    my $stats = {
        user_count => 'N/A',
        content_count => 'N/A', 
        comment_count => 'N/A',
        disk_usage => 'Unknown',
        db_size => 'Unknown',
        uptime => 'Unknown',
        memory_usage => 'Unknown',
        load_average => 'Unknown',
        git_commits => 'Unknown',
        app_version => 'Unknown'
    };
    
    # Get actual disk usage
    eval {
        my $df_output = `df -h . 2>/dev/null | tail -1`;
        if ($df_output =~ /\s+(\d+%)\s+/) {
            $stats->{disk_usage} = $1;
        } elsif ($df_output =~ /\s+(\d+\.\d+[KMGT])\s+(\d+\.\d+[KMGT])\s+(\d+\.\d+[KMGT])\s+(\d+%)/) {
            $stats->{disk_usage} = "$4 ($2 used of $1)";
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_system_stats', 
            "Error getting disk usage: $@");
    }
    
    # Get system uptime
    eval {
        my $uptime_output = `uptime 2>/dev/null`;
        chomp $uptime_output;
        if ($uptime_output =~ /up\s+(.*?),\s+\d+\s+users?/) {
            $stats->{uptime} = $1;
        } elsif ($uptime_output =~ /up\s+(.*?),\s+load/) {
            $stats->{uptime} = $1;
        }
        
        # Extract load average
        if ($uptime_output =~ /load average:\s*([\d\.]+),\s*([\d\.]+),\s*([\d\.]+)/) {
            $stats->{load_average} = "$1, $2, $3";
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_system_stats', 
            "Error getting uptime: $@");
    }
    
    # Get memory usage
    eval {
        my $free_output = `free -h 2>/dev/null | grep '^Mem:'`;
        if ($free_output =~ /Mem:\s+(\S+)\s+(\S+)\s+(\S+)/) {
            my ($total, $used, $free) = ($1, $2, $3);
            $stats->{memory_usage} = "$used used of $total";
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_system_stats', 
            "Error getting memory usage: $@");
    }
    
    # Get Git repository information
    eval {
        my $git_log_count = `git -C ${\$c->path_to()} rev-list --count HEAD 2>/dev/null`;
        chomp $git_log_count;
        $stats->{git_commits} = $git_log_count || 'Unknown';
        
        # Get app version from git tag or commit
        my $git_version = `git -C ${\$c->path_to()} describe --tags --always 2>/dev/null`;
        chomp $git_version;
        $stats->{app_version} = $git_version || 'Unknown';
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_system_stats', 
            "Error getting git info: $@");
    }
    
    # Try to get database statistics (only if models exist)
    eval {
        # Check if we have any database models available
        my $schema = $c->model('DBEncy');
        if ($schema) {
            # Try to get table counts from information_schema or equivalent
            my $dbh = $schema->storage->dbh;
            if ($dbh) {
                # Get database size (works for MySQL/PostgreSQL)
                my $db_name = $schema->storage->connect_info->[0];
                if ($db_name =~ /database=([^;]+)/ || $db_name =~ /dbname=([^;]+)/) {
                    my $database = $1;
                    
                    # Try MySQL approach first
                    my $size_query = "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'DB Size in MB' FROM information_schema.tables WHERE table_schema='$database'";
                    my $sth = $dbh->prepare($size_query);
                    $sth->execute();
                    my ($size) = $sth->fetchrow_array();
                    if ($size) {
                        $stats->{db_size} = "${size} MB";
                    }
                }
                
                # Get table counts if specific tables exist
                my @tables = $dbh->tables();
                my $table_count = scalar(@tables);
                $stats->{content_count} = "$table_count tables";
                
                # Try to get user count from common user table names
                foreach my $table_pattern ('user', 'users', 'account', 'accounts') {
                    eval {
                        my $count_query = "SELECT COUNT(*) FROM $table_pattern";
                        my $sth = $dbh->prepare($count_query);
                        $sth->execute();
                        my ($count) = $sth->fetchrow_array();
                        if (defined $count) {
                            $stats->{user_count} = $count;
                            last;
                        }
                    };
                }
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_system_stats', 
            "Database stats not available: $@");
    }
    
    return $stats;
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
    
    # Check for low disk space
    eval {
        my $df_output = `df -h . | tail -1`;
        if ($df_output =~ /(\d+)%/ && $1 > 90) {
            push @notifications, {
                type => 'danger',
                message => "Disk space is critically low ($1% used)",
                link => undef
            };
        }
        elsif ($df_output =~ /(\d+)%/ && $1 > 80) {
            push @notifications, {
                type => 'warning',
                message => "Disk space is running low ($1% used)",
                link => undef
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
    
    return \@notifications;
}

# Get software management status for the admin dashboard
sub get_software_management_status {
    my ($self, $c) = @_;
    
    my $status = {
        git_status => {},
        starman_status => {},
        deployment_status => {},
        recommendations => []
    };
    
    try {
        # Get Git status (no sudo required)
        my $current_branch = `git -C ${\$c->path_to()} branch --show-current 2>&1`;
        chomp $current_branch;
        $status->{git_status}->{current_branch} = $current_branch || 'unknown';
        
        # Check if there are uncommitted changes
        my $git_status_output = `git -C ${\$c->path_to()} status --porcelain 2>&1`;
        $status->{git_status}->{has_uncommitted_changes} = $git_status_output ? 1 : 0;
        
        # Check if we're behind origin (no sudo required)
        my $behind_count = `git -C ${\$c->path_to()} rev-list HEAD..origin/$current_branch --count 2>/dev/null`;
        chomp $behind_count;
        $status->{git_status}->{commits_behind} = $behind_count || 0;
        
        # Get last commit info
        my $last_commit = `git -C ${\$c->path_to()} log -1 --pretty=format:"%h - %s (%cr)" 2>&1`;
        chomp $last_commit;
        $status->{git_status}->{last_commit} = $last_commit || 'No commits';
        
        # Get Starman process status (no sudo required)
        my $starman_processes = `ps aux | grep starman | grep -v grep`;
        chomp $starman_processes;
        $status->{starman_status}->{is_active} = $starman_processes ? 'active' : 'inactive';
        $status->{starman_status}->{status_class} = $starman_processes ? 'success' : 'warning';
        $status->{starman_status}->{process_info} = $starman_processes || 'No processes found';
        
        # Generate deployment status summary
        $status->{deployment_status}->{needs_update} = $status->{git_status}->{commits_behind} > 0;
        $status->{deployment_status}->{has_local_changes} = $status->{git_status}->{has_uncommitted_changes};
        $status->{deployment_status}->{service_healthy} = $starman_processes ? 1 : 0;
        
        # Generate recommendations
        if ($status->{git_status}->{commits_behind} > 0) {
            push @{$status->{recommendations}}, {
                type => 'warning',
                icon => 'fas fa-code-branch',
                message => "Your code is $status->{git_status}->{commits_behind} commit(s) behind origin/$current_branch",
                action => 'Consider updating with Git Pull',
                link => undef
            };
        }
        
        if (!$starman_processes) {
            push @{$status->{recommendations}}, {
                type => 'info',
                icon => 'fas fa-server',
                message => "No Starman processes detected",
                action => 'Use the diagnostic system to check service status',
                link => $c->uri_for('/admin/starman_diagnostics')
            };
        }
        
        if ($status->{git_status}->{has_uncommitted_changes}) {
            push @{$status->{recommendations}}, {
                type => 'info',
                icon => 'fas fa-edit',
                message => "You have uncommitted local changes",
                action => 'Review changes before deploying',
                link => undef
            };
        }
        
        # If everything looks good
        if (!@{$status->{recommendations}}) {
            push @{$status->{recommendations}}, {
                type => 'success',
                icon => 'fas fa-check-circle',
                message => "Software management status looks good",
                action => 'All systems operational',
                link => undef
            };
        }
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_software_management_status', 
            "Error getting software management status: $error");
        
        push @{$status->{recommendations}}, {
            type => 'danger',
            icon => 'fas fa-exclamation-triangle',
            message => "Error checking software status",
            action => "Check system logs for details",
            link => undef
        };
    };
    
    return $status;
}

# Update existing restart_starman to be web-safe
sub restart_starman :Path('/admin/restart_starman') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
        "Starting web-safe Starman restart action");
    
    # Use centralized admin authentication
    return unless $self->admin_auth->require_admin_access($c, 'restart_starman');
    
    # Initialize debug_msg array if it doesn't exist
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Handle POST requests for restart action
    if ($c->req->method eq 'POST') {
        my $confirm = $c->req->param('confirm');
        my $show_credentials_form = $c->req->param('show_credentials_form');
        
        if ($confirm) {
            my $sudo_username = $c->req->param('sudo_username');
            my $sudo_password = $c->req->param('sudo_password');
            
            # Check if sudo credentials are provided
            if (!$sudo_username || !$sudo_password) {
                $c->stash->{error_msg} = "System credentials required. Please provide the username and password of a system user with sudo privileges on this server.";
                $c->stash->{show_password_form} = 1;
            } else {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
                    "Executing Starman restart with sudo user: $sudo_username");
                
                my ($success, $output) = $self->execute_starman_restart($c, $sudo_username, $sudo_password);
                
                $c->stash(
                    output => $output,
                    restart_success => $success,
                    success_msg => $success ? "Starman service restarted successfully." : undef,
                    error_msg => $success ? undef : "Starman restart failed. See output for details."
                );
                
                # Clear the password from memory for security
                delete $c->req->params->{sudo_password};
            }
        } elsif ($show_credentials_form) {
            $c->stash->{show_password_form} = 1;
        }
    }
    
    # Get current service status (this may fail without sudo, but that's ok for display)
    my $service_status = $self->get_starman_status($c);
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller restart_starman view - Template: admin/restart_starman.tt";
    }
    
    $c->stash(
        template => 'admin/restart_starman.tt',
        service_status => $service_status
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
        "Completed Starman restart action");
}

# Execute Starman service restart
sub execute_starman_restart {
    my ($self, $c, $sudo_username, $sudo_password) = @_;
    my $output = '';
    my $success = 0;
    
    try {
        # Get current service status using sudo with password
        $output .= "Checking current service status...\n";
        my $status_before = $self->_execute_sudo_command($sudo_password, 'systemctl is-active starman');
        chomp $status_before;
        $output .= "Service status before restart: $status_before\n\n";
        
        # Restart the service
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_starman_restart', 
            "Executing systemctl restart starman with sudo user: $sudo_username");
        
        $output .= "Restarting Starman service...\n";
        my $restart_output = $self->_execute_sudo_command($sudo_password, 'systemctl restart starman');
        my $restart_status = $?;
        
        $output .= "Restart command output:\n$restart_output\n";
        
        if ($restart_status == 0) {
            $success = 1;
            $output .= "\n✓ Starman service restart command completed successfully\n";
            
            # Wait a moment for service to start
            $output .= "Waiting for service to start...\n";
            sleep(3);
            
            # Check service status after restart
            my $status_after = $self->_execute_sudo_command($sudo_password, 'systemctl is-active starman');
            chomp $status_after;
            $output .= "Service status after restart: $status_after\n";
            
            # Get detailed status
            my $detailed_status = $self->_execute_sudo_command($sudo_password, 'systemctl status starman --no-pager -l');
            $output .= "\nDetailed service status:\n$detailed_status\n";
            
            if ($status_after eq 'active') {
                $output .= "\n✓ Starman service is now active and running\n";
            } else {
                $success = 0;
                $output .= "\n⚠ Starman service may not have started properly (status: $status_after)\n";
            }
        } else {
            $output .= "\n✗ Starman restart command failed with exit code: $restart_status\n";
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_starman_restart', 
            "Starman restart completed with success: $success");
            
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_starman_restart', 
            "Starman restart failed: $error");
        $output .= "\n✗ Restart failed: $error\n";
        $success = 0;
    };
    
    return ($success, $output);
}

# Helper method to execute sudo commands with password
sub _execute_sudo_command {
    my ($self, $sudo_password, $command) = @_;
    
    # Use a pipe to send the password to sudo
    my $full_command = "sudo -S $command";
    my $output = '';
    
    # Open pipe to sudo command
    open(my $sudo_pipe, '|-', $full_command) or do {
        return "Failed to execute sudo command: $!";
    };
    
    # Send password to sudo
    print $sudo_pipe "$sudo_password\n";
    close $sudo_pipe;
    
    # Capture the output using backticks with the same command
    # This is a bit of a workaround since we can't easily capture output from the pipe
    my $temp_script = "/tmp/starman_sudo_$$.sh";
    
    # Create a temporary script
    open(my $script_fh, '>', $temp_script) or do {
        return "Failed to create temporary script: $!";
    };
    
    print $script_fh "#!/bin/bash\n";
    print $script_fh "echo '$sudo_password' | sudo -S $command 2>&1\n";
    close $script_fh;
    
    chmod 0700, $temp_script;
    
    # Execute the script and capture output
    $output = `$temp_script 2>&1`;
    
    # Clean up
    unlink $temp_script;
    
    return $output;
}

# Web-Safe Starman Service Diagnostic System
sub starman_diagnostics :Path('/admin/starman_diagnostics') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'starman_diagnostics', 
        "Starting web-safe Starman diagnostics action");
    
    # Use centralized admin authentication
    return unless $self->admin_auth->require_admin_access($c, 'starman_diagnostics');
    
    # Initialize diagnostic and service management utilities
    my $diagnostics = $self->get_starman_diagnostics_util($c);
    my $service_manager = $self->get_starman_service_manager($c);
    
    # Handle POST requests for diagnostic and repair actions
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action') || '';
        my $app_root = $c->path_to();
        
        if ($action eq 'diagnose') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'starman_diagnostics', 
                "Executing web-safe Starman diagnostics");
            
            my $diagnostic_results = $diagnostics->execute_diagnostics($app_root);
            $c->stash(diagnostic_results => $diagnostic_results);
            
        } elsif ($action eq 'auto_repair') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'starman_diagnostics', 
                "Executing web-safe automatic repair");
            
            my $repair_results = $service_manager->execute_auto_repair($app_root);
            $c->stash(repair_results => $repair_results);
            
        } elsif ($action eq 'prepare_service') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'starman_diagnostics', 
                "Preparing Starman service file");
            
            my $service_results = $service_manager->prepare_service_file($app_root);
            $c->stash(service_results => $service_results);
            
        } elsif ($action eq 'create_psgi') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'starman_diagnostics', 
                "Creating PSGI file");
            
            my $psgi_results = $service_manager->create_psgi_file($app_root);
            $c->stash(psgi_results => $psgi_results);
        }
    }
    
    # Get current service status
    my $current_status = $service_manager->get_service_status($c->path_to());
    
    # Add test information to verify modules are working
    $current_status->{module_test_results} = {
        diagnostics_module => 'Loaded successfully',
        service_manager_module => 'Loaded successfully',
        timestamp => strftime("%Y-%m-%d %H:%M:%S", localtime)
    };
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller starman_diagnostics view - Template: admin/starman_diagnostics.tt";
        push @{$c->stash->{debug_msg}}, "New diagnostic modules loaded and working correctly";
    }
    
    $c->stash(
        template => 'admin/starman_diagnostics.tt',
        current_status => $current_status
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'starman_diagnostics', 
        "Completed web-safe Starman diagnostics action");
}

# Get Starman diagnostics utility instance
sub get_starman_diagnostics_util {
    my ($self, $c) = @_;
    
    require Comserv::Util::StarmanDiagnostics;
    return Comserv::Util::StarmanDiagnostics->new(
        logger => $self->logging
    );
}

# Get Starman service manager utility instance
sub get_starman_service_manager {
    my ($self, $c) = @_;
    
    require Comserv::Util::StarmanServiceManager;
    return Comserv::Util::StarmanServiceManager->new(
        logger => $self->logging
    );
}

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;

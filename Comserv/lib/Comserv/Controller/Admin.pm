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

# Database connection status endpoint
sub db_status :Chained('base') :PathPart('db-status') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'db_status', 
        "Starting Admin db_status action");
    
    my $db_info = {};
    
    # Get DBEncy connection info
    eval {
        my $dbency = $c->model('DBEncy');
        $db_info->{dbency} = $dbency->get_connection_info();
        $db_info->{dbency_startup} = $dbency->get_startup_connection_info();
    };
    if ($@) {
        $db_info->{dbency_error} = "Error getting DBEncy info: $@";
    }
    
    # Get DBForager connection info if available
    eval {
        my $dbforager = $c->model('DBForager');
        if ($dbforager && $dbforager->can('get_connection_info')) {
            $db_info->{dbforager} = $dbforager->get_connection_info();
        } else {
            $db_info->{dbforager} = "Method not available";
        }
    };
    if ($@) {
        $db_info->{dbforager_error} = "Error getting DBForager info: $@";
    }
    
    # Set content type for JSON output
    $c->response->content_type('application/json; charset=utf-8');
    
    # Return JSON response
    $c->response->body(JSON->new->pretty->encode($db_info));
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'db_status', 
        "Completed Admin db_status action");
}

# Schema comparison redirect - redirects to dedicated SchemaComparison controller
sub compare_schema :Chained('base') :PathPart('compare_schema') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'compare_schema', 
        "Redirecting to dedicated schema comparison controller");
    
    # Redirect to the dedicated schema comparison controller
    $c->response->redirect($c->uri_for('/admin/schema-comparison'));
}

# Legacy AJAX endpoint redirects for schema comparison functionality
# These maintain backward compatibility with existing template URLs

sub get_table_schema :Chained('base') :PathPart('get_table_schema') :Args(0) {
    my ($self, $c) = @_;
    
    # Forward to the dedicated schema comparison controller
    $c->forward('/admin/schema-comparison/get-field-comparison');
}

sub get_field_comparison :Chained('base') :PathPart('get_field_comparison') :Args(0) {
    my ($self, $c) = @_;
    
    # Forward to the dedicated schema comparison controller
    $c->forward('/admin/schema-comparison/get-field-comparison');
}

sub sync_fields :Chained('base') :PathPart('sync_fields') :Args(0) {
    my ($self, $c) = @_;
    
    # Forward to the dedicated schema comparison controller
    $c->forward('/admin/schema-comparison/sync-fields');
}

sub batch_sync_table :Chained('base') :PathPart('batch_sync_table') :Args(0) {
    my ($self, $c) = @_;
    
    # Forward to the dedicated schema comparison controller
    $c->forward('/admin/schema-comparison/batch-sync-table');
}

sub create_table_from_result :Chained('base') :PathPart('create_table_from_result') :Args(0) {
    my ($self, $c) = @_;
    
    # Forward to the dedicated schema comparison controller
    $c->forward('/admin/schema-comparison/create-table-from-result');
}

sub create_result_from_table :Chained('base') :PathPart('create_result_from_table') :Args(0) {
    my ($self, $c) = @_;
    
    # Forward to the dedicated schema comparison controller
    $c->forward('/admin/schema-comparison/create-result-from-table');
}

sub sync_table_to_result :Chained('base') :PathPart('sync_table_to_result') :Args(0) {
    my ($self, $c) = @_;
    
    # Forward to the dedicated schema comparison controller
    $c->forward('/admin/schema-comparison/sync-table-to-result');
}

sub sync_result_to_table :Chained('base') :PathPart('sync_result_to_table') :Args(0) {
    my ($self, $c) = @_;
    
    # Forward to the dedicated schema comparison controller
    $c->forward('/admin/schema-comparison/sync-result-to-table');
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
        
        # Check if there are uncommitted changes (exclude untracked files)
        my $git_status_output = `git -C ${\$c->path_to()} status --porcelain 2>&1`;
        my $has_uncommitted_changes = 0;
        my $has_untracked_files = 0;
        my @untracked_files = ();
        
        # Parse git status output to distinguish between uncommitted changes and untracked files
        # Uncommitted changes have prefixes like: M (modified), A (added), D (deleted), R (renamed), C (copied)
        # Untracked files have prefix: ?? (untracked)
        if ($git_status_output) {
            for my $line (split /\n/, $git_status_output) {
                # Check if line indicates actual uncommitted changes (not untracked files)
                if ($line =~ /^[MADRCU]/) {
                    $has_uncommitted_changes = 1;
                } elsif ($line =~ /^\?\?\s+(.+)$/) {
                    $has_untracked_files = 1;
                    push @untracked_files, $1;
                }
            }
        }
        
        $status->{git_status}->{has_uncommitted_changes} = $has_uncommitted_changes;
        $status->{git_status}->{has_untracked_files} = $has_untracked_files;
        $status->{git_status}->{untracked_files} = \@untracked_files;
        
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
        
        if ($status->{git_status}->{has_untracked_files}) {
            my $file_count = scalar @{$status->{git_status}->{untracked_files}};
            push @{$status->{recommendations}}, {
                type => 'info',
                icon => 'fas fa-file-plus',
                message => "You have $file_count untracked file(s)",
                action => 'Add files to Git if needed, or add to .gitignore',
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
    
    # Get current service status using the StarmanServiceManager utility
    my $service_manager = $self->get_starman_service_manager($c);
    my $service_status = $service_manager->get_service_status($c->path_to());
    
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
        "Starting Starman diagnostics action");
    
    # Use centralized admin authentication
    return unless $self->admin_auth->require_admin_access($c, 'starman_diagnostics');
    
    # Handle POST requests for diagnostic actions
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action') || '';
        
        if ($action eq 'run_diagnostics') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'starman_diagnostics', 
                "Running Starman diagnostics");
            
            my $output = $self->run_starman_diagnostics($c);
            $c->stash(output => $output);
            $c->stash(success_msg => "Diagnostics completed successfully");
        }
    }
    
    # Get current service status using the StarmanServiceManager utility
    my $service_manager = $self->get_starman_service_manager($c);
    my $service_status = $service_manager->get_service_status($c->path_to());
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller starman_diagnostics view - Template: admin/starman_diagnostics.tt";
    }
    
    $c->stash(
        template => 'admin/starman_diagnostics.tt',
        service_status => $service_status
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'starman_diagnostics', 
        "Completed Starman diagnostics action");
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



# Run basic Starman diagnostics
sub run_starman_diagnostics {
    my ($self, $c) = @_;
    
    my $output = "=== Starman Service Diagnostics ===\n\n";
    
    # Check service status
    $output .= "1. Service Status Check:\n";
    my $status_cmd = `systemctl status starman 2>&1`;
    $output .= $status_cmd . "\n";
    
    # Check if PSGI file exists
    $output .= "2. PSGI File Check:\n";
    my $app_dir = '/home/shanta/PycharmProjects/comserv2';
    my $psgi_file = "$app_dir/Comserv/comserv.psgi";
    if (-f $psgi_file) {
        $output .= "✓ PSGI file exists: $psgi_file\n";
        my $psgi_perms = sprintf("%04o", (stat($psgi_file))[2] & 07777);
        $output .= "  Permissions: $psgi_perms\n";
    } else {
        $output .= "✗ PSGI file missing: $psgi_file\n";
    }
    
    # Check process information
    $output .= "\n3. Process Information:\n";
    my $ps_output = `ps aux | grep starman | grep -v grep 2>/dev/null`;
    if ($ps_output) {
        $output .= $ps_output;
    } else {
        $output .= "No Starman processes found\n";
    }
    
    # Check port usage
    $output .= "\n4. Port Usage Check:\n";
    my $port_check = `netstat -tlnp 2>/dev/null | grep :5000 || echo "Port 5000 not in use"`;
    $output .= $port_check;
    
    # Check recent logs
    $output .= "\n5. Recent Service Logs:\n";
    my $log_output = `journalctl -u starman --no-pager -n 10 2>/dev/null || echo "Could not access service logs"`;
    $output .= $log_output;
    
    $output .= "\n=== Diagnostics Complete ===\n";
    
    return $output;
}

# Emergency backup directory browser and restore functionality
sub emergency_restore :Chained('base') :PathPart('emergency-restore') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'emergency_restore', 
        "Starting emergency restore interface");
    
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action');
        
        if ($action eq 'restore_psgi') {
            my $result = $self->restore_psgi_file($c);
            $c->stash(%$result);
        } elsif ($action eq 'restore_file') {
            my $backup_path = $c->req->param('backup_path');
            my $target_file = $c->req->param('target_file');
            my $result = $self->restore_file_from_backup($c, $backup_path, $target_file);
            $c->stash(%$result);
        }
    }
    
    # Get backup directory contents
    my $backup_contents = $self->get_backup_directory_contents($c);
    $c->stash(backup_contents => $backup_contents);
    
    # Check if comserv.psgi exists
    my $app_dir = '/home/shanta/PycharmProjects/comserv2';
    my $psgi_exists = -f "$app_dir/Comserv/comserv.psgi";
    $c->stash(psgi_exists => $psgi_exists);
    
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller emergency_restore view - Using simple output";
    }
    
    # Get Starman status using existing functionality
    my $software_status = $self->get_software_management_status($c);
    
    $c->stash(
        template => 'admin/emergency_restore.tt',
        backup_contents => $backup_contents,
        software_status => $software_status
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'emergency_restore', 
        "Completed emergency restore interface");
}

# Get contents of backup directories (both /Comserv/backup and /Comserv/backups)
sub get_backup_directory_contents {
    my ($self, $c) = @_;
    
    my $contents = {
        backup_singular => [],  # /Comserv/backup/
        backup_plural => [],    # /Comserv/backups/
        error => ''
    };
    
    my $app_dir = '/home/shanta/PycharmProjects/comserv2';
    
    # Check /Comserv/backup/ directory (mentioned by user)
    my $backup_dir_singular = "$app_dir/Comserv/backup";
    if (-d $backup_dir_singular) {
        $contents->{backup_singular} = $self->scan_backup_directory($c, $backup_dir_singular, 'backup');
    }
    
    # Check /Comserv/backups/ directory (used by existing Git controller)
    my $backup_dir_plural = "$app_dir/Comserv/backups";
    if (-d $backup_dir_plural) {
        $contents->{backup_plural} = $self->scan_backup_directory($c, $backup_dir_plural, 'backups');
    }
    
    if (!@{$contents->{backup_singular}} && !@{$contents->{backup_plural}}) {
        $contents->{error} = "No backup directories found. Checked: $backup_dir_singular and $backup_dir_plural";
    }
    
    return $contents;
}

# Scan a backup directory for files
sub scan_backup_directory {
    my ($self, $c, $backup_dir, $dir_type) = @_;
    
    my @files = ();
    
    eval {
        opendir(my $dh, $backup_dir) or die "Cannot open directory: $!";
        my @entries = readdir($dh);
        closedir($dh);
        
        for my $entry (@entries) {
            next if $entry =~ /^\.\.?$/;  # Skip . and ..
            
            my $full_path = "$backup_dir/$entry";
            my $stat = stat($full_path);
            
            push @files, {
                name => $entry,
                full_path => $full_path,
                is_directory => -d $full_path,
                size => $stat ? $stat->size : 0,
                modified => $stat ? strftime("%Y-%m-%d %H:%M:%S", localtime($stat->mtime)) : 'Unknown',
                dir_type => $dir_type
            };
        }
        
        # Sort by modification time (newest first)
        @files = sort { 
            my $a_stat = stat($a->{full_path});
            my $b_stat = stat($b->{full_path});
            ($b_stat ? $b_stat->mtime : 0) <=> ($a_stat ? $a_stat->mtime : 0)
        } @files;
        
    } or do {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'scan_backup_directory', 
            "Error scanning backup directory $backup_dir: $@");
    };
    
    return \@files;
}

# Emergency restore of comserv.psgi file
sub restore_psgi_file {
    my ($self, $c) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => ''
    };
    
    my $app_dir = '/home/shanta/PycharmProjects/comserv2';
    my $target_file = "$app_dir/Comserv/comserv.psgi";
    
    # Look for comserv.psgi in backup directories
    my @backup_dirs = (
        "$app_dir/Comserv/backup",
        "$app_dir/Comserv/backups"
    );
    
    my $source_file = undef;
    
    for my $backup_dir (@backup_dirs) {
        next unless -d $backup_dir;
        
        # Look for comserv.psgi directly
        my $psgi_backup = "$backup_dir/comserv.psgi";
        if (-f $psgi_backup) {
            $source_file = $psgi_backup;
            last;
        }
        
        # Look for comserv.psgi in subdirectories
        eval {
            opendir(my $dh, $backup_dir) or die "Cannot open directory: $!";
            my @entries = readdir($dh);
            closedir($dh);
            
            for my $entry (@entries) {
                next if $entry =~ /^\.\.?$/;
                my $subdir = "$backup_dir/$entry";
                next unless -d $subdir;
                
                my $psgi_in_subdir = "$subdir/comserv.psgi";
                if (-f $psgi_in_subdir) {
                    $source_file = $psgi_in_subdir;
                    last;
                }
                
                # Also check Comserv subdirectory
                my $psgi_in_comserv = "$subdir/Comserv/comserv.psgi";
                if (-f $psgi_in_comserv) {
                    $source_file = $psgi_in_comserv;
                    last;
                }
            }
        };
        
        last if $source_file;
    }
    
    if (!$source_file) {
        $result->{message} = "comserv.psgi not found in any backup directory";
        $result->{output} = "Searched directories: " . join(", ", @backup_dirs);
        $result->{error_msg} = $result->{message};
        return $result;
    }
    
    # Create backup of current file if it exists
    if (-f $target_file) {
        my $backup_current = "$target_file.backup." . time();
        if (copy($target_file, $backup_current)) {
            $result->{output} .= "Created backup of existing file: $backup_current\n";
        }
    }
    
    # Copy the backup file to target location
    eval {
        copy($source_file, $target_file) or die "Copy failed: $!";
        chmod(0755, $target_file);  # Make executable
        
        $result->{success} = 1;
        $result->{message} = "comserv.psgi restored successfully";
        $result->{output} .= "Restored comserv.psgi from: $source_file\n";
        $result->{output} .= "Target location: $target_file\n";
        $result->{success_msg} = "comserv.psgi has been restored. Starman should now be able to accept calls.";
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restore_psgi_file', 
            "Successfully restored comserv.psgi from $source_file to $target_file");
            
    } or do {
        $result->{message} = "Failed to restore comserv.psgi: $@";
        $result->{output} .= "Restore error: $@\n";
        $result->{error_msg} = $result->{message};
        
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'restore_psgi_file', 
            "Failed to restore comserv.psgi: $@");
    };
    
    return $result;
}

# Generic file restore from backup
sub restore_file_from_backup {
    my ($self, $c, $backup_path, $target_file) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => ''
    };
    
    return $result unless $backup_path && $target_file;
    
    unless (-f $backup_path) {
        $result->{message} = "Backup file not found: $backup_path";
        $result->{error_msg} = $result->{message};
        return $result;
    }
    
    my $app_dir = '/home/shanta/PycharmProjects/comserv2';
    my $full_target_path = "$app_dir/$target_file";
    
    # Create backup of current file if it exists
    if (-f $full_target_path) {
        my $backup_current = "$full_target_path.backup." . time();
        if (copy($full_target_path, $backup_current)) {
            $result->{output} .= "Created backup of existing file: $backup_current\n";
        }
    }
    
    # Ensure target directory exists
    my $target_dir = dirname($full_target_path);
    unless (-d $target_dir) {
        make_path($target_dir) or do {
            $result->{message} = "Failed to create target directory: $target_dir";
            $result->{error_msg} = $result->{message};
            return $result;
        };
    }
    
    # Copy the backup file to target location
    eval {
        copy($backup_path, $full_target_path) or die "Copy failed: $!";
        
        $result->{success} = 1;
        $result->{message} = "File restored successfully";
        $result->{output} .= "Restored file from: $backup_path\n";
        $result->{output} .= "Target location: $full_target_path\n";
        $result->{success_msg} = "File '$target_file' has been restored from backup.";
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restore_file_from_backup', 
            "Successfully restored $target_file from $backup_path");
            
    } or do {
        $result->{message} = "Failed to restore file: $@";
        $result->{output} .= "Restore error: $@\n";
        $result->{error_msg} = $result->{message};
        
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'restore_file_from_backup', 
            "Failed to restore file: $@");
    };
    
    return $result;
}

# Software Update System - Main interface for comprehensive software updates
sub software_update :Chained('base') :PathPart('software-update') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'software_update', 
        "Starting software update interface");
    
    # Handle POST requests for update actions
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action');
        
        if ($action eq 'check_updates') {
            my $result = $self->check_available_updates($c);
            $c->stash(%$result);
        } elsif ($action eq 'pull_updates') {
            my $sudo_username = $c->req->param('sudo_username');
            my $sudo_password = $c->req->param('sudo_password');
            
            if (!$sudo_username || !$sudo_password) {
                $c->stash->{error_msg} = "System credentials required for git operations";
                $c->stash->{show_password_form} = 1;
            } else {
                my $result = $self->execute_git_pull($c, $sudo_username, $sudo_password);
                $c->stash(%$result);
                # Clear the password from memory for security
                delete $c->req->params->{sudo_password};
            }
        } elsif ($action eq 'deploy_updates') {
            my $sudo_username = $c->req->param('sudo_username');
            my $sudo_password = $c->req->param('sudo_password');
            
            if (!$sudo_username || !$sudo_password) {
                $c->stash->{error_msg} = "System credentials required for deployment operations";
                $c->stash->{show_password_form} = 1;
            } else {
                my $result = $self->execute_deployment($c, $sudo_username, $sudo_password);
                $c->stash(%$result);
                # Clear the password from memory for security
                delete $c->req->params->{sudo_password};
            }
        } elsif ($action eq 'show_credentials_form') {
            $c->stash->{show_password_form} = 1;
        }
    }
    
    # Get current software management status
    my $software_status = $self->get_software_management_status($c);
    
    # Get update history
    my $update_history = $self->get_update_history($c);
    
    # Get system requirements check
    my $system_check = $self->check_system_requirements($c);
    
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller software_update view - Template: admin/software_update.tt";
    }
    
    $c->stash(
        template => 'admin/software_update.tt',
        software_status => $software_status,
        update_history => $update_history,
        system_check => $system_check
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'software_update', 
        "Completed software update interface");
}

# Check for available updates from the repository
sub check_available_updates {
    my ($self, $c) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => '',
        updates_available => 0,
        update_details => []
    };
    
    try {
        # Fetch from remote to get latest information
        my $fetch_output = `git -C ${\$c->path_to()} fetch origin 2>&1`;
        $result->{output} .= "Fetch output:\n$fetch_output\n";
        
        # Check current branch
        my $current_branch = `git -C ${\$c->path_to()} branch --show-current 2>&1`;
        chomp $current_branch;
        
        # Check commits behind
        my $commits_behind = `git -C ${\$c->path_to()} rev-list HEAD..origin/$current_branch --count 2>/dev/null`;
        chomp $commits_behind;
        
        if ($commits_behind && $commits_behind > 0) {
            $result->{updates_available} = $commits_behind;
            $result->{success} = 1;
            $result->{message} = "$commits_behind update(s) available";
            
            # Get details of pending commits
            my $pending_commits = `git -C ${\$c->path_to()} log HEAD..origin/$current_branch --oneline --no-merges 2>/dev/null`;
            my @commit_lines = split /\n/, $pending_commits;
            
            foreach my $commit (@commit_lines) {
                if ($commit =~ /^([a-f0-9]+)\s+(.+)$/) {
                    push @{$result->{update_details}}, {
                        commit_hash => $1,
                        commit_message => $2
                    };
                }
            }
            
            $result->{output} .= "\nPending commits:\n$pending_commits";
        } else {
            $result->{success} = 1;
            $result->{message} = "Your software is up to date";
            $result->{output} .= "\nNo updates available";
        }
        
    } catch {
        my $error = $_;
        $result->{message} = "Error checking for updates: $error";
        $result->{output} .= "\nError: $error";
        $result->{error_msg} = $result->{message};
        
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'check_available_updates', 
            "Error checking for updates: $error");
    };
    
    return $result;
}

# Execute git pull with sudo credentials
sub execute_git_pull {
    my ($self, $c, $sudo_username, $sudo_password) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => '',
        backup_created => 0
    };
    
    try {
        # Create backup before pulling
        my $backup_result = $self->create_pre_update_backup($c);
        if ($backup_result->{success}) {
            $result->{backup_created} = 1;
            $result->{output} .= "Backup created: " . $backup_result->{backup_path} . "\n";
        } else {
            $result->{output} .= "Backup warning: " . $backup_result->{message} . "\n";
        }
        
        # Execute git pull
        my $app_dir = $c->path_to();
        my $pull_command = "cd $app_dir && git pull origin";
        
        # Use echo to pipe password (insecure but functional for controlled environment)
        my $full_command = "echo '$sudo_password' | sudo -S -u $sudo_username $pull_command 2>&1";
        my $output = `$full_command`;
        
        $result->{output} .= "\nGit pull output:\n$output";
        
        # Check if pull was successful
        if ($output =~ /Already up to date|Fast-forward|\d+ files? changed/) {
            $result->{success} = 1;
            $result->{message} = "Software updates pulled successfully";
            $result->{success_msg} = "Code has been updated. Review changes before deploying.";
        } else {
            $result->{message} = "Git pull completed but may need review";
            $result->{success_msg} = "Git pull executed. Please review output for any conflicts.";
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
            "Git pull executed by user: $sudo_username");
        
    } catch {
        my $error = $_;
        $result->{message} = "Error during git pull: $error";
        $result->{output} .= "\nError: $error";
        $result->{error_msg} = $result->{message};
        
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_pull', 
            "Error during git pull: $error");
    };
    
    return $result;
}

# Execute full deployment (dependencies + restart)
sub execute_deployment {
    my ($self, $c, $sudo_username, $sudo_password) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => '',
        steps_completed => []
    };
    
    try {
        my $app_dir = $c->path_to();
        
        # Step 1: Check dependencies
        $result->{output} .= "=== Step 1: Checking Dependencies ===\n";
        my $deps_check = `cd $app_dir && perl Makefile.PL 2>&1`;
        $result->{output} .= $deps_check;
        push @{$result->{steps_completed}}, 'dependencies_checked';
        
        # Step 2: Install missing dependencies if any
        $result->{output} .= "\n=== Step 2: Installing Dependencies ===\n";
        my $deps_install = `cd $app_dir && cpanm --installdeps . 2>&1`;
        $result->{output} .= $deps_install;
        push @{$result->{steps_completed}}, 'dependencies_installed';
        
        # Step 3: Restart Starman service
        $result->{output} .= "\n=== Step 3: Restarting Starman Service ===\n";
        my ($restart_success, $restart_output) = $self->execute_starman_restart($c, $sudo_username, $sudo_password);
        $result->{output} .= $restart_output;
        
        if ($restart_success) {
            push @{$result->{steps_completed}}, 'service_restarted';
            $result->{success} = 1;
            $result->{message} = "Deployment completed successfully";
            $result->{success_msg} = "Software has been deployed and service restarted.";
        } else {
            $result->{message} = "Deployment partially completed - service restart failed";
            $result->{error_msg} = "Dependencies updated but service restart failed. Manual intervention may be required.";
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_deployment', 
            "Deployment executed with steps: " . join(', ', @{$result->{steps_completed}}));
        
    } catch {
        my $error = $_;
        $result->{message} = "Error during deployment: $error";
        $result->{output} .= "\nError: $error";
        $result->{error_msg} = $result->{message};
        
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_deployment', 
            "Error during deployment: $error");
    };
    
    return $result;
}

# Create backup before updates
sub create_pre_update_backup {
    my ($self, $c) = @_;
    
    my $result = {
        success => 0,
        message => '',
        backup_path => ''
    };
    
    try {
        my $app_dir = $c->path_to();
        my $timestamp = strftime("%Y%m%d_%H%M%S", localtime());
        my $backup_dir = "$app_dir/Comserv/backups/pre_update_$timestamp";
        
        # Create backup directory
        make_path($backup_dir) or die "Cannot create backup directory: $!";
        
        # Copy critical files
        my @critical_files = (
            'Comserv/comserv.psgi',
            'Comserv/lib/Comserv.pm',
            'Comserv/comserv.conf'
        );
        
        foreach my $file (@critical_files) {
            my $source = "$app_dir/$file";
            next unless -f $source;
            
            my $target_dir = dirname("$backup_dir/$file");
            make_path($target_dir) unless -d $target_dir;
            
            copy($source, "$backup_dir/$file") or warn "Failed to backup $file: $!";
        }
        
        # Create manifest file
        my $manifest = "$backup_dir/BACKUP_MANIFEST.txt";
        open(my $fh, '>', $manifest) or die "Cannot create manifest: $!";
        print $fh "Comserv Pre-Update Backup\n";
        print $fh "Created: " . strftime("%Y-%m-%d %H:%M:%S", localtime()) . "\n";
        print $fh "Git Commit: " . `git -C $app_dir rev-parse HEAD 2>/dev/null` || "Unknown\n";
        print $fh "Files backed up:\n";
        foreach my $file (@critical_files) {
            print $fh "  $file\n" if -f "$app_dir/$file";
        }
        close($fh);
        
        $result->{success} = 1;
        $result->{backup_path} = $backup_dir;
        $result->{message} = "Backup created successfully";
        
    } catch {
        my $error = $_;
        $result->{message} = "Failed to create backup: $error";
    };
    
    return $result;
}

# Get software update history
sub get_update_history {
    my ($self, $c) = @_;
    
    my @history = ();
    
    try {
        # Get recent commits
        my $log_output = `git -C ${\$c->path_to()} log --oneline -10 --no-merges 2>/dev/null`;
        my @commits = split /\n/, $log_output;
        
        foreach my $commit (@commits) {
            if ($commit =~ /^([a-f0-9]+)\s+(.+)$/) {
                # Get commit details
                my $commit_hash = $1;
                my $commit_msg = $2;
                my $commit_date = `git -C ${\$c->path_to()} show -s --format=%ci $commit_hash 2>/dev/null`;
                chomp $commit_date;
                
                push @history, {
                    hash => $commit_hash,
                    message => $commit_msg,
                    date => $commit_date,
                    author => `git -C ${\$c->path_to()} show -s --format=%an $commit_hash 2>/dev/null` || 'Unknown'
                };
            }
        }
        
    } catch {
        # If git fails, return empty history
    };
    
    return \@history;
}

# Check system requirements for updates
sub check_system_requirements {
    my ($self, $c) = @_;
    
    my $check = {
        perl_version => 'Unknown',
        disk_space => 'Unknown',
        memory => 'Unknown',
        git_version => 'Unknown',
        requirements_met => 1,
        warnings => []
    };
    
    try {
        # Check Perl version
        $check->{perl_version} = $^V ? sprintf("v%vd", $^V) : 'Unknown';
        
        # Check disk space
        my $df_output = `df -h . | tail -1`;
        if ($df_output =~ /\s+(\d+)%\s+/) {
            my $usage = $1;
            $check->{disk_space} = "${usage}% used";
            
            if ($usage > 95) {
                push @{$check->{warnings}}, "Critical: Disk space very low (${usage}% used)";
                $check->{requirements_met} = 0;
            } elsif ($usage > 85) {
                push @{$check->{warnings}}, "Warning: Disk space getting low (${usage}% used)";
            }
        }
        
        # Check memory
        my $free_output = `free -h | grep '^Mem:'`;
        if ($free_output =~ /Mem:\s+(\S+)\s+(\S+)\s+(\S+)/) {
            $check->{memory} = "$2 used of $1";
        }
        
        # Check Git version
        my $git_version = `git --version 2>/dev/null`;
        chomp $git_version;
        $check->{git_version} = $git_version || 'Not available';
        
        unless ($git_version) {
            push @{$check->{warnings}}, "Git not available - required for updates";
            $check->{requirements_met} = 0;
        }
        
    } catch {
        push @{$check->{warnings}}, "Error checking system requirements";
    };
    
    return $check;
}

# Schema Manager action - manage database schema and create AI conversation tables
sub schema_manager : Chained('admin_check') : PathPart('schema_manager') : Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_manager', 
        "Schema manager page accessed");
    
    # Handle POST requests for table creation
    if ($c->request->method eq 'POST') {
        my $action = $c->request->params->{action} || '';
        
        if ($action eq 'create_ai_tables') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_manager', 
                "Creating AI conversation tables");
            
            try {
                my $schema_manager = $c->model('DBSchemaManager');
                
                # Path to our AI conversation SQL file
                my $sql_file_path = $c->path_to('Comserv', 'sql', 'ai_conversation_tables.sql');
                
                # Create tables using the DBSchemaManager
                my $result = $schema_manager->create_table_from_sql($c, 'ENCY', $sql_file_path->stringify);
                
                $c->stash->{message} = "AI conversation tables created successfully! " .
                                      "Executed $result->{executed_count} statements.";
                $c->stash->{message_type} = 'success';
                
                # Check if tables were created successfully
                my $ai_conv_exists = $schema_manager->table_exists($c, 'ENCY', 'ai_conversations');
                my $ai_msg_exists = $schema_manager->table_exists($c, 'ENCY', 'ai_messages');
                
                $c->stash->{ai_tables_status} = {
                    ai_conversations => $ai_conv_exists,
                    ai_messages => $ai_msg_exists
                };
                
            } catch {
                my $error = $_;
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'schema_manager', 
                    "Error creating AI tables: $error");
                    
                $c->stash->{message} = "Error creating AI conversation tables: $error";
                $c->stash->{message_type} = 'error';
            };
        }
    } else {
        # GET request - show schema information
        try {
            my $schema_manager = $c->model('DBSchemaManager');
            
            # Check current table status
            my $ai_conv_exists = $schema_manager->table_exists($c, 'ENCY', 'ai_conversations');
            my $ai_msg_exists = $schema_manager->table_exists($c, 'ENCY', 'ai_messages');
            
            $c->stash->{ai_tables_status} = {
                ai_conversations => $ai_conv_exists,
                ai_messages => $ai_msg_exists
            };
            
            # Get list of existing tables
            my $tables = $schema_manager->list_tables($c, 'ENCY');
            $c->stash->{existing_tables} = $tables;
            
        } catch {
            my $error = $_;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'schema_manager', 
                "Error getting schema information: $error");
                
            $c->stash->{message} = "Error retrieving schema information: $error";
            $c->stash->{message_type} = 'error';
        };
    }
    
    $c->stash->{template} = 'admin/schema_manager.md';
}

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;

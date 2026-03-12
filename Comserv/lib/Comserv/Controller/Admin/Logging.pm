package Comserv::Controller::Admin::Logging;

use Moose;
use namespace::autoclean;
use File::Spec;
use File::Basename;
use Comserv::Util::Logging;

BEGIN { extends 'Comserv::Controller::Base'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub begin :Private {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', 
        "User accessing logging admin: " . $c->req->uri);
    
    my $roles = $c->session->{roles} || [];
    
    if (ref $roles ne 'ARRAY') {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'begin', 
            "Invalid or undefined roles in session");
        $c->stash->{error_msg} = "Session expired or invalid. Please log in again.";
        $c->res->redirect($c->uri_for('/user/login'));
        $c->detach;
    }
    
    unless (grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'begin', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "Unauthorized access. You do not have permission to view this page.";
        $c->res->redirect($c->uri_for('/'));
        $c->detach;
    }
}

sub index :Path('/admin/logging') :Args(0) {
    my ($self, $c) = @_;

    $c->stash(template => 'admin/Logging/AdminLoggingIndex.tt');

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        'Loading logging administration interface');
    
    # Refresh settings from DB
    $self->logging->refresh_settings($c);

    my $log_file = $self->logging->{LOG_FILE} || $ENV{COMSERV_LOG_FILE};
    
    # If not found, try to find it where we expect
    unless ($log_file && -e $log_file) {
         my $base_dir = $ENV{'COMSERV_NFS_LOG_DIR'} // $ENV{'COMSERV_LOG_DIR'} // File::Spec->catdir($c->config->{home}, '..');
         $log_file = File::Spec->catfile($base_dir, "logs", "application.log") unless $ENV{'COMSERV_NFS_LOG_DIR'};
         $log_file = File::Spec->catfile($base_dir, "application.log") if $ENV{'COMSERV_NFS_LOG_DIR'};
    }

    my @archived_logs;
    if ($log_file && -e $log_file) {
        my ($filename, $directories, $suffix) = fileparse($log_file);
        my $archive_dir = File::Spec->catdir($directories, 'archive');
        
        if (-d $archive_dir) {
            opendir(my $dh, $archive_dir);
            while (my $file = readdir($dh)) {
                next if $file =~ /^\./;
                my $path = File::Spec->catfile($archive_dir, $file);
                push @archived_logs, {
                    name => $file,
                    path => $path,
                    size => sprintf("%.2f KB", (-s $path) / 1024),
                    mtime => (stat($path))[9]
                };
            }
            closedir($dh);
            @archived_logs = sort { $b->{mtime} <=> $a->{mtime} } @archived_logs;
        }
    }

    # Fetch recent logs from database with filtering
    my @db_logs;
    my $search_params = {};
    my $filter_level = $c->req->param('filter_level');
    my $filter_sitename = $c->req->param('filter_sitename');
    my $filter_username = $c->req->param('filter_username');
    my $search_text = $c->req->param('search_text');

    $search_params->{level} = $filter_level if $filter_level;
    $search_params->{sitename} = $filter_sitename if $filter_sitename;
    $search_params->{username} = $filter_username if $filter_username;
    $search_params->{message} = { -like => "%$search_text%" } if $search_text;

    eval {
        my $logs_rs = $c->model('DBEncy')->resultset('SystemLog')->search(
            $search_params,
            { order_by => { -desc => 'timestamp' }, rows => 100 }
        );
        while (my $log = $logs_rs->next) {
            push @db_logs, {
                timestamp => $log->timestamp,
                level => $log->level,
                subroutine => $log->subroutine,
                message => $log->message,
                file => basename($log->file),
                line => $log->line,
                username => $log->username,
                sitename => $log->sitename
            };
        }
    };

    # Get available levels for filter
    my @levels = sort { $Comserv::Util::Logging::LEVEL_PRIORITY{$a} <=> $Comserv::Util::Logging::LEVEL_PRIORITY{$b} } keys %Comserv::Util::Logging::LEVEL_PRIORITY;

    $c->stash(
        current_log => {
            path => $log_file,
            size => $log_file && -e $log_file ? sprintf("%.2f KB", (-s $log_file) / 1024) : '0 KB',
            exists => $log_file && -e $log_file ? 1 : 0
        },
        archived_logs => \@archived_logs,
        db_logs => \@db_logs,
        levels => \@levels,
        filter_level => $filter_level,
        filter_sitename => $filter_sitename,
        filter_username => $filter_username,
        search_text => $search_text,
        email_threshold => $Comserv::Util::Logging::EMAIL_NOTIFY_THRESHOLD,
        nfs_dir => $ENV{COMSERV_NFS_LOG_DIR} || 'Not Set',
        template => 'admin/Logging/AdminLoggingIndex.tt'
    );
}

sub view_log :Path('/admin/logging/view') :Args(0) {
    my ($self, $c) = @_;
    
    my $path = $c->req->param('path');
    unless ($path && -e $path && -r $path) {
        $c->flash->{error_msg} = "Invalid log file path or file not readable.";
        return $c->res->redirect($c->uri_for($self->action_for('index')));
    }

    # Security check: ensure path is within allowed log directories
    # (Simplified for now, but should be robust)
    
    my $content = "";
    eval {
        open my $fh, '<', $path or die "Could not open $path: $!";
        # Read last 500 lines for performance
        my @lines = <$fh>;
        $content = join('', splice(@lines, -500));
        close $fh;
    };
    if ($@) {
        $c->flash->{error_msg} = "Error reading log file: $@";
        return $c->res->redirect($c->uri_for($self->action_for('index')));
    }

    $c->stash(
        log_path => $path,
        log_name => basename($path),
        content => $content,
        template => 'admin/Logging/AdminViewLogs.tt'
    );
}

sub rotate :Path('/admin/logging/rotate') :Args(0) {
    my ($self, $c) = @_;
    
    eval {
        $self->logging->force_log_rotation();
    };
    if ($@) {
        $c->flash->{error_msg} = "Failed to rotate log: $@";
    } else {
        $c->flash->{success_msg} = "Log rotated successfully.";
    }
    
    $c->res->redirect($c->uri_for($self->action_for('index')));
}

sub settings :Path('/admin/logging/settings') :Args(0) {
    my ($self, $c) = @_;
    
    if ($c->req->method eq 'POST') {
        my $threshold = $c->req->param('email_threshold');
        my $nfs_dir = $c->req->param('nfs_dir');
        
        # Persist to DB
        eval {
            # Try to get site from SiteName or default to 'CSC'
            my $sitename = $c->stash->{SiteName} || 'CSC';
            my $site = $c->model('DBEncy')->resultset('Site')->find({ name => $sitename });
            
            # If site doesn't exist, try to find ANY site
            unless ($site) {
                $site = $c->model('DBEncy')->resultset('Site')->first;
            }

            if ($site) {
                # Save threshold
                if ($threshold && exists $Comserv::Util::Logging::LEVEL_PRIORITY{uc($threshold)}) {
                    $c->model('DBEncy')->resultset('SiteConfig')->update_or_create({
                        site_id => $site->id,
                        config_key => 'logging_email_threshold',
                        config_value => uc($threshold)
                    }, { key => 'site_config_site_id_config_key' });
                }

                # Save NFS dir
                if (defined $nfs_dir) {
                    $c->model('DBEncy')->resultset('SiteConfig')->update_or_create({
                        site_id => $site->id,
                        config_key => 'logging_nfs_dir',
                        config_value => $nfs_dir
                    }, { key => 'site_config_site_id_config_key' });
                }
                
                $self->logging->refresh_settings($c);
                $c->flash->{success_msg} = "Logging settings updated and persisted for " . $site->name;
            } else {
                # If no sites at all, just update in memory
                $Comserv::Util::Logging::EMAIL_NOTIFY_THRESHOLD = uc($threshold) if $threshold;
                $c->flash->{warn_msg} = "Settings updated in memory only (no sites found in DB).";
            }
        };
        if ($@) {
            my $err = "$@";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'settings', 
                "Failed to persist settings: $err");
            $c->flash->{error_msg} = "Failed to persist settings: $err";
        }
        return $c->res->redirect($c->uri_for($self->action_for('index')));
    }
    
    # Get current NFS dir from DB if available
    my $db_nfs_dir = "";
    eval {
        my $sitename = $c->stash->{SiteName} || 'CSC';
        my $site = $c->model('DBEncy')->resultset('Site')->find({ name => $sitename });
        if ($site) {
            my $nfs_cfg = $c->model('DBEncy')->resultset('SiteConfig')->find({
                site_id => $site->id,
                config_key => 'logging_nfs_dir'
            });
            $db_nfs_dir = $nfs_cfg->config_value if $nfs_cfg;
        }
    };

    $c->stash(
        levels => [sort { $Comserv::Util::Logging::LEVEL_PRIORITY{$a} <=> $Comserv::Util::Logging::LEVEL_PRIORITY{$b} } keys %Comserv::Util::Logging::LEVEL_PRIORITY],
        current_threshold => $Comserv::Util::Logging::EMAIL_NOTIFY_THRESHOLD,
        current_nfs_dir => $db_nfs_dir,
        env_nfs_dir => $ENV{COMSERV_NFS_LOG_DIR} || 'None',
        template => 'admin/Logging/AdminLoggingSettings.tt'
    );
}

__PACKAGE__->meta->make_immutable;

1;

package Comserv::Controller::Admin::Logging;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use File::Slurp;
use Data::Dumper;
use Comserv::Util::Logging;
use JSON qw(encode_json decode_json);

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'admin/logging');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Main logging administration interface
sub index :Path('/admin/logging') :Args(0) {
    my ($self, $c) = @_;

    # Log that we've entered the logging admin interface
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "***** ENTERED LOGGING ADMIN INTERFACE *****");

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
            "User not logged in, redirecting to login page");
        $c->flash->{error} = 'You must be logged in to access this page';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Check if the user has the admin role
    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "User does not have admin role, redirecting to home page. Roles: " .
            (defined $roles ? (ref $roles eq 'ARRAY' ? join(", ", @$roles) : ref($roles)) : "undefined"));
        $c->flash->{error} = 'You do not have permission to access this page. Required role: admin.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get current debug mode status
    my $debug_mode = $c->session->{debug_mode} || 0;
    
    # Get current site
    my $site_name = $c->session->{SiteName} || 'default';
    
    # PHASE 3: Get application log level settings
    my $app_log_level = Comserv::Util::Logging->get_application_log_level();
    my @available_log_levels = Comserv::Util::Logging->get_available_log_levels();
    
    # PHASE 2: Enhanced Error Reporting - Get error summary for dashboard
    my $error_summary = $self->logging->get_error_summary();
    my $recent_errors = $self->logging->get_stored_errors();
    
    # Get critical errors from session
    my $critical_errors = $c->session->{critical_errors} || [];
    my $has_critical_errors = $c->session->{has_critical_errors} || 0;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Site name: $site_name, Debug mode: $debug_mode, Total errors: " . $error_summary->{total_errors});

    # Set up stash for template
    $c->stash(
        template => 'admin/logging/index.tt',
        page_title => 'Logging Administration',
        debug_mode => $debug_mode,
        site_name => $site_name,
        app_log_level => $app_log_level,
        available_log_levels => \@available_log_levels,
        error_summary => $error_summary,
        recent_errors => $recent_errors,
        critical_errors => $critical_errors,
        has_critical_errors => $has_critical_errors,
    );
}

# Toggle debug mode
sub toggle_debug :Path('/admin/logging/toggle_debug') :Args(0) {
    my ($self, $c) = @_;

    # Check admin permissions
    if (!$c->user_exists && !$c->session->{user_id}) {
        $c->response->status(401);
        $c->response->body('Unauthorized');
        return;
    }

    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $c->response->status(403);
        $c->response->body('Forbidden');
        return;
    }

    # Toggle debug mode
    my $current_debug_mode = $c->session->{debug_mode} || 0;
    my $new_debug_mode = $current_debug_mode ? 0 : 1;
    
    $c->session->{debug_mode} = $new_debug_mode;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'toggle_debug',
        "Debug mode toggled from $current_debug_mode to $new_debug_mode by user: " . 
        ($c->session->{username} || 'unknown'));

    # Return JSON response
    $c->response->content_type('application/json');
    $c->response->body(encode_json({
        success => 1,
        debug_mode => $new_debug_mode,
        message => "Debug mode " . ($new_debug_mode ? "enabled" : "disabled")
    }));
}

# PHASE 3: Change application log level (separate from browser debug_mode)
sub set_app_log_level :Path('/admin/logging/set_app_log_level') :Args(0) {
    my ($self, $c) = @_;

    # Check admin permissions
    if (!$c->user_exists && !$c->session->{user_id}) {
        $c->response->status(401);
        $c->response->body('Unauthorized');
        return;
    }

    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $c->response->status(403);
        $c->response->body('Forbidden');
        return;
    }

    # Get the requested log level from parameters
    my $new_level = $c->request->params->{level};
    
    if (!$new_level) {
        $c->response->status(400);
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 0,
            message => "No log level specified"
        }));
        return;
    }

    # Set the new application log level
    my $old_level = Comserv::Util::Logging->get_application_log_level();
    my $success = Comserv::Util::Logging->set_application_log_level($new_level);
    
    if ($success) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_app_log_level',
            "Application log level changed from $old_level to $new_level by user: " . 
            ($c->session->{username} || 'unknown'));

        # Return JSON response
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 1,
            old_level => $old_level,
            new_level => $new_level,
            message => "Application log level changed to $new_level"
        }));
    } else {
        $c->response->status(400);
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 0,
            message => "Invalid log level: $new_level"
        }));
    }
}

# Force log rotation
sub rotate_logs :Path('/admin/logging/rotate') :Args(0) {
    my ($self, $c) = @_;

    # Check admin permissions
    if (!$c->user_exists && !$c->session->{user_id}) {
        $c->response->status(401);
        $c->response->body('Unauthorized');
        return;
    }

    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $c->response->status(403);
        $c->response->body('Forbidden');
        return;
    }

    # Force log rotation
    try {
        Comserv::Util::Logging->force_log_rotation();
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'rotate_logs',
            "Manual log rotation triggered by user: " . ($c->session->{username} || 'unknown'));

        # Return JSON response
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 1,
            message => "Log rotation completed successfully"
        }));
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'rotate_logs',
            "Log rotation failed: $error");

        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 0,
            message => "Log rotation failed: $error"
        }));
    };
}

# PHASE 2: Enhanced Error Reporting - Get error details
sub get_errors :Path('/admin/logging/errors') :Args(0) {
    my ($self, $c) = @_;

    # Check admin permissions
    if (!$c->user_exists && !$c->session->{user_id}) {
        $c->response->status(401);
        $c->response->body('Unauthorized');
        return;
    }

    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $c->response->status(403);
        $c->response->body('Forbidden');
        return;
    }

    # Get filter parameters
    my $level_filter = $c->request->param('level');
    my $limit = $c->request->param('limit') || 50;

    # Get errors
    my $errors = $self->logging->get_stored_errors($level_filter);
    
    # Apply limit
    if ($limit && @$errors > $limit) {
        $errors = [ splice(@$errors, 0, $limit) ];
    }

    # Return JSON response
    $c->response->content_type('application/json');
    $c->response->body(encode_json({
        success => 1,
        errors => $errors,
        total_count => scalar(@$errors),
        filter => $level_filter || 'all',
    }));
}

# PHASE 2: Enhanced Error Reporting - Clear errors
sub clear_errors :Path('/admin/logging/clear_errors') :Args(0) {
    my ($self, $c) = @_;

    # Check admin permissions
    if (!$c->user_exists && !$c->session->{user_id}) {
        $c->response->status(401);
        $c->response->body('Unauthorized');
        return;
    }

    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $c->response->status(403);
        $c->response->body('Forbidden');
        return;
    }

    # Get level filter
    my $level_filter = $c->request->param('level');

    try {
        # Clear errors
        $self->logging->clear_stored_errors($level_filter);
        
        # Clear critical errors from session if clearing all or critical
        if (!$level_filter || $level_filter eq 'CRITICAL') {
            $c->session->{critical_errors} = [];
            $c->session->{has_critical_errors} = 0;
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'clear_errors',
            "Errors cleared" . ($level_filter ? " (level: $level_filter)" : " (all levels)") . 
            " by user: " . ($c->session->{username} || 'unknown'));

        # Return JSON response
        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 1,
            message => "Errors cleared successfully" . ($level_filter ? " for level: $level_filter" : "")
        }));
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'clear_errors',
            "Failed to clear errors: $error");

        $c->response->content_type('application/json');
        $c->response->body(encode_json({
            success => 0,
            message => "Failed to clear errors: $error"
        }));
    };
}

# PHASE 2: Enhanced Error Reporting - Dismiss critical error notifications
sub dismiss_critical_errors :Path('/admin/logging/dismiss_critical') :Args(0) {
    my ($self, $c) = @_;

    # Check admin permissions
    if (!$c->user_exists && !$c->session->{user_id}) {
        $c->response->status(401);
        $c->response->body('Unauthorized');
        return;
    }

    my $roles = $c->session->{roles};
    if (!defined $roles || ref $roles ne 'ARRAY' || !grep { $_ eq 'admin' } @$roles) {
        $c->response->status(403);
        $c->response->body('Forbidden');
        return;
    }

    # Clear critical error notifications from session
    $c->session->{has_critical_errors} = 0;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dismiss_critical_errors',
        "Critical error notifications dismissed by user: " . ($c->session->{username} || 'unknown'));

    # Return JSON response
    $c->response->content_type('application/json');
    $c->response->body(encode_json({
        success => 1,
        message => "Critical error notifications dismissed"
    }));
}

__PACKAGE__->meta->make_immutable;

1;
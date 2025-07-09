package Comserv::Controller::DatabaseMode;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::DatabaseMode - Database Backend Selection Controller

=head1 DESCRIPTION

This controller provides interface for selecting and managing database backends
in the hybrid offline mode system. Supports MySQL and SQLite backend switching.

=cut

=head1 METHODS

=head2 index

Main database mode selection interface

=cut

sub index :Private {
    my ($self, $c) = @_;
    
    # Check admin/developer permissions
    unless ($c->check_user_roles(qw/admin developer/)) {
        $c->response->redirect($c->uri_for('/'));
        $c->detach();
    }
    
    try {
        # Get HybridDB model
        my $hybrid_db = $c->model('HybridDB');
        my $status = $hybrid_db->get_status();
        
        # Test current connection
        my $connection_test = $hybrid_db->test_connection($c);
        
        $c->stash(
            template => 'database_mode/index.tt',
            page_title => 'Database Backend Selection',
            status => $status,
            connection_test => $connection_test,
        );
        
        $self->log_with_details($c, 'info', 'Database mode interface accessed', {
            current_backend => $status->{current_backend},
            mysql_available => $status->{mysql_available},
        });
        
    } catch {
        my $error = $_;
        $c->stash(
            template => 'database_mode/index.tt',
            page_title => 'Database Backend Selection - Error',
            error_message => "Failed to load database status: $error",
        );
        
        $self->log_with_details($c, 'error', 'Database mode interface error', {
            error => $error,
        });
    };
}

=head2 switch_backend

Switch database backend (AJAX endpoint)

=cut

sub switch_backend :Private {
    my ($self, $c, $backend_name) = @_;
    
    # Check admin/developer permissions
    unless ($c->check_user_roles(qw/admin developer/)) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->detach('View::JSON');
    }
    
    try {
        # Validate backend name
        unless ($backend_name) {
            $c->response->status(400);
            $c->stash(json => { 
                success => 0, 
                error => "Backend name is required"
            });
            $c->detach('View::JSON');
        }
        
        # Get HybridDB model
        my $hybrid_db = $c->model('HybridDB');
        my $available_backends = $hybrid_db->get_available_backends();
        
        # Check if backend exists
        unless ($available_backends->{$backend_name}) {
            $c->response->status(400);
            $c->stash(json => { 
                success => 0, 
                error => "Unknown backend: $backend_name"
            });
            $c->detach('View::JSON');
        }
        
        # Check if backend is available
        unless ($available_backends->{$backend_name}->{available}) {
            $c->response->status(400);
            $c->stash(json => { 
                success => 0, 
                error => "Backend '$backend_name' is not available"
            });
            $c->detach('View::JSON');
        }
        
        # Switch backend
        $hybrid_db->switch_backend($c, $backend_name);
        
        # Test new connection
        my $connection_test = $hybrid_db->test_connection($c);
        my $status = $hybrid_db->get_status();
        
        my $backend_description = $available_backends->{$backend_name}->{config}->{description} || $backend_name;
        
        $c->stash(json => {
            success => 1,
            message => "Successfully switched to '$backend_description'",
            status => $status,
            connection_test => $connection_test,
        });
        
        $self->log_with_details($c, 'info', 'Database backend switched', {
            new_backend => $backend_name,
            backend_description => $backend_description,
            connection_test => $connection_test,
        });
        
    } catch {
        my $error = $_;
        $c->response->status(500);
        $c->stash(json => { 
            success => 0, 
            error => "Failed to switch backend: $error"
        });
        
        $self->log_with_details($c, 'error', 'Database backend switch failed', {
            requested_backend => $backend_name,
            error => $error,
        });
    };
    
    $c->detach('View::JSON');
}

=head2 toggle_localhost_override

Toggle localhost_override setting for a backend (AJAX endpoint)

=cut

sub toggle_localhost_override :Private {
    my ($self, $c) = @_;
    
    # Check admin/developer permissions
    unless ($c->check_user_roles(qw/admin developer/)) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->detach('View::JSON');
    }
    
    my $backend_name = $c->request->params->{backend} || $c->request->body_params->{backend};
    
    unless ($backend_name) {
        $c->response->status(400);
        $c->stash(json => { 
            success => 0, 
            error => "Backend name is required"
        });
        $c->detach('View::JSON');
    }
    
    try {
        # Get HybridDB model
        my $hybrid_db = $c->model('HybridDB');
        
        # Toggle localhost_override in configuration
        my $result = $hybrid_db->toggle_localhost_override($c, $backend_name);
        
        if ($result->{success}) {
            # Re-detect backends to apply changes
            $hybrid_db->_detect_backends($c);
            
            # Get updated status
            my $status = $hybrid_db->get_status();
            my $connection_test = $hybrid_db->test_connection($c);
            
            $c->stash(json => {
                success => 1,
                message => $result->{message},
                new_override_value => $result->{new_value},
                status => $status,
                connection_test => $connection_test,
            });
            
            $self->log_with_details($c, 'info', 'Localhost override toggled', {
                backend => $backend_name,
                new_value => $result->{new_value},
                message => $result->{message},
            });
        } else {
            $c->response->status(400);
            $c->stash(json => { 
                success => 0, 
                error => $result->{error}
            });
        }
        
    } catch {
        my $error = $_;
        $c->response->status(500);
        $c->stash(json => { 
            success => 0, 
            error => "Failed to toggle localhost override: $error"
        });
        
        $self->log_with_details($c, 'error', 'Localhost override toggle failed', {
            backend => $backend_name,
            error => $error,
        });
    };
    
    $c->detach('View::JSON');
}

=head2 status

Get current database status (AJAX endpoint)

=cut

sub status :Private {
    my ($self, $c) = @_;
    
    # Check admin/developer permissions
    unless ($c->check_user_roles(qw/admin developer/)) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->detach('View::JSON');
    }
    
    try {
        # Get HybridDB model
        my $hybrid_db = $c->model('HybridDB');
        my $status = $hybrid_db->get_status();
        
        # Test current connection
        my $connection_test = $hybrid_db->test_connection($c);
        
        # Re-detect MySQL availability
        $hybrid_db->_detect_backends($c);
        my $updated_status = $hybrid_db->get_status();
        
        $c->stash(json => {
            success => 1,
            status => $updated_status,
            connection_test => $connection_test,
        });
        
    } catch {
        my $error = $_;
        $c->response->status(500);
        $c->stash(json => { 
            success => 0, 
            error => "Failed to get status: $error"
        });
        
        $self->log_with_details($c, 'error', 'Database status check failed', {
            error => $error,
        });
    };
    
    $c->detach('View::JSON');
}

=head2 test_connection

Test connection to specified backend (AJAX endpoint)

=cut

sub test_connection :Private {
    my ($self, $c, $backend_name) = @_;
    
    # Check admin/developer permissions
    unless ($c->check_user_roles(qw/admin developer/)) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->detach('View::JSON');
    }
    
    try {
        # Validate backend name
        unless ($backend_name) {
            $c->response->status(400);
            $c->stash(json => { 
                success => 0, 
                error => "Backend name is required"
            });
            $c->detach('View::JSON');
        }
        
        # Get HybridDB model
        my $hybrid_db = $c->model('HybridDB');
        my $available_backends = $hybrid_db->get_available_backends();
        
        # Check if backend exists
        unless ($available_backends->{$backend_name}) {
            $c->response->status(400);
            $c->stash(json => { 
                success => 0, 
                error => "Unknown backend: $backend_name",
                connection_test => 0,
            });
            $c->detach('View::JSON');
        }
        
        # Temporarily switch to test backend
        my $original_backend = $hybrid_db->get_backend_type($c);
        
        if (!$available_backends->{$backend_name}->{available}) {
            my $backend_description = $available_backends->{$backend_name}->{config}->{description} || $backend_name;
            $c->stash(json => { 
                success => 0, 
                error => "Backend '$backend_description' is not available",
                connection_test => 0,
            });
            $c->detach('View::JSON');
        }
        
        # Test connection
        $hybrid_db->switch_backend($c, $backend_name);
        my $connection_test = $hybrid_db->test_connection($c);
        
        # Restore original backend
        $hybrid_db->switch_backend($c, $original_backend);
        
        my $backend_description = $available_backends->{$backend_name}->{config}->{description} || $backend_name;
        
        $c->stash(json => {
            success => 1,
            backend_name => $backend_name,
            connection_test => $connection_test,
            message => $connection_test ? 
                "Connection to '$backend_description' successful" : 
                "Connection to '$backend_description' failed",
        });
        
        $self->log_with_details($c, 'info', 'Database connection tested', {
            backend_name => $backend_name,
            backend_description => $backend_description,
            connection_test => $connection_test,
        });
        
    } catch {
        my $error = $_;
        $c->response->status(500);
        $c->stash(json => { 
            success => 0, 
            error => "Connection test failed: $error"
        });
        
        $self->log_with_details($c, 'error', 'Database connection test failed', {
            backend_name => $backend_name,
            error => $error,
        });
    };
    
    $c->detach('View::JSON');
}

=head2 sync_to_production

Sync current database to production (AJAX endpoint)

=cut

sub sync_to_production :Private {
    my ($self, $c) = @_;
    
    # Check admin permissions
    unless ($c->check_user_roles(qw/admin/)) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Admin access required' });
        $c->detach('View::JSON');
    }
    
    try {
        # Get parameters
        my $dry_run = $c->request->param('dry_run') || 0;
        my $tables_param = $c->request->param('tables') || '';
        my @tables = $tables_param ? split(/,/, $tables_param) : ();
        
        # Get HybridDB model
        my $hybrid_db = $c->model('HybridDB');
        
        # Perform sync
        my $sync_results = $hybrid_db->sync_to_production($c, {
            dry_run => $dry_run,
            tables => \@tables,
        });
        
        $c->stash(json => {
            success => 1,
            message => $dry_run ? 
                "Dry run completed - would sync $sync_results->{tables_synced} tables with $sync_results->{records_synced} records" :
                "Successfully synced $sync_results->{tables_synced} tables with $sync_results->{records_synced} records",
            sync_results => $sync_results,
        });
        
        $self->log_with_details($c, 'info', 'Database sync to production', {
            dry_run => $dry_run,
            tables_synced => $sync_results->{tables_synced},
            records_synced => $sync_results->{records_synced},
            errors => scalar(@{$sync_results->{errors}}),
        });
        
    } catch {
        my $error = $_;
        $c->response->status(500);
        $c->stash(json => { 
            success => 0, 
            error => "Sync failed: $error"
        });
        
        $self->log_with_details($c, 'error', 'Database sync to production failed', {
            error => $error,
        });
    };
    
    $c->detach('View::JSON');
}

=head2 refresh_backends

Refresh backend detection (AJAX endpoint)

=cut

sub refresh_backends :Private {
    my ($self, $c) = @_;
    
    # Check admin/developer permissions
    unless ($c->check_user_roles(qw/admin developer/)) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Admin or developer access required' });
        $c->detach('View::JSON');
    }
    
    try {
        # Get HybridDB model and refresh backend detection
        my $hybrid_db = $c->model('HybridDB');
        my $backends = $hybrid_db->refresh_backend_detection($c);
        
        $c->stash(json => {
            success => 1,
            message => 'Backend detection refreshed successfully',
            backends => $backends,
            total_backends => scalar(keys %$backends),
            available_count => scalar(grep { $_->{available} } values %$backends),
        });
        
        $self->log_with_details($c, 'info', 'Backend detection refreshed', {
            total_backends => scalar(keys %$backends),
            available_count => scalar(grep { $_->{available} } values %$backends),
        });
        
    } catch {
        my $error = $_;
        $c->response->status(500);
        $c->stash(json => { 
            success => 0, 
            error => "Backend refresh failed: $error"
        });
        
        $self->log_with_details($c, 'error', 'Backend detection refresh failed', {
            error => $error,
        });
    };
    
    $c->detach('View::JSON');
}

=head2 debug_backends

Debug endpoint to show backend configuration and status (AJAX endpoint)

=cut

sub debug_backends :Private {
    my ($self, $c) = @_;
    
    # Check admin/developer permissions
    unless ($c->check_user_roles(qw/admin developer/)) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->detach('View::JSON');
    }
    
    try {
        # Get HybridDB model
        my $hybrid_db = $c->model('HybridDB');
        my $available_backends = $hybrid_db->get_available_backends();
        my $status = $hybrid_db->get_status();
        
        # Build debug information
        my $debug_info = {
            current_backend => $status->{current_backend},
            total_backends => $status->{total_backends},
            available_count => $status->{available_count},
            backends => {},
        };
        
        # Add detailed backend information
        foreach my $backend_name (sort keys %$available_backends) {
            my $backend = $available_backends->{$backend_name};
            
            $debug_info->{backends}->{$backend_name} = {
                type => $backend->{type},
                available => $backend->{available},
                description => $backend->{config}->{description} || $backend_name,
                config => {
                    %{$backend->{config}},
                    # Hide password for security
                    password => $backend->{config}->{password} ? '***HIDDEN***' : undef,
                },
            };
        }
        
        $c->stash(json => {
            success => 1,
            debug_info => $debug_info,
            message => "Backend debug information retrieved successfully",
        });
        
        $self->log_with_details($c, 'info', 'Backend debug information requested', {
            current_backend => $status->{current_backend},
            total_backends => $status->{total_backends},
            available_count => $status->{available_count},
        });
        
    } catch {
        my $error = $_;
        $c->response->status(500);
        $c->stash(json => { 
            success => 0, 
            error => "Failed to get debug information: $error"
        });
        
        $self->log_with_details($c, 'error', 'Backend debug information failed', {
            error => $error,
        });
    };
    
    $c->detach('View::JSON');
}

=head2 log_with_details

Enhanced logging method with structured details

=cut

sub log_with_details {
    my ($self, $c, $level, $message, $details) = @_;
    
    my $log_entry = {
        controller => 'DatabaseMode',
        action => $c->action->name,
        message => $message,
        user => $c->user ? $c->user->username : 'anonymous',
        session_id => $c->sessionid || 'no_session',
        timestamp => scalar(localtime()),
        details => $details || {},
    };
    
    my $log_message = sprintf(
        "[%s] %s - %s (User: %s, Session: %s)",
        uc($level),
        $log_entry->{controller},
        $message,
        $log_entry->{user},
        substr($log_entry->{session_id}, 0, 8)
    );
    
    if ($level eq 'error') {
        $c->log->error($log_message);
    } elsif ($level eq 'warn') {
        $c->log->warn($log_message);
    } else {
        $c->log->info($log_message);
    }
    
    # Store detailed log in stash for potential database logging
    push @{$c->stash->{detailed_logs} ||= []}, $log_entry;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Comserv Development Team

=head1 COPYRIGHT

Copyright (c) 2025 Comserv. All rights reserved.

=cut
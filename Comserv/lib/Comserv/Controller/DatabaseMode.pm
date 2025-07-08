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
    my ($self, $c, $backend_type) = @_;
    
    # Check admin/developer permissions
    unless ($c->check_user_roles(qw/admin developer/)) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->detach('View::JSON');
    }
    
    try {
        # Validate backend type
        unless ($backend_type && ($backend_type eq 'mysql' || $backend_type eq 'sqlite')) {
            $c->response->status(400);
            $c->stash(json => { 
                success => 0, 
                error => "Invalid backend type: " . ($backend_type || 'undefined')
            });
            $c->detach('View::JSON');
        }
        
        # Get HybridDB model
        my $hybrid_db = $c->model('HybridDB');
        
        # Check if MySQL is available when switching to MySQL
        if ($backend_type eq 'mysql' && !$hybrid_db->is_mysql_available()) {
            $c->response->status(400);
            $c->stash(json => { 
                success => 0, 
                error => 'MySQL server is not available'
            });
            $c->detach('View::JSON');
        }
        
        # Switch backend
        $hybrid_db->switch_backend($c, $backend_type);
        
        # Test new connection
        my $connection_test = $hybrid_db->test_connection($c);
        my $status = $hybrid_db->get_status();
        
        $c->stash(json => {
            success => 1,
            message => "Successfully switched to $backend_type backend",
            status => $status,
            connection_test => $connection_test,
        });
        
        $self->log_with_details($c, 'info', 'Database backend switched', {
            new_backend => $backend_type,
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
            requested_backend => $backend_type,
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
    my ($self, $c, $backend_type) = @_;
    
    # Check admin/developer permissions
    unless ($c->check_user_roles(qw/admin developer/)) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->detach('View::JSON');
    }
    
    try {
        # Validate backend type
        unless ($backend_type && ($backend_type eq 'mysql' || $backend_type eq 'sqlite')) {
            $c->response->status(400);
            $c->stash(json => { 
                success => 0, 
                error => "Invalid backend type: " . ($backend_type || 'undefined')
            });
            $c->detach('View::JSON');
        }
        
        # Get HybridDB model
        my $hybrid_db = $c->model('HybridDB');
        
        # Temporarily switch to test backend
        my $original_backend = $hybrid_db->get_backend_type();
        
        if ($backend_type eq 'mysql' && !$hybrid_db->is_mysql_available()) {
            $c->stash(json => { 
                success => 0, 
                error => 'MySQL server is not available',
                connection_test => 0,
            });
            $c->detach('View::JSON');
        }
        
        # Test connection
        $hybrid_db->switch_backend($c, $backend_type);
        my $connection_test = $hybrid_db->test_connection($c);
        
        # Restore original backend
        $hybrid_db->switch_backend($c, $original_backend);
        
        $c->stash(json => {
            success => 1,
            backend_type => $backend_type,
            connection_test => $connection_test,
            message => $connection_test ? 
                "Connection to $backend_type successful" : 
                "Connection to $backend_type failed",
        });
        
        $self->log_with_details($c, 'info', 'Database connection tested', {
            backend_type => $backend_type,
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
            backend_type => $backend_type,
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
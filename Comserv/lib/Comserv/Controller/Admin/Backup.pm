package Comserv::Controller::Admin::Backup;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

use Try::Tiny;
use Comserv::Util::AdminAuth;
use Comserv::Util::BackupManager;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Controller::Admin::Backup - Backup and Restore Management Controller

=head1 DESCRIPTION

Dedicated controller for comprehensive backup and restore functionality.
Provides centralized backup management with proper admin authentication.

=cut

# DO NOT MODIFY - Standardized admin authentication pattern
sub admin_auth {
    my ($self) = @_;
    return Comserv::Util::AdminAuth->new();
}

# DO NOT MODIFY - Standardized logging pattern
sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->new();
}

# DO NOT MODIFY - Standardized backup manager
sub backup_manager {
    my ($self, $c) = @_;
    my $app_dir = $c ? $c->config->{home} : undef;
    return Comserv::Util::BackupManager->new($app_dir ? (app_dir => $app_dir) : ());
}

=head2 auto

Auto method for admin authentication

=cut

sub auto :Private {
    my ($self, $c) = @_;
    
    unless ($self->admin_auth->check_admin_access($c, 'backup_management')) {
        $c->response->redirect($c->uri_for('/login'));
        return 0;
    }
    
    return 1;
}

=head2 index

Main backup management interface

=cut

sub index :Path('/admin/backup') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup_index', 
        "Accessing backup management interface");
    
    # Get backup directory contents
    my $backup_contents = $self->backup_manager($c)->get_backup_directory_contents();
    
    # Get available backups with metadata
    my $available_backups = $self->backup_manager($c)->get_available_backups();
    
    # Check if comserv.psgi exists
    my $backup_manager = $self->backup_manager($c);
    my $app_dir = $backup_manager->app_dir;
    my $psgi_path = $app_dir =~ m{/Comserv$} ? "$app_dir/comserv.psgi" : "$app_dir/Comserv/comserv.psgi";
    my $psgi_exists = -f $psgi_path;
    
    $c->stash(
        template => 'admin/backup/index.tt',
        backup_contents => $backup_contents,
        available_backups => $available_backups,
        psgi_exists => $psgi_exists,
        protected_files => $self->backup_manager($c)->protected_files
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup_index', 
        "Completed backup management interface");
}



=head2 create_backup

Create a new backup

=cut

sub create_backup :Path('/admin/backup_create') :Args(0) {
    my ($self, $c) = @_;
    
    return unless $self->admin_auth->require_admin_access($c, 'create_backup');
    
    if ($c->req->method eq 'POST') {
        my $backup_type = $c->req->param('backup_type') || 'manual';
        my $description = $c->req->param('description') || 'Manual backup';
        my $username = $c->session->{username} || 'unknown';
        
        my $result;
        
        if ($backup_type eq 'protected_files') {
            $result = $self->backup_manager($c)->create_protected_files_backup($username);
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_backup', 
                "Protected files backup result: " . ($result->{success} ? 'SUCCESS' : 'FAILED'));
                
        } else {
            $result = $self->backup_manager($c)->create_manual_backup($description, $username);
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_backup', 
                "Manual backup result: " . ($result->{success} ? 'SUCCESS' : 'FAILED'));
        }
        
        $c->stash(%$result);
        
        # Redirect back to main interface after creation
        if ($result->{success}) {
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }
    }
    
    $c->stash(
        template => 'admin/backup/create.tt',
        protected_files => $self->backup_manager($c)->protected_files
    );
}

=head2 restore_backup

Restore from a specific backup

=cut

sub restore_backup :Path('/admin/backup_restore') :Args(0) {
    my ($self, $c) = @_;
    
    return unless $self->admin_auth->require_admin_access($c, 'restore_backup');
    
    if ($c->req->method eq 'POST') {
        my $backup_path = $c->req->param('backup_path');
        my $target_file = $c->req->param('target_file');
        
        if ($backup_path && $target_file) {
            my $result = $self->backup_manager($c)->restore_file_from_backup($backup_path, $target_file);
            $c->stash(%$result);
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restore_backup', 
                "Backup restore result: " . ($result->{success} ? 'SUCCESS' : 'FAILED') . " - $target_file");
        }
    }
    
    # Get available backups
    my $available_backups = $self->backup_manager($c)->get_available_backups();
    
    $c->stash(
        template => 'admin/backup/restore.tt',
        available_backups => $available_backups
    );
}

=head2 view_backup

View details of a specific backup

=cut

sub view_backup :Path('/admin/backup_view') :Args(1) {
    my ($self, $c, $backup_filename) = @_;
    
    return unless $self->admin_auth->require_admin_access($c, 'view_backup');
    
    my $available_backups = $self->backup_manager($c)->get_available_backups();
    my $backup_info = undef;
    
    for my $backup (@$available_backups) {
        if ($backup->{filename} eq $backup_filename) {
            $backup_info = $backup;
            last;
        }
    }
    
    unless ($backup_info) {
        $c->stash(
            error_msg => "Backup not found: $backup_filename",
            template => 'admin/backup/view.tt'
        );
        return;
    }
    
    $c->stash(
        template => 'admin/backup/view.tt',
        backup_info => $backup_info
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_backup', 
        "Viewed backup details: $backup_filename");
}

=head2 delete_backup

Delete a backup file

=cut

sub delete_backup :Path('/admin/backup_delete') :Args(1) {
    my ($self, $c, $backup_filename) = @_;
    
    return unless $self->admin_auth->require_admin_access($c, 'delete_backup');
    
    if ($c->req->method eq 'POST') {
        my $confirm = $c->req->param('confirm');
        
        if ($confirm eq 'yes') {
            my $backup_dir = $self->backup_manager($c)->backup_dirs->[1];  # Use /Comserv/backups
            my $backup_path = "$backup_dir/$backup_filename";
            my $meta_path = "$backup_path.meta";
            
            my $result = {
                success => 0,
                message => '',
                output => ''
            };
            
            if (-f $backup_path) {
                if (unlink($backup_path)) {
                    $result->{output} .= "Deleted backup file: $backup_filename\n";
                    
                    # Also delete metadata file if it exists
                    if (-f $meta_path && unlink($meta_path)) {
                        $result->{output} .= "Deleted metadata file: $backup_filename.meta\n";
                    }
                    
                    $result->{success} = 1;
                    $result->{message} = "Backup deleted successfully";
                    $result->{success_msg} = "Backup '$backup_filename' has been deleted.";
                    
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_backup', 
                        "Successfully deleted backup: $backup_filename");
                        
                } else {
                    $result->{message} = "Failed to delete backup file";
                    $result->{error_msg} = "Could not delete backup file: $!";
                    
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_backup', 
                        "Failed to delete backup: $backup_filename - $!");
                }
            } else {
                $result->{message} = "Backup file not found";
                $result->{error_msg} = "Backup file does not exist: $backup_filename";
            }
            
            $c->stash(%$result);
            
            # Redirect back to main interface after deletion
            if ($result->{success}) {
                $c->response->redirect($c->uri_for('/admin/backup'));
                return;
            }
        }
    }
    
    $c->stash(
        template => 'admin/backup/delete.tt',
        backup_filename => $backup_filename
    );
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Comserv Development Team

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2025 by Comserv Development Team

=cut
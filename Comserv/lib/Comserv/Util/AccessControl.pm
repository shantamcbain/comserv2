package Comserv::Util::AccessControl;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::AccessControl - Enhanced access control utilities for multi-site architecture

=head1 DESCRIPTION

This module provides enhanced access control methods that support site-specific
permissions while maintaining backward compatibility with the existing role system.

=cut

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

=head2 check_user_roles_enhanced

Enhanced version of check_user_roles that supports site-specific permissions.

Usage:
  $c->check_user_roles_enhanced('admin')                    # Global admin check
  $c->check_user_roles_enhanced('admin', $site_id)         # Site-specific admin check
  $c->check_user_roles_enhanced('site_admin', $site_id)    # Site admin check

=cut

sub check_user_roles_enhanced {
    my ($self, $c, $role, $site_id) = @_;
    
    # First check if user exists
    return 0 unless $c->user_exists;
    
    my $username = $c->session->{username} || 'unknown';
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'check_user_roles_enhanced',
        "Checking role '$role' for user '$username'" . (defined $site_id ? " on site $site_id" : " globally"));
    
    # For CSC users, check hardcoded usernames first (most reliable)
    if ($self->is_csc_user($c)) {
        # CSC users have all admin privileges
        if ($role eq 'admin' || $role eq 'csc_admin' || $role eq 'super_admin' || $role eq 'backup_admin') {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'check_user_roles_enhanced',
                "CSC user '$username' granted '$role' access via hardcoded check");
            return 1;
        }
        # CSC users can access any site admin
        if ($role eq 'site_admin' && defined $site_id) {
            return 1;
        }
    }
    
    # Try to get user object from database for enhanced role checking
    my $user;
    eval {
        $user = $self->get_user_object($c);
    };
    
    if ($@ || !$user) {
        # Database access failed - use fallback for critical roles
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'check_user_roles_enhanced',
            "Database access failed, using fallback role checking: " . ($@ || 'user object not found'));
        
        # For backup-related roles, ensure CSC users can still access
        if ($role eq 'backup_admin' || $role eq 'csc_admin' || $role eq 'super_admin') {
            return $self->is_csc_user($c);
        }
        
        # For admin roles, check legacy admin role
        if ($role eq 'admin') {
            return $self->check_legacy_admin_role($c) || $self->is_csc_user($c);
        }
        
        # For other roles, use legacy checking
        return $self->check_legacy_role($c, $role);
    }
    
    # Database access successful - use enhanced role checking
    eval {
        # Handle different role types
        if ($role eq 'admin') {
            # Admin role can be global or site-specific
            if (defined $site_id) {
                # Site-specific admin check
                return 1 if $user->can_access_site_admin($site_id);
            } else {
                # Global admin check - includes CSC admins and legacy admin role
                return 1 if $user->is_csc_admin;
                return 1 if $self->check_legacy_admin_role($c);
            }
        }
        elsif ($role eq 'csc_admin' || $role eq 'super_admin') {
            # CSC/Super admin roles are always global
            return 1 if $user->is_csc_admin;
        }
        elsif ($role eq 'backup_admin') {
            # Backup management is CSC-only
            return 1 if $user->can_manage_backups;
        }
        elsif ($role =~ /^site_(.+)$/) {
            # Site-specific roles (site_admin, site_user, etc.)
            return 0 unless defined $site_id;
            return 1 if $user->has_site_role($site_id, $role);
        }
        else {
            # Other roles - check both global and site-specific
            if (defined $site_id) {
                return 1 if $user->has_site_role($site_id, $role);
            }
            return 1 if $user->has_global_role($role);
            
            # Fallback to legacy role checking
            return 1 if $self->check_legacy_role($c, $role);
        }
    };
    
    if ($@) {
        # Enhanced role checking failed - use fallback
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'check_user_roles_enhanced',
            "Enhanced role checking failed, using fallback: $@");
        
        # For backup-related roles, ensure CSC users can still access
        if ($role eq 'backup_admin' || $role eq 'csc_admin' || $role eq 'super_admin') {
            return $self->is_csc_user($c);
        }
        
        # For admin roles, check legacy admin role
        if ($role eq 'admin') {
            return $self->check_legacy_admin_role($c) || $self->is_csc_user($c);
        }
        
        # For other roles, use legacy checking
        return $self->check_legacy_role($c, $role);
    }
    
    return 0;
}

=head2 get_user_site_context

Get the current site context for the user session.

=cut

sub get_user_site_context {
    my ($self, $c) = @_;
    
    # Try to get site context from various sources
    my $site_id = $c->session->{current_site_id} 
                || $c->stash->{site_id}
                || $c->req->param('site_id');
    
    # If no explicit site context, try to determine from domain/URL
    unless ($site_id) {
        my $host = $c->req->header('Host') || '';
        $host =~ s/:\d+$//; # Remove port if present
        
        if ($host) {
            my $site_domain = $c->model('Site')->get_site_domain($c, $host);
            $site_id = $site_domain->site_id if $site_domain;
        }
    }
    
    return $site_id;
}

=head2 set_user_site_context

Set the site context for the current user session.

=cut

sub set_user_site_context {
    my ($self, $c, $site_id) = @_;
    
    return unless defined $site_id;
    
    $c->session->{current_site_id} = $site_id;
    $c->stash->{site_id} = $site_id;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_user_site_context',
        "Set site context to $site_id for user " . ($c->session->{username} || 'unknown'));
}

=head2 get_user_accessible_sites

Get list of sites the current user can access.

=cut

sub get_user_accessible_sites {
    my ($self, $c) = @_;
    
    return [] unless $c->user_exists;
    
    my $user = $self->get_user_object($c);
    return [] unless $user;
    
    # CSC admins can access all sites
    if ($user->is_csc_admin) {
        my $all_sites = $c->model('Site')->get_all_sites($c);
        return $all_sites || [];
    }
    
    # Get sites where user has specific roles
    my @site_roles = $user->user_site_roles->search({
        is_active => 1,
        -or => [
            expires_at => undef,
            expires_at => { '>' => \'NOW()' }
        ]
    });
    
    my @accessible_sites;
    my %seen_sites;
    
    foreach my $site_role (@site_roles) {
        next unless $site_role->site_id;
        next if $seen_sites{$site_role->site_id};
        
        my $site = $site_role->site;
        if ($site) {
            push @accessible_sites, $site;
            $seen_sites{$site_role->site_id} = 1;
        }
    }
    
    return \@accessible_sites;
}

=head2 grant_site_role

Grant a site-specific role to a user.

=cut

sub grant_site_role {
    my ($self, $c, $user_id, $site_id, $role, $granted_by_user_id, $expires_at) = @_;
    
    return 0 unless $user_id && $site_id && $role;
    
    # Check if granting user has permission to grant this role
    my $granting_user = $self->get_user_object($c);
    return 0 unless $granting_user && $granting_user->can_access_site_admin($site_id);
    
    eval {
        my $user_site_role = $c->model('DBEncy::UserSiteRole')->create({
            user_id => $user_id,
            site_id => $site_id,
            role => $role,
            granted_by => $granted_by_user_id,
            expires_at => $expires_at,
            is_active => 1,
        });
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'grant_site_role',
            "Granted role '$role' to user $user_id on site $site_id");
        
        return 1;
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'grant_site_role',
            "Error granting role: $@");
        return 0;
    }
    
    return 1;
}

=head2 revoke_site_role

Revoke a site-specific role from a user.

=cut

sub revoke_site_role {
    my ($self, $c, $user_id, $site_id, $role) = @_;
    
    return 0 unless $user_id && $site_id && $role;
    
    # Check if revoking user has permission
    my $revoking_user = $self->get_user_object($c);
    return 0 unless $revoking_user && $revoking_user->can_access_site_admin($site_id);
    
    eval {
        my $user_site_role = $c->model('DBEncy::UserSiteRole')->search({
            user_id => $user_id,
            site_id => $site_id,
            role => $role,
            is_active => 1,
        })->first;
        
        if ($user_site_role) {
            $user_site_role->update({ is_active => 0 });
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'revoke_site_role',
                "Revoked role '$role' from user $user_id on site $site_id");
            
            return 1;
        }
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'revoke_site_role',
            "Error revoking role: $@");
        return 0;
    }
    
    return 0;
}

# Private helper methods

sub get_user_object {
    my ($self, $c) = @_;
    
    return unless $c->user_exists;
    
    my $user_id = $c->session->{user_id};
    return unless $user_id;
    
    # Try to get user object with comprehensive error handling
    my $user;
    eval {
        # First check if the model exists
        my $user_model = $c->model('DBEncy::User');
        die "User model not available" unless $user_model;
        
        # Try to find the user
        $user = $user_model->find($user_id);
        
        # If user found, test if we can access the enhanced fields
        if ($user) {
            # Test access to enhanced role methods to ensure schema compatibility
            eval {
                # These calls will fail if the schema doesn't support enhanced roles
                $user->has_global_role('test');
                $user->is_csc_admin();
            };
            if ($@) {
                # Schema doesn't support enhanced roles - use fallback for CSC users
                if ($self->is_csc_user($c)) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_user_object',
                        "Schema incompatible with enhanced roles, using session fallback for CSC user");
                    return $self->create_session_user_object($c);
                }
                # For non-CSC users, return the basic user object
                return $user;
            }
        }
    };
    
    if ($@) {
        # Database error - log it and use fallback for CSC users
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_user_object',
            "Database error accessing user: $@");
        
        # For CSC users, allow fallback to session-based checking
        if ($self->is_csc_user($c)) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_user_object',
                "Using session fallback for CSC user due to database error");
            return $self->create_session_user_object($c);
        }
        
        return;
    }
    
    return $user;
}

sub check_legacy_admin_role {
    my ($self, $c) = @_;
    
    # Check legacy admin role from session
    my $roles = $c->session->{roles};
    
    if (ref($roles) eq 'ARRAY') {
        return 1 if grep { lc($_) eq 'admin' } @$roles;
    }
    elsif (defined $roles && !ref($roles)) {
        return 1 if $roles =~ /\badmin\b/i;
    }
    
    # Check user_groups for admin
    my $user_groups = $c->session->{user_groups};
    if (ref($user_groups) eq 'ARRAY') {
        return 1 if grep { lc($_) eq 'admin' } @$user_groups;
    }
    elsif (defined $user_groups && !ref($user_groups)) {
        return 1 if $user_groups =~ /\badmin\b/i;
    }
    
    return 0;
}

sub check_legacy_role {
    my ($self, $c, $role) = @_;
    
    # Check legacy roles from session
    my $roles = $c->session->{roles};
    
    if (ref($roles) eq 'ARRAY') {
        return 1 if grep { lc($_) eq lc($role) } @$roles;
    }
    elsif (defined $roles && !ref($roles)) {
        return 1 if $roles =~ /\b\Q$role\E\b/i;
    }
    
    return 0;
}

# Helper method to check if user is CSC admin based on session only
sub is_csc_user {
    my ($self, $c) = @_;
    
    return 0 unless $c->user_exists;
    
    my $username = $c->session->{username} || '';
    
    # Check hardcoded CSC usernames
    my @csc_users = qw(shanta csc_admin backup_admin);
    return 1 if grep { lc($_) eq lc($username) } @csc_users;
    
    # Check session roles for admin
    return 1 if $self->check_legacy_admin_role($c);
    
    return 0;
}

# Create a minimal user object from session data for fallback
sub create_session_user_object {
    my ($self, $c) = @_;
    
    return unless $c->user_exists;
    
    # Create a simple hash-based object that mimics the User model methods
    my $session_user = {
        id => $c->session->{user_id},
        username => $c->session->{username},
        roles => $c->session->{roles} || '',
        _is_session_fallback => 1,
    };
    
    # Add methods to the hash reference
    bless $session_user, 'Comserv::Util::AccessControl::SessionUser';
    
    return $session_user;
}

__PACKAGE__->meta->make_immutable;

# Fallback SessionUser class for when database schema is incompatible
package Comserv::Util::AccessControl::SessionUser;

sub new {
    my ($class, $data) = @_;
    return bless $data, $class;
}

sub id { return $_[0]->{id}; }
sub username { return $_[0]->{username}; }
sub roles { return $_[0]->{roles}; }

sub has_global_role {
    my ($self, $role) = @_;
    
    return 0 unless $role && $self->roles;
    
    # Simple role checking for fallback
    my @roles = split(/,/, $self->roles);
    return 1 if grep { lc(trim($_)) eq lc($role) } @roles;
    
    return 0;
}

sub has_site_role {
    my ($self, $site_id, $role) = @_;
    
    # In fallback mode, treat admin as having access to all sites
    return 1 if $self->has_global_role('admin') && $role eq 'site_admin';
    
    return 0;
}

sub is_csc_admin {
    my ($self) = @_;
    
    # Check hardcoded CSC usernames
    my @csc_users = qw(shanta csc_admin backup_admin);
    return 1 if grep { lc($_) eq lc($self->username) } @csc_users;
    
    # Check admin role
    return 1 if $self->has_global_role('admin');
    
    return 0;
}

sub can_access_site_admin {
    my ($self, $site_id) = @_;
    
    return $self->is_csc_admin;
}

sub can_manage_backups {
    my ($self) = @_;
    
    return $self->is_csc_admin;
}

sub trim {
    my $str = shift;
    return '' unless defined $str;
    $str =~ s/^\s+|\s+$//g;
    return $str;
}

1;

=head1 ROLE HIERARCHY

The new role system supports the following hierarchy:

=head2 Global Roles

=over 4

=item * super_admin - Full system access across all sites and CSC functions

=item * csc_admin - CSC hosting administrator with backup access and multi-site admin

=item * admin - Legacy admin role (backward compatibility)

=back

=head2 Site-Specific Roles

=over 4

=item * site_admin - Administrative access to a specific site

=item * site_user - Regular user access to a specific site

=item * site_viewer - Read-only access to a specific site

=back

=head1 MIGRATION STRATEGY

1. Existing users with 'admin' role will continue to work via legacy compatibility
2. CSC users (shanta, etc.) automatically get super_admin privileges
3. New site-specific roles can be granted incrementally
4. Backup functionality remains CSC-only

=cut
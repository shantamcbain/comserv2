package Comserv::Model::Schema::Ency::Result::User;
use base 'DBIx::Class::Core';

__PACKAGE__->table('users');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    username => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    password => {
        data_type => 'varchar',
        size => 255,
    },
    first_name => {
        data_type => 'varchar',
        size => 255,
    },
    last_name => {
        data_type => 'varchar',
        size => 255,
    },
    email => {
        data_type => 'varchar',
        size => 255,
    },
    roles => {
        data_type => 'text',
        is_nullable => 1,
        # Enhanced to support both global and site-specific roles
        # Format: "admin,user" or "global:super_admin,site:123:site_admin"
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('username_unique' => ['username']);

# Relationships
__PACKAGE__->has_many(
    user_site_roles => 'Comserv::Model::Schema::Ency::Result::UserSiteRole',
    'user_id'
);

__PACKAGE__->has_many(
    user_sites => 'Comserv::Model::Schema::Ency::Result::UserSite',
    'user_id'
);

# Enhanced helper methods for role checking with backward compatibility
sub has_global_role {
    my ($self, $role) = @_;
    
    return 0 unless $role;
    
    # Parse roles field for both legacy and enhanced formats
    return $self->_parse_roles_field('global', undef, $role);
}

sub has_site_role {
    my ($self, $site_id, $role) = @_;
    
    return 0 unless defined $site_id && $role;
    
    # First check the enhanced roles field format
    if ($self->_parse_roles_field('site', $site_id, $role)) {
        return 1;
    }
    
    # Then check UserSiteRole table if it exists
    eval {
        my $site_role = $self->user_site_roles->search({
            site_id => $site_id,
            role => $role,
            is_active => 1,
            -or => [
                expires_at => undef,
                expires_at => { '>' => \'NOW()' }
            ]
        })->first;
        
        return 1 if $site_role;
    };
    # Ignore errors if UserSiteRole table doesn't exist yet
    
    return 0;
}

sub get_site_roles {
    my ($self, $site_id) = @_;
    
    return [] unless defined $site_id;
    
    my @roles;
    
    # Get roles from enhanced roles field
    push @roles, @{$self->_get_site_roles_from_field($site_id)};
    
    # Get roles from UserSiteRole table if it exists
    eval {
        my @db_roles = $self->user_site_roles->search({
            site_id => $site_id,
            is_active => 1,
            -or => [
                expires_at => undef,
                expires_at => { '>' => \'NOW()' }
            ]
        })->get_column('role')->all;
        
        push @roles, @db_roles;
    };
    # Ignore errors if table doesn't exist
    
    # Remove duplicates
    my %seen;
    @roles = grep { !$seen{$_}++ } @roles;
    
    return \@roles;
}

sub is_csc_admin {
    my ($self) = @_;
    
    # Check for CSC-level administrative roles in enhanced format
    return 1 if $self->has_global_role('super_admin');
    return 1 if $self->has_global_role('csc_admin');
    
    # Check legacy admin role
    return 1 if $self->has_global_role('admin');
    
    # Check hardcoded CSC usernames for backward compatibility
    my @csc_users = qw(shanta csc_admin backup_admin);
    return 1 if grep { lc($_) eq lc($self->username) } @csc_users;
    
    return 0;
}

sub can_access_site_admin {
    my ($self, $site_id) = @_;
    
    # CSC admins can access any site
    return 1 if $self->is_csc_admin;
    
    # Check site-specific admin roles
    return 1 if $self->has_site_role($site_id, 'site_admin');
    
    # Check legacy admin role (backward compatibility)
    return 1 if $self->has_global_role('admin');
    
    return 0;
}

sub can_manage_backups {
    my ($self) = @_;
    
    # Only CSC admins can manage backups
    return $self->is_csc_admin;
}

# Private helper methods
sub _parse_roles_field {
    my ($self, $scope, $site_id, $target_role) = @_;
    
    return 0 unless $self->roles;
    
    my $roles_text = $self->roles;
    
    # Handle enhanced format: "global:super_admin,site:123:site_admin,admin"
    if ($roles_text =~ /(?:global|site):/i) {
        my @role_parts = split(/,/, $roles_text);
        
        foreach my $part (@role_parts) {
            $part = trim($part);
            
            if ($scope eq 'global') {
                # Check for global:role_name format
                if ($part =~ /^global:(.+)$/i) {
                    return 1 if lc($1) eq lc($target_role);
                }
                # Also check plain role names (legacy compatibility)
                elsif ($part !~ /:/ && lc($part) eq lc($target_role)) {
                    return 1;
                }
            }
            elsif ($scope eq 'site' && defined $site_id) {
                # Check for site:site_id:role_name format
                if ($part =~ /^site:(\d+):(.+)$/i) {
                    return 1 if $1 == $site_id && lc($2) eq lc($target_role);
                }
            }
        }
    }
    else {
        # Legacy format: simple comma-separated roles
        if ($scope eq 'global') {
            my @legacy_roles = split(/,/, $roles_text);
            return 1 if grep { lc(trim($_)) eq lc($target_role) } @legacy_roles;
        }
    }
    
    return 0;
}

sub _get_site_roles_from_field {
    my ($self, $site_id) = @_;
    
    my @roles;
    return \@roles unless $self->roles;
    
    my $roles_text = $self->roles;
    
    if ($roles_text =~ /site:/i) {
        my @role_parts = split(/,/, $roles_text);
        
        foreach my $part (@role_parts) {
            $part = trim($part);
            
            if ($part =~ /^site:(\d+):(.+)$/i && $1 == $site_id) {
                push @roles, $2;
            }
        }
    }
    
    return \@roles;
}

# Utility function to trim whitespace
sub trim {
    my $str = shift;
    return '' unless defined $str;
    $str =~ s/^\s+|\s+$//g;
    return $str;
}

1;

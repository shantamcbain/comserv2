package Comserv::Model::User;
                use Moose;
                use namespace::autoclean;
                use Email::Sender::Simple qw(sendmail);
                use Email::Sender::Transport::SMTP qw();
                use Email::Simple;
                use Email::Simple::Creator;
                use Comserv::Util::Logging;
                extends 'Catalyst::Model', 'Catalyst::Authentication::User';

                has '_user' => (
                    is => 'ro',
                    lazy => 1,
                    default => sub {
                        die "_user attribute must be set before it's used";
                    },
                );

                sub get_object {
                    my $self = shift;
                    return $self->_user;
                }

                sub for_session {
                    my $self = shift;
                    return $self->_user->id;
                }

                sub from_session {
                    my ($self, $c, $id) = @_;
                    return $self->new(_user => $c->model('DBEncy::User')->find($id));
                }

                sub supports {
                    my ($self, $feature) = @_;
                    return 1 if $feature eq 'session';
                    return 0;
                }

                sub roles {
                    my $self = shift;
                    my $roles = $self->_user->roles;
                    
                    # Log the raw roles value for debugging
                    warn "DEBUG: User roles raw value: " . (defined $roles ? "'$roles'" : "undefined") . 
                         ", type: " . (defined $roles ? (ref $roles || "string") : "undefined") . 
                         ", username: " . $self->_user->username;
                    
                    # TEMPORARY FIX: Ensure Shanta has admin role
                    if ($self->_user->username eq 'Shanta') {
                        warn "DEBUG: Ensuring admin role for user Shanta";
                        return ['admin', 'user'];
                    }
                    
                    # Handle different role formats
                    if (!defined $roles) {
                        warn "DEBUG: No roles defined, returning default ['user']";
                        return ['user']; # Default role if none defined
                    } elsif (!ref $roles) {
                        # If roles is a string, split it by commas or spaces
                        if ($roles =~ /,/) {
                            my @role_array = split(/\s*,\s*/, $roles);
                            warn "DEBUG: Split comma-separated roles into: [" . join(", ", @role_array) . "]";
                            return \@role_array;
                        } else {
                            warn "DEBUG: Single role string: '$roles', returning [$roles]";
                            return [$roles]; # Single role as string
                        }
                    } elsif (ref $roles eq 'ARRAY') {
                        warn "DEBUG: Roles is already an array reference: [" . join(", ", @$roles) . "]";
                        return $roles; # Already an array reference
                    } else {
                        # Unexpected format, log and return default
                        warn "DEBUG: Unexpected roles format: " . (ref $roles || 'undefined') . ", returning default ['user']";
                        return ['user'];
                    }
                }

                sub create_user {
                    my ($self, $user_data) = @_;
                    my $schema = Comserv::Model::DBEncy->new->schema;
                    my $existing_user = $schema->resultset('User')->find({ username => $user_data->{username} });
                    return "Username already exists" if $existing_user;
                    my $new_user = $schema->resultset('User')->create({
                        %$user_data,
                        roles => $user_data->{roles} // 'default_role',
                    });
                    return $new_user;
                }
                
                sub delete_user {
                    my ($self, $user_id) = @_;
                    my $schema = Comserv::Model::DBEncy->new->schema;
                    my $user = $schema->resultset('User')->find($user_id);
                    
                    return "User not found" unless $user;
                    
                    # Delete the user
                    $user->delete;
                    
                    return 1; # Success
                }

                # User-Site Relationship Helper Methods
                sub has_site_access {
                    my ($self, $user_obj, $site_id) = @_;
                    
                    return 0 unless defined $site_id && $user_obj;
                    
                    # CSC admins have access to all sites
                    return 1 if $self->is_csc_admin($user_obj);
                    
                    # Check if user has explicit site access via UserSite table
                    my $schema = Comserv::Model::DBEncy->new->schema;
                    my $user_site = $schema->resultset('UserSite')->search({
                        user_id => $user_obj->id,
                        site_id => $site_id
                    })->first;
                    return 1 if $user_site;
                    
                    # Check if user has any active role on this site
                    my $site_role = $schema->resultset('UserSiteRole')->search({
                        user_id => $user_obj->id,
                        site_id => $site_id,
                        is_active => 1,
                        -or => [
                            expires_at => undef,
                            expires_at => { '>' => \'NOW()' }
                        ]
                    })->first;
                    
                    return $site_role ? 1 : 0;
                }

                sub get_accessible_sites {
                    my ($self, $user_obj) = @_;
                    
                    return [] unless $user_obj;
                    
                    my $schema = Comserv::Model::DBEncy->new->schema;
                    
                    # CSC admins can access all sites
                    if ($self->is_csc_admin($user_obj)) {
                        # Return all active sites from Project table
                        eval {
                            my @all_sites = $schema->resultset('Project')->search(
                                { is_active => 1 },
                                { order_by => 'name' }
                            )->all;
                            return \@all_sites;
                        };
                        # If Project table doesn't exist or error, return empty array
                        return [];
                    }
                    
                    # Get sites user has explicit access to
                    my @accessible_sites;
                    
                    # From UserSite relationships
                    my @user_sites = $schema->resultset('UserSite')->search(
                        { user_id => $user_obj->id },
                        { 
                            join => 'site',
                            prefetch => 'site',
                            order_by => 'site.name'
                        }
                    )->all;
                    
                    push @accessible_sites, map { $_->site } @user_sites;
                    
                    # From UserSiteRole relationships (additional sites)
                    my @role_sites = $schema->resultset('UserSiteRole')->search(
                        {
                            user_id => $user_obj->id,
                            site_id => { '!=' => undef },
                            is_active => 1,
                            -or => [
                                expires_at => undef,
                                expires_at => { '>' => \'NOW()' }
                            ]
                        },
                        {
                            join => 'site',
                            prefetch => 'site',
                            order_by => 'site.name'
                        }
                    )->all;
                    
                    push @accessible_sites, map { $_->site } @role_sites;
                    
                    # Remove duplicates
                    my %seen;
                    @accessible_sites = grep { !$seen{$_->id}++ } @accessible_sites;
                    
                    return \@accessible_sites;
                }

                sub add_site_access {
                    my ($self, $user_obj, $site_id, $role, $granted_by_user_id) = @_;
                    
                    return 0 unless defined $site_id && $user_obj;
                    
                    eval {
                        my $schema = Comserv::Model::DBEncy->new->schema;
                        
                        # Create UserSite entry if it doesn't exist
                        my $user_site = $schema->resultset('UserSite')->find_or_create({
                            user_id => $user_obj->id,
                            site_id => $site_id,
                        });
                        
                        # Create or update UserSiteRole entry
                        if ($role) {
                            my $user_site_role = $schema->resultset('UserSiteRole')->find_or_create({
                                user_id => $user_obj->id,
                                site_id => $site_id,
                                role => $role,
                            }, {
                                granted_by => $granted_by_user_id,
                                is_active => 1,
                            });
                        }
                        
                        return 1;
                    };
                    
                    return 0;  # Error occurred
                }

                sub remove_site_access {
                    my ($self, $user_obj, $site_id) = @_;
                    
                    return 0 unless defined $site_id && $user_obj;
                    
                    eval {
                        my $schema = Comserv::Model::DBEncy->new->schema;
                        
                        # Remove UserSite entry
                        $schema->resultset('UserSite')->search({
                            user_id => $user_obj->id,
                            site_id => $site_id,
                        })->delete;
                        
                        # Deactivate UserSiteRole entries
                        $schema->resultset('UserSiteRole')->search({
                            user_id => $user_obj->id,
                            site_id => $site_id,
                        })->update({ is_active => 0 });
                        
                        return 1;
                    };
                    
                    return 0;  # Error occurred
                }

                sub get_primary_site {
                    my ($self, $user_obj) = @_;
                    
                    return undef unless $user_obj;
                    
                    my $schema = Comserv::Model::DBEncy->new->schema;
                    
                    # Get the first site the user has access to
                    my $user_site = $schema->resultset('UserSite')->search(
                        { user_id => $user_obj->id },
                        { 
                            join => 'site',
                            prefetch => 'site',
                            order_by => 'site.name',
                            rows => 1
                        }
                    )->first;
                    
                    return $user_site ? $user_site->site : undef;
                }

                sub is_csc_admin {
                    my ($self, $user_obj) = @_;
                    
                    return 0 unless $user_obj;
                    
                    # Check for CSC-level administrative roles in enhanced format
                    return 1 if $self->has_global_role($user_obj, 'super_admin');
                    return 1 if $self->has_global_role($user_obj, 'csc_admin');
                    
                    # Check legacy admin role
                    return 1 if $self->has_global_role($user_obj, 'admin');
                    
                    # Check hardcoded CSC usernames for backward compatibility
                    my @csc_users = qw(shanta csc_admin backup_admin);
                    return 1 if grep { lc($_) eq lc($user_obj->username) } @csc_users;
                    
                    return 0;
                }

                sub has_global_role {
                    my ($self, $user_obj, $role) = @_;
                    
                    return 0 unless $role && $user_obj;
                    
                    # Parse roles field for both legacy and enhanced formats
                    return $self->_parse_roles_field($user_obj, 'global', undef, $role);
                }

                sub _parse_roles_field {
                    my ($self, $user_obj, $scope, $site_id, $target_role) = @_;
                    
                    return 0 unless $user_obj->roles;
                    
                    my $roles_text = $user_obj->roles;
                    
                    # Handle enhanced format: "global:super_admin,site:123:site_admin,admin"
                    if ($roles_text =~ /(?:global|site):/i) {
                        my @role_parts = split(/,/, $roles_text);
                        
                        foreach my $part (@role_parts) {
                            $part = $self->trim($part);
                            
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
                            return 1 if grep { lc($self->trim($_)) eq lc($target_role) } @legacy_roles;
                        }
                    }
                    
                    return 0;
                }

                # Utility function to trim whitespace
                sub trim {
                    my ($self, $str) = @_;
                    return '' unless defined $str;
                    $str =~ s/^\s+|\s+$//g;
                    return $str;
                }

                __PACKAGE__->meta->make_immutable;
                1;
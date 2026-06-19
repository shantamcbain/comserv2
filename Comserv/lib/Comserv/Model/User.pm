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
                    return $self->new(_user => $c->model('DBEncy')->resultset('User')->find($id));
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
                    my ($self, $c, $user_data) = @_;
                    
                    # Context Safety Net: Ensure $c is a blessed object with a model method.
                    # If not, we fall back to a cached schema to prevent "unblessed reference" crashes.
                    my $db = eval { $c->model('DBEncy') } if (ref $c && $c->can('model'));
                    unless ($db) {
                        require Comserv::Util::Logging;
                        my $log = Comserv::Util::Logging->instance;
                        $log->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_user', 
                            "Invalid context passed to create_user; falling back to cached schema.");
                        
                        # Fallback to a singleton-like schema if $c is missing or broken
                        eval {
                            require Comserv::Model::Schema::Ency;
                            my $schema = Comserv::Model::Schema::Ency->new;
                            $db = $schema;
                        };
                    }
                    
                    my $existing_user = $db->resultset('User')->find({ username => $user_data->{username} });
                    return "Username already exists" if $existing_user;
                    my $new_user_row = $db->resultset('User')->create({
                        %$user_data,
                        roles => $user_data->{roles} // 'default_role',
                    });
                    # Return a properly blessed Comserv::Model::User wrapper so callers
                    # (and the auth system) can use it like $c->user without "unblessed reference" errors.
                    return $self->new(_user => $new_user_row);
                }
                
                sub delete_user {
                    my ($self, $c, $user_id) = @_;
                    my $user = $c->model('DBEncy')->resultset('User')->find($user_id);
                    
                    return "User not found" unless $user;
                    
                    # Delete the user
                    $user->delete;
                    
                    return 1; # Success
                }

                __PACKAGE__->meta->make_immutable;
                1;
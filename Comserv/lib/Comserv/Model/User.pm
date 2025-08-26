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

                __PACKAGE__->meta->make_immutable;
                1;
package Comserv::View::Email::Template;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

# Array to store debug messages
has '_debug_msgs' => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { [] }
);

# Helper method to add debug messages
sub add_debug_msg {
    my ($self, $msg) = @_;
    push @{$self->_debug_msgs}, $msg;
    return;
}

has '_app_logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN {
    # Try to load the real module
    eval {
        require Catalyst::View::Email::Template;
    };
    
    if ($@) {
        # If we can't load the module, we'll create a minimal implementation
        warn "Cannot load Catalyst::View::Email::Template: $@\n";
        warn "Using minimal implementation instead.\n";
    } else {
        # If we can load the module, extend it
        extends 'Catalyst::View::Email::Template';
        
        # Override process method to add debugging and fallback
        # ONLY when the parent class is successfully loaded
        around 'process' => sub {
            my ($orig, $self, $c, $args) = @_;
            
            # Store debug messages in stash for debugging
            $c->stash->{debug_msg} = $self->_debug_msgs;
            
            # Log with details for debugging
            $self->log_with_details($c, "Processing email template request", {
                to => $args->{to},
                subject => $args->{subject},
                template => $args->{template},
            });
            
            # If we're using the real module, try to use it
            if ($self->can($orig)) {
                eval {
                    $self->add_debug_msg("Attempting to send email using Catalyst::View::Email::Template");
                    return $self->$orig($c, $args);
                };
                if ($@) {
                    my $error = "$@";
                    $self->_app_logging->log_with_details($c, 'error', __FILE__, __LINE__, 'Email::Template',
                        "SMTP send failed (Catalyst::View::Email::Template): $error");
                    $self->add_debug_msg("Failed to send email: $error");
                    # Fall through to the fallback/log-only implementation
                } else {
                    $self->_app_logging->log_with_details($c, 'info', __FILE__, __LINE__, 'Email::Template',
                        "SMTP send OK via Catalyst::View::Email::Template to=" . ($args->{to} || '?'));
                    return 1;
                }
            } else {
                $self->_app_logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'Email::Template',
                    "EMAIL NOT SENT - Catalyst::View::Email::Template not installed. Running in log-only mode.");
                $self->add_debug_msg("Email template functionality not available: Catalyst::View::Email::Template not installed");
            }

            # Fallback: log-only mode — email is NOT actually sent
            $self->_app_logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'Email::Template',
                "LOG-ONLY MODE: to=" . ($args->{to} || '?') .
                " subject=" . ($args->{subject} || '?') .
                " template=" . ($args->{template} || '?'));

            # Return 0 so caller knows email was NOT sent
            return 0;
        };
    }
}

# Configuration - only set if the module can accept it
# (i.e., when Catalyst::View::Email::Template successfully loaded)
if (__PACKAGE__->can('config')) {
    __PACKAGE__->config(
        template_prefix => 'email',
        render_params => {
            INCLUDE_PATH => [
                eval { Comserv->path_to('root') } || 'root',
            ],
            WRAPPER => 'email/wrapper.tt',
        },
        sender => {
            mailer => 'SMTP',
            mailer_args => {
                host => 'localhost',
                port => 25,
            }
        },
        default => {
            content_type => 'text/html',
            charset => 'UTF-8',
        }
    );
}

__PACKAGE__->meta->make_immutable;

=head1 NAME

Comserv::View::Email::Template - TT View for Comserv

=head1 DESCRIPTION

View for sending template-based emails from Comserv

=head1 AUTHOR

Shanta

=head1 SEE ALSO

L<Comserv>

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
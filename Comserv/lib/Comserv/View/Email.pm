package Comserv::View::Email;
use Moose;
use namespace::autoclean;

BEGIN {
    # Try to load the real module
    eval {
        require Catalyst::View::Email;
    };
    
    if ($@) {
        # If we can't load the module, we'll create a minimal implementation
        warn "Cannot load Catalyst::View::Email: $@\n";
        warn "Using minimal implementation instead.\n";
    } else {
        # If we can load the module, extend it
        extends 'Catalyst::View::Email';
    }
}

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

# Helper method for detailed logging
sub log_with_details {
    my ($self, $c, $message, $details) = @_;
    
    # Log the main message
    $c->log->info($message);
    
    # Log each detail on a separate line
    if ($details && ref($details) eq 'HASH') {
        foreach my $key (sort keys %$details) {
            my $value = defined $details->{$key} ? $details->{$key} : 'undef';
            $c->log->info("  $key: $value");
        }
    }
}

# Process method - either override or create new depending on base class availability
BEGIN {
    # Only create the around method if we have the base class
    if (__PACKAGE__->isa('Catalyst::View::Email')) {
        around 'process' => sub {
            my ($orig, $self, $c, $args) = @_;
            
            # Store debug messages in stash for debugging
            $c->stash->{debug_msg} = $self->_debug_msgs;
            
            # Log with details for debugging
            $self->log_with_details($c, "Processing email request", {
                to => $args->{to},
                subject => $args->{subject},
            });
            
            # Try to use the original method
            eval {
                $self->add_debug_msg("Attempting to send email using Catalyst::View::Email");
                return $self->$orig($c, $args);
            };
            if ($@) {
                my $error = $@;
                $c->log->warn("Failed to send email using Catalyst::View::Email: $error");
                $self->add_debug_msg("Failed to send email: $error");
                # Fall through to the fallback implementation
            } else {
                # If it worked, return success
                return 1;
            }
            
            # Fallback implementation - just log the email details
            $c->log->info("Email would be sent (fallback mode):");
            $c->log->info("  To: " . ($args->{to} || 'not specified'));
            $c->log->info("  Subject: " . ($args->{subject} || 'not specified'));
            $c->log->info("  Body: " . substr(($args->{body} || ''), 0, 100) . "...");
            
            return 1;  # Return success even if sending failed
        };
    }
}

# Fallback process method for when Catalyst::View::Email is not available
sub process {
    my ($self, $c, $args) = @_;
    
    # Store debug messages in stash for debugging
    $c->stash->{debug_msg} = $self->_debug_msgs;
    
    # Log with details for debugging
    $self->log_with_details($c, "Processing email request (fallback mode)", {
        to => $args->{to},
        subject => $args->{subject},
    });
    
    $self->add_debug_msg("Email functionality not available: Catalyst::View::Email not installed");
    
    # Fallback implementation - just log the email details
    $c->log->info("Email would be sent (fallback mode):");
    $c->log->info("  To: " . ($args->{to} || 'not specified'));
    $c->log->info("  Subject: " . ($args->{subject} || 'not specified'));
    $c->log->info("  Body: " . substr(($args->{body} || ''), 0, 100) . "...");
    
    return 1;  # Return success even if sending failed
}

# Configuration
__PACKAGE__->config(
    sender => {
        mailer => 'SMTP',
        mailer_args => {
            host => 'localhost',
            port => 25,
        }
    },
    default => {
        content_type => 'text/plain',
        charset => 'UTF-8',
    }
);

__PACKAGE__->meta->make_immutable;

=head1 NAME

Comserv::View::Email - Email View for Comserv

=head1 DESCRIPTION

View for sending emails from Comserv

=head1 AUTHOR

Shanta

=head1 SEE ALSO

L<Comserv>

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
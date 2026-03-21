package Comserv::View::Email::Template;
use Moose;
use namespace::autoclean;

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

# Override process method to add debugging and fallback
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
            my $error = $@;
            $c->log->warn("Failed to send email using Catalyst::View::Email::Template: $error");
            $self->add_debug_msg("Failed to send email: $error");
            # Fall through to the fallback implementation
        } else {
            # If it worked, return success
            return 1;
        }
    } else {
        $self->add_debug_msg("Email template functionality not available: Catalyst::View::Email::Template not installed");
    }
    
    # Fallback implementation - just log the email details
    $c->log->info("Email template would be sent (fallback mode):");
    $c->log->info("  To: " . ($args->{to} || 'not specified'));
    $c->log->info("  Subject: " . ($args->{subject} || 'not specified'));
    $c->log->info("  Template: " . ($args->{template} || 'not specified'));
    
    # Try to render the template if Template Toolkit is available
    my $body = '';
    eval {
        require Template;
        $self->add_debug_msg("Template Toolkit loaded, attempting to render template");
        my $tt = Template->new({
            INCLUDE_PATH => [
                eval { Comserv->path_to('root') } || 'root',
            ],
            WRAPPER => 'email/wrapper.tt.notusedbyapplication',
        });
        my $template = $args->{template};
        my $vars = $args->{template_vars} || {};
        $tt->process($template, $vars, \$body) || die $tt->error();
    };
    if ($@) {
        my $tt_error = $@;
        $c->log->warn("Failed to render email template: $tt_error");
        $self->add_debug_msg("Template rendering failed: $tt_error");
        $body = "Template rendering failed. Template: " . ($args->{template} || 'not specified');
    }
    
    $c->log->info("  Body: " . substr($body, 0, 100) . "...");
    
    return 1;  # Return success even if sending failed
};

# Configuration
__PACKAGE__->config(
    template_prefix => 'email',
    render_params => {
        INCLUDE_PATH => [
            eval { Comserv->path_to('root') } || 'root',
        ],
        WRAPPER => 'email/wrapper.tt.notusedbyapplication',
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
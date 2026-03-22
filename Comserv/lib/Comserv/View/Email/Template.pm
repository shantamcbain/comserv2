package Comserv::View::Email::Template;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

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
            my ($orig, $self, $c) = @_;

            # Email config comes from $c->stash->{email}
            my $email_stash = $c->stash->{email} || {};
            my $to       = $email_stash->{to}       || '?';
            my $subject  = $email_stash->{subject}  || '?';
            my $template = $email_stash->{template} || '?';

            $self->_app_logging->log_with_details($c, 'info', __FILE__, __LINE__, 'Email::Template',
                "Processing email: to=$to subject=$subject template=$template");

            eval {
                $self->$orig($c);
            };
            if ($@) {
                my $error = "$@";
                $self->_app_logging->log_with_details($c, 'error', __FILE__, __LINE__, 'Email::Template',
                    "SMTP send failed: to=$to subject=$subject error=$error");
                # Do NOT re-throw — let caller's eval catch success/failure via return value
                return 0;
            }
            $self->_app_logging->log_with_details($c, 'info', __FILE__, __LINE__, 'Email::Template',
                "SMTP send OK via PMG: to=$to subject=$subject");
            return 1;
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
                host => '192.168.1.128',  # PMG relay
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
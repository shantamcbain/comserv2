package Comserv;
use Moose;
use namespace::autoclean;
use Config::JSON;
use FindBin '$Bin';

use Catalyst::Runtime 5.80;
use Catalyst qw/
    ConfigLoader
    Static::Simple
    StackTrace
    Session
    Session::Store::File
    Session::State::Cookie
    Authentication
    Authorization::Roles
    Log::Dispatch
    Authorization::ACL
/;
use Comserv::Util::Debug;
extends 'Catalyst';

our $VERSION = '0.01';

__PACKAGE__->log(Catalyst::Log->new(output => sub {
    my ($self, $level, $message) = @_;
    $level = 'debug' unless defined $level;
    $message = '' unless defined $message;
    $self->dispatchers->[0]->log(level => $level, message => $message);
}));

__PACKAGE__->config(
    name => 'Comserv',
    disable_component_resolution_regex_fallback => 1,
    enable_catalyst_header => $ENV{CATALYST_HEADER} // 1,
    encoding => 'UTF-8',
     'View::TT' => {
        INCLUDE_PATH => [
            __PACKAGE__->path_to('root'),  # Ensure this path is correct
            __PACKAGE__->path_to('root', 'src'),
            __PACKAGE__->path_to('root', 'lib'),
        ],
        TEMPLATE_EXTENSION => '.tt', # Add this line to recognize .tt2 files
        WRAPPER => 'layout.tt',
        ERROR => 'error.tt',
    },
   debug => $ENV{CATALYST_DEBUG} // 0,
    'Plugin::Log::Dispatch' => {
        dispatchers => [
            {
                class => 'Log::Dispatch::File',
                min_level => 'debug',
                filename => 'logs/application.log',
                mode => 'append',
                newline => 1,
            },
        ],
    },
);

sub psgi_app {
    my $self = shift;

    my $app = $self->SUPER::psgi_app(@_);

    return sub {
        my $env = shift;

        $self->config->{enable_catalyst_header} = $ENV{CATALYST_HEADER} // 1;
        $self->config->{debug} = $ENV{CATALYST_DEBUG} // 0;

        return $app->($env);
    };
}

__PACKAGE__->setup();

# Call the initialize_db.pl script during application startup
BEGIN {
    my $script_path = "$FindBin::Bin/../script/initialize_db.pl";
    unless (-x $script_path) {
        die "Failed to initialize database: $script_path is not executable";
    }
    system($script_path) == 0
        or die "Failed to initialize database: $!";
}

=encoding utf8

=head1 NAME

Comserv - Catalyst based application

=head1 SYNOPSIS

    script/comserv_server.pl

=head1 DESCRIPTION

[enter your description here]

=head1 SEE ALSO

L<Comserv::Controller::Root>, L<Catalyst>

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
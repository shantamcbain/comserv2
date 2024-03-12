package Comserv;
use Moose;
use namespace::autoclean;
use Config::JSON;
use FindBin '$Bin';

use Catalyst::Runtime 5.80;
use Catalyst qw/
    -Debug
    ConfigLoader
    Static::Simple
    StackTrace
    Session
    Session::Store::File
    Session::State::Cookie
    Authentication
    Authorization::Roles
    Log::Dispatch
/;
# Set flags and add plugins for the application.
#
# Note that ORDERING IS IMPORTANT here as plugins are initialized in order,
# therefore you almost certainly want to keep ConfigLoader at the head of the
# list if you're using it.
#
#         -Debug: activates the debug mode for very useful log messages
#   ConfigLoader: will load the configuration from a Config::General file in the
#                 application's home directory
# Static::Simple: will serve static file from the application's root
#                 directory



extends 'Catalyst';

our $VERSION = '0.01';
#my $config = Config::JSON->new('db_config.json');
#my $config = Config::JSON->new("$Bin/../db_config.json");
#my $connect_info = $config->get('connect_info');
#my $connect_info_ency = $config->get('connect_info_ency');

# Now you can use $connect_info and $connect_info_ency to connect to your databases with DBIx
# Configure the application.
#
# Note that settings in comserv.conf (or other external
# configuration file that you set up manually) take precedence
# over this when using ConfigLoader. Thus configuration
# details given here can function as a default configuration,
# with an external configuration file acting as an override for
# local deployment.
# After the use statements and before the __PACKAGE__->config call
__PACKAGE__->log(Catalyst::Log->new(output => sub {
    my ($self, $level, $message) = @_;
    $level = 'debug' unless defined $level;
    $message = '' unless defined $message;
    $self->dispatchers->[0]->log(level => $level, message => $message);
}));

__PACKAGE__->config(
    name => 'Comserv',
    # Disable deprecated behavior needed by old applications
    disable_component_resolution_regex_fallback => 1,
    enable_catalyst_header => 1, # Send X-Catalyst header
    encoding => 'UTF-8', # Setup request decoding and response encoding
     # Configure the application's log
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

# Start the application
__PACKAGE__->setup();

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

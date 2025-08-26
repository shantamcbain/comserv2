package Comserv::Controller::ThemeAdmin::update_theme_with_variables;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

# This file has been moved to ThemeAdmin.pm
# See ThemeAdmin.pm for the implementation

# Stub method to ensure the package is properly defined
sub update_theme_with_variables :Path :Args(0) {
    my ($self, $c) = @_;
    $c->response->redirect($c->uri_for('/themeadmin'));
}

__PACKAGE__->meta->make_immutable;
1; # Return true value
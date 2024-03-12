package Comserv::View::TT;
use Moose;
use namespace::autoclean;
extends 'Catalyst::View::TT';

__PACKAGE__->config(
    TEMPLATE_EXTENSION => '.tt',
    render_die => 1,
    WRAPPER => 'layout.tt',
    PLUGIN_BASE => 'Template::Plugin',
    PLUGINS     => { DateTime => {} },
);

__PACKAGE__->meta->make_immutable(inline_constructor => 0);

1;
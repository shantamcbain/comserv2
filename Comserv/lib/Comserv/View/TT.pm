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
# Register the format_time filter
$Template::Stash::SCALAR_OPS->{format_time} = sub {
    my $seconds = shift;
    my $hours = int($seconds / 3600);
    my $minutes = int(($seconds % 3600) / 60);
    return sprintf("%02d:%02d", $hours, $minutes);
};
__PACKAGE__->meta->make_immutable(inline_constructor => 0);

1;
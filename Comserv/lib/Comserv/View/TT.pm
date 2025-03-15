package Comserv::View::TT;
use Moose;
use namespace::autoclean;
use Comserv::View::Helper::Database;
extends 'Catalyst::View::TT';

has 'db_helper' => (
    is => 'ro',
    default => sub { Comserv::View::Helper::Database->new }
);

__PACKAGE__->config(
    TEMPLATE_EXTENSION => '.tt',
    render_die => 1,
    WRAPPER => 'layout.tt',
    PLUGIN_BASE => 'Template::Plugin',
    PLUGINS     => {
        DateTime => {},
        DBI => {},
    },
    CATALYST_VAR => 'c',
);
# Register the format_time filter
$Template::Stash::SCALAR_OPS->{format_time} = sub {
    my $seconds = shift;
    my $hours = int($seconds / 3600);
    my $minutes = int(($seconds % 3600) / 60);
    return sprintf("%02d:%02d", $hours, $minutes);
};

# Override render to add database helper to the stash
sub render {
    my ($self, $c, $template, $args) = @_;

    # Add the database helper to the stash
    $args->{db_helper} = $self->db_helper;

    # Call the parent render method
    return $self->next::method($c, $template, $args);
}

__PACKAGE__->meta->make_immutable(inline_constructor => 0);

1;
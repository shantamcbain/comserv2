package Comserv::Controller::ThemeEditor;

use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

use JSON;
use File::Slurp;
use Try::Tiny;

sub edit : Local {
    my ( $self, $c ) = @_;

    # Use the canonical theme_definitions.json location in static/config
    my $json_file = $c->path_to('root', 'static', 'config', 'theme_definitions.json');

    my $theme_data = {};
    if (-e $json_file) {
        try {
            my $json_text = read_file($json_file);
            $theme_data = decode_json($json_text);
            # If the JSON has a "themes" wrapper, unwrap it
            $theme_data = $theme_data->{themes} if exists $theme_data->{themes};
        }
        catch {
            $c->log->error("Failed to load theme definitions: $_");
        };
    }

    $c->stash->{theme_data} = $theme_data;
    $c->stash->{template} = 'theme_editor/edit.tt2';
}

__PACKAGE__->meta->make_immutable;

1;

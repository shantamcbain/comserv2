package Comserv::Controller::Admin::ThemeEditor;
use Moose;
use namespace::autoclean;
use File::Slurp;
use Try::Tiny;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub edit :Path('/admin/theme/edit') :Args(1) {
    my ($self, $c, $theme_name) = @_;
    
    # Check admin permissions
    unless ($c->session->{roles} && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $c->flash->{error} = 'Admin access required';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $css_file = $c->path_to('root', 'static', 'css', $theme_name . '.css');
    
    if ($c->req->method eq 'POST') {
        my $css_content = $c->req->params->{css_content};
        try {
            write_file($css_file, $css_content);
            $c->flash->{success} = 'CSS file updated successfully';
        } catch {
            $c->flash->{error} = "Error saving CSS: $_";
        };
    }

    my $css_content = -f $css_file ? read_file($css_file) : '';
    
    $c->stash(
        template => 'admin/theme/edit.tt',
        css_content => $css_content,
        theme_name => $theme_name
    );
}

__PACKAGE__->meta->make_immutable;
1;

package Comserv::Controller::SiteHome;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'sitehome');

has 'logging' => (is => 'ro', default => sub { Comserv::Util::Logging->instance });

sub auto :Private {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless ref $c->stash->{debug_errors} eq 'ARRAY';
    $c->stash->{debug_msg}    = [] unless ref $c->stash->{debug_msg}    eq 'ARRAY';
    return 1;
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'SiteHome';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "SiteHome serving site: $site_name");

    my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->first;

    my $tpl = "SiteHome/${site_name}.tt";
    my $tpl_path = $c->path_to('root', 'SiteHome', "${site_name}.tt");
    unless (-f $tpl_path) {
        $tpl = 'SiteHome/default.tt';
    }

    $c->stash(
        template => $tpl,
        title    => ($site ? $site->site_display_name : $site_name),
        site     => $site,
    );
}

__PACKAGE__->meta->make_immutable;
1;

# CLI/DB loading stabilized [2026-07-16] - Grok review
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

    # Defensive: wrap Site query in eval for schema mismatch tolerance (e.g. missing columns in SQLite).
    my $site;
    eval {
        $site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->first;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index', 
            "Site lookup failed (possible schema mismatch / SQLite fallback): $@");
        undef $site;
    }

    # Check if a dynamic home page exists in the new Page table
    my $page = eval {
        $c->model('DBEncy')->resultset('Page')->find({
            sitename  => $site_name,
            page_code => 'home',
            status    => 'active',
        });
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', "Error finding dynamic home page: $@");
    }

    unless ($page) {
        $page = eval {
            $c->model('DBEncy')->resultset('Page')->find({
                sitename  => $site_name,
                page_code => 'index',
                status    => 'active',
            });
        };
    }

    if ($page) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
            "Delivering dynamic database home page for site '$site_name' (page_code: " . $page->page_code . ")");
        $c->stash(
            page     => $page,
            template => 'pages/view.tt',
            title    => $page->title,
        );
        return;
    }

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

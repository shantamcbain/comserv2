package Comserv::Controller::Root;

use Moose;
use namespace::autoclean;
use Template;                     # Template Toolkit - for template handling
use Data::Dumper;                 # For debugging purposes
use Comserv::Model::DBSchemaManager; # Handles database schema management or migrations
use Try::Tiny;

BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => '');

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    push @{$c->stash->{error_msg}}, "Entered index action in Root.pm";
    my $site_name = $c->session->{SiteName} // 'none';

    if ($site_name ne 'Root') {
        push @{$c->stash->{error_msg}}, "Redirecting to controller: $site_name";
        $c->detach($site_name, 'index');
    } else {
        $c->stash(template => 'index.tt');
    }
}

sub auto :Private {
    my ($self, $c) = @_;

    my $SiteName = $c->session->{SiteName};

    if (defined $SiteName && $SiteName ne 'none') {
        push @{$c->stash->{error_msg}}, "SiteName found in session: $SiteName";
    } else {
        push @{$c->stash->{error_msg}}, "SiteName not found in session, extracting domain";

        my $domain = $c->req->base->host;
        $domain =~ s/:.*//;

        try {
            my $site_domain = $c->model('Site')->get_site_domain($domain);

            if ($site_domain && $site_domain->site_id) {
                my $site_details = $c->model('Site')->get_site_details($site_domain->site_id);
                if ($site_details && $site_details->name) {
                    $c->session->{SiteName} = $site_details->name;
                    $c->stash->{SiteName} = $site_details->name;
                } else {
                    $c->session->{SiteName} = 'none';
                    $c->stash->{SiteName} = 'none';
                }
            } else {
                $c->session->{SiteName} = 'none';
                $c->stash->{SiteName} = 'none';
            }
        } catch {
            push @{$c->stash->{error_msg}}, "Error retrieving site domain: $_";
            $c->session->{SiteName} = 'none';
            $c->stash->{SiteName} = 'none';
        };
    }

    # Call the site_setup method from the Site controller
    $c->controller('Site')->site_setup($c, $c->session->{SiteName});

    push @{$c->stash->{error_msg}}, 'Entered auto action in Root.pm';

    # Handle session group
    unless ($c->session->{group}) {
        $c->session->{group} = 'normal';
    }

    # Handle 'debug' parameter
    my $debug_param = $c->req->param('debug');
    if (defined $debug_param) {
        if ($c->session->{debug_mode} ne $debug_param) {
            $c->session->{debug_mode} = $debug_param;
            $c->stash->{debug_mode} = $debug_param;
        }
    } elsif (defined $c->session->{debug_mode}) {
        $c->stash->{debug_mode} = $c->session->{debug_mode};
    }

    # Handle 'page' parameter
    my $page = $c->req->param('page');
    if (defined $page) {
        if ($c->session->{page} ne $page) {
            $c->session->{page} = $page;
            $c->stash->{page} = $page;
        }
    } elsif (defined $c->session->{page}) {
        $c->stash->{page} = $c->session->{page};
    }

    return 1;
}

sub fetch_and_set {
    my ($self, $c, $param) = @_;

    my $value = $c->req->query_parameters->{$param};
    push @{$c->stash->{error_msg}}, "fetch_and_set: $value";

    if (defined $value) {
        $c->stash->{SiteName} = $value;
        $c->session->{SiteName} = $value;
    } elsif (defined $c->session->{SiteName}) {
        $c->stash->{SiteName} = $c->session->{SiteName};
    } else {
        my $domain = $c->req->base->host;
        $domain =~ s/:.*//;

        my $site_domain = $c->model('Site')->get_site_domain($domain);
        if ($site_domain) {
            $c->stash->{SiteName} = $site_domain;
            $c->session->{SiteName} = $site_domain;
        } else {
            $c->stash->{SiteName} = 'none';
            $c->session->{SiteName} = 'none';
        }
    }

    return $value;
}

sub default :Path {
    my ($self, $c) = @_;
    $c->response->body('Page not found');
    $c->response->status(404);
}

sub end : ActionClass('RenderView') {}

__PACKAGE__->meta->make_immutable;

1;

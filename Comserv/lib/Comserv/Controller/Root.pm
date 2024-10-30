package Comserv::Controller::Root;

use Moose;
use namespace::autoclean;
use Template;
use Data::Dumper;
use Comserv::Model::DBSchemaManager;
use Try::Tiny;
use Comserv::Util::Logger;
BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => '');

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    Comserv::Util::Logging->log_with_details($c, "Entered index action in Root.pm");

    Comserv::Util::Logging->log_with_details($c, "Entered index action in Root.pm");
    Comserv::Util::Logging->log_with_details($c, "About to fetch SiteName from session");

    my $site_name = $c->session->{SiteName} // 'none';

    Comserv::Util::Logging->log_with_details($c, "Fetched SiteName from session: $site_name");

    if ($site_name ne 'Root') {
        Comserv::Util::Logging->log_with_details($c, "Redirecting to controller: $site_name");
        $c->detach($site_name, 'index');
    } else {
        Comserv::Util::Logging->log_with_details($c, "Rendering Root index");
        $c->stash(template => 'index.tt');
    }
}
sub auto :Private {
    my ($self, $c) = @_;

    # Log entry into the auto action
    Comserv::Util::Logging->instance->log_with_details($c, "Entered auto action in Root.pm");

    # Domain setup
    my $domain = $c->req->base->host;
    $domain =~ s/:.*//;

    my $site_model = $c->model('Site');
    my $SiteName = $c->session->{SiteName} || $domain;
    Comserv::Util::Logging->instance->log_with_details($c, "Fetched SiteName from session: $SiteName");

    try {
        if ($SiteName ne 'none' && $c->session->{SiteName}) {
            $c->stash(site_name => $SiteName);
        } else {
            my $domain_setup = $site_model->site_setup($SiteName);
            if ($domain_setup && $domain_setup->{site_name}) {
                $c->stash(%$domain_setup);
                $c->session->{SiteName} = $domain_setup->{site_name};
                Comserv::Util::Logging->instance->log_with_details($c, "Site setup successful for $SiteName");
            } else {
                Comserv::Util::Logging->instance->log_with_details($c, "Failed to setup site for domain: $domain");
            }
        }
        $self->site_setup($c, $c->stash->{site_name});
    } catch {
        Comserv::Util::Logging->instance->log_with_details($c, "Error setting up site: $_");
    };

    # Existing logic for schema, group, and debug mode
    my $schema = $c->model('DBEncy');
    print "Schema: $schema\n";

    # Update the call to fetch_and_set to use the Site model
    $SiteName = $site_model->fetch_and_set($c, $schema, 'site');

    unless ($c->session->{group}) {
        $c->session->{group} = 'normal';
    }

    # Debug mode toggle
    my $debug_param = $c->req->param('debug');
    if (defined $debug_param) {
        if ($debug_param eq '1') {
            $c->session->{debug_mode} = 1;
        } elsif ($debug_param eq '0') {
            $c->session->{debug_mode} = 0;
        }
    }
}



sub debug :Path('/debug') {
    my ($self, $c) = @_;

    my $site_name = $c->stash->{SiteName};
    $c->stash(template => 'debug.tt');
    $c->forward($c->view('TT'));
}

sub default :Path {
    my ( $self, $c ) = @_;
    $c->response->body( 'Page not found' );
    $c->response->status(404);
}

sub documentation :Path('documentation') :Args(0) {
    my ( $self, $c ) = @_;

    # Logging to stash
    Comserv::Util::Logging->log_with_details($c, "Entered documentation action in Root.pm");

    # Ensure the template path is correct
    my $template_path = 'Documentation/Documentation.tt';
    if (!-e $c->path_to('root', $template_path)) {
        Comserv::Util::Logging->log_with_details($c, "Template file not found: $template_path");
        $c->response->body('Template file not found');
        $c->response->status(500);
        return;
    }

    $c->stash(template => $template_path);

    # Logging to stash
    Comserv::Util::Logging->log_with_details($c, "Template set to $template_path");

    $c->forward($c->view('TT'));
}


sub end : ActionClass('RenderView') {}

__PACKAGE__->meta->make_immutable;

1;
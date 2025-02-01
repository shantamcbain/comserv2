package Comserv::Controller::Root;

use Moose;
use namespace::autoclean;
use Template;
use Data::Dumper;
use Comserv::Util::Logging;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => '');

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Starting index action");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "About to fetch SiteName from session");
    my $SiteName = $c->session->{SiteName};
    my $ControllerName = $c->session->{SiteName};
    $self->logging->log_with_details($c,  'info', __FILE__, __LINE__, 'index', "Site setup called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Fetched SiteName from session: $SiteName");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Fetched ControllerName from session: $ControllerName");

    print "ControllerName in index: = $ControllerName\n";
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "ControllerName in index: = $ControllerName");

    print "print SiteName in root index: = $SiteName\n";
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "SiteName in root index: = $SiteName");

    if ($ControllerName) {
        if ($ControllerName =~ /\.tt$/) {
            $ControllerName =~ s{^/}{};
            $c->stash(template => $ControllerName);
        } else {
            $c->detach($ControllerName, 'index');
        }
    } else {
        $c->stash(template => 'index.tt');
    }

    $c->forward($c->view('TT'));
}

sub fetch_and_set {
    my ($self, $c, $param) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Starting fetch_and_set action");
    my $value = $c->req->query_parameters->{$param};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Checking query parameter '$param'");

    if (defined $value) {
        $c->stash->{SiteName} = $value;
        $c->session->{SiteName} = $value;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Query parameter '$param' found: $value");
    }
    elsif (defined $c->session->{SiteName}) {
        $c->stash->{SiteName} = $c->session->{SiteName};
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "SiteName found in session: " . $c->session->{SiteName});
    }
    else {
        my $domain = $c->req->base->host;
        $domain =~ s/:.*//;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Extracted domain: $domain");

        my $site_domain = $c->model('Site')->get_site_domain($domain);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Site domain retrieved: " . Dumper($site_domain));

        if ($site_domain) {
            my $site_id = $site_domain->site_id;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Site ID: $site_id");

            my $site = $c->model('Site')->get_site_details($site_id);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Site details retrieved: " . Dumper($site));

            if ($site) {
                $value = $site->name;
                $c->stash->{SiteName} = $value;
                $c->session->{SiteName} = $value;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "SiteName set to: $value");

                $c->session->{SiteDisplayName} = $site->site_display_name;
                my $home_view = $site->home_view || 'Root';
                $c->stash->{ControllerName} = $home_view;
                $c->session->{ControllerName} = $home_view;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "ControllerName set to: $home_view");
            }
        } else {
            $c->session->{SiteName} = 'none';
            $c->stash->{SiteName} = 'none';
            $c->session->{ControllerName} = 'Root';
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'fetch_and_set', "No site domain found, defaulting SiteName and ControllerName to 'none' and 'Root'");
        }
    }

    return $value;
}


sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Starting auto action");

    my $SiteName = $c->session->{SiteName};

    if (!defined $SiteName || $SiteName eq 'none' || $SiteName eq 'root') {

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "SiteName is either undefined, 'none', or 'root'. Proceeding with domain extraction and site domain retrieval");

        my $domain = $c->req->base->host;
        $domain =~ s/:.*//;
        # Store the domain in the session
        $c->session->{Domain} = $domain;

        my $site_domain = $c->model('Site')->get_site_domain($domain);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "site_domain in auto = $site_domain");

        if ($site_domain) {
            my $site_id = $site_domain->site_id;
            my $site = $c->model('Site')->get_site_details($site_id);

            if ($site) {
                $SiteName = $site->name;
                $c->stash->{SiteName} = $SiteName;
                $c->session->{SiteName} = $SiteName;
            }
        } else {
            $SiteName = $self->fetch_and_set($c, 'site');
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "SiteName in auto = $SiteName");
            if (!defined $SiteName) {
                $c->stash(template => 'index.tt');
                $c->forward($c->view('TT'));
                return 0;
            }
        }
    }

    $self->site_setup($c, $c->session->{SiteName});

    $c->log->debug('Entered auto action in Root.pm');

    my $schema = $c->model('DBEncy');
    #print "Schema: $schema\n";

    $SiteName = $self->fetch_and_set($c, $schema, 'site');

    unless ($c->session->{group}) {
        $c->session->{group} = 'normal';
    }

    my $debug_param = $c->req->param('debug');
    if (defined $debug_param) {
        if ($c->session->{debug_mode} ne $debug_param) {
            $c->session->{debug_mode} = $debug_param;
            $c->stash->{debug_mode} = $debug_param;
        }
    } elsif (defined $c->session->{debug_mode}) {
        $c->stash->{debug_mode} = $c->session->{debug_mode};

    }

    my $page = $c->req->param('page');
    if (defined $page) {
        if ($c->session->{page} ne $page) {
            $c->session->{page} = $page;
            $c->stash->{page} = $page;
        }
    } elsif (defined $c->session->{page}) {
        $c->stash->{page} = $c->session->{page};
    }

    $c->stash->{HostName} = $c->request->base;
    my @todos = $c->model('Todo')->get_top_todos($c, $SiteName);
    my $todos = $c->session->{todos};
    $c->stash(todos => $todos);

    if (ref($c) eq 'Catalyst::Context') {
        my @main_links = $c->model('DB')->get_links($c, 'Main');
        my @login_links = $c->model('DB')->get_links($c, 'Login');
        my @global_links = $c->model('DB')->get_links($c, 'Global');
        my @hosted_links = $c->model('DB')->get_links($c, 'Hosted');
        my @member_links = $c->model('DB')->get_links($c, 'Member');

        $c->session(
            main_links => \@main_links,
            login_links => \@login_links,
            global_links => \@global_links,
            hosted_links => \@hosted_links,
            member_links => \@member_links,
        );
    }
    # Set the mail server name based on the SiteName
    my $mail_server;

    return 1;
}



sub site_setup {
    my ($self, $c) = @_;
    my $SiteName = $c->session->{SiteName};

    unless (defined $SiteName) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "SiteName is not defined in the session");
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "SiteName: $SiteName");

    my $site = $c->model('Site')->get_site_details_by_name($SiteName);

    unless (defined $site) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "No site found for SiteName: $SiteName");
        return;
    }

    #$self->logging->log_with_details($c, 'info', __FILE__, __LINE__,  'site_setup', "Found site: " . Dumper($site));

    my $css_view_name = $site->css_view_name || '/static/css/default.css';
    my $site_display_name = $site->site_display_name || 'none';
    my $mail_to_admin = $site->mail_to_admin || 'none';
    my $mail_replyto = $site->mail_replyto || 'helpdesk.computersystemconsulting.ca';

    $c->stash->{ScriptDisplayName} = $site_display_name;
    $c->stash->{css_view_name} = $css_view_name;
    $c->stash->{mail_to_admin} = $mail_to_admin;
    $c->stash->{mail_replyto} = $mail_replyto;

    $c->stash(
        default_css => $c->uri_for($c->stash->{css_view_name} || '/static/css/default.css'),
        menu_css => $c->uri_for('/static/css/menu.css'),
        log_css => $c->uri_for('/static/css/log.css'),
        todo_css => $c->uri_for('/static/css/todo.css'),
    );
}

sub debug :Path('/debug') {
    my ($self, $c) = @_;

    my $site_name = $c->stash->{SiteName};
    $c->stash(template => 'debug.tt');
    $c->forward($c->view('TT'));
}
# Subroutine to handle the /accounts route
sub accounts :Path('/accounts') :Args(0) {
    my ($self, $c) = @_;

    # Log the access to the accounts page
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'accounts', "Accessing accounts page");

    # Set the template to accounts.tt
    $c->stash(template => 'accounts.tt');

    # Forward to the TT view for rendering
    $c->forward($c->view('TT'));
}

sub default :Path {
    my ( $self, $c ) = @_;
    $c->response->body( 'Page not found' );
    $c->response->status(404);
}

sub documentation :Path('documentation') :Args(0) {
    my ( $self, $c ) = @_;
    $c->stash(template => 'Documentation/Documentation.tt');
}

sub end : ActionClass('RenderView') {}

__PACKAGE__->meta->make_immutable;

1;



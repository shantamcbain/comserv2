package Comserv::Controller::Root;

use Moose;
use namespace::autoclean;
use Template;
use Data::Dumper;

BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => '');

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    $c->log->debug('Entered index action in Root.pm');
    $c->log->debug('About to fetch SiteName from session');
    my $SiteName = $c->session->{SiteName};
    my $ControllerName = $c->session->{SiteName};
    # Add a logging statement here
    $c->log->debug("Fetched SiteName from session: $SiteName");
    $c->log->debug("Fetched ControllerName from session: $ControllerName");

    print "ControllerName in index: = $ControllerName\n";
    $c->log->debug("ControllerName in index: = $ControllerName\n");

    print "print SiteName in root index: = $SiteName\n";
    $c->log->debug('debug SiteName in root index: = $SiteName\n');

    if ($ControllerName) {
        # Check if the ControllerName is a controller or a template
        if ($ControllerName =~ /\.tt$/) {
            # If it's a template, set the template
            $ControllerName =~ s{^/}{};
            $c->stash(template => $ControllerName);
        } else {
            # If it's a controller, detach to the controller
            $c->detach($ControllerName, 'index');
        }
    } else {
        # Handle the case when the controller name doesn't exist
        $c->stash(template => 'index.tt');
    }

    $c->forward($c->view('TT'));
}

sub auto :Private {
    my ($self, $c) = @_;

    # Keep the code to remove the port from the domain
    my $domain = $c->req->base->host;
    $domain =~ s/:.*//;

    my $site_domain = $c->model('Site')->get_site_domain($domain);
    $c->log->debug(__PACKAGE__ . " . (split '::', __SUB__)[-1] . \" line \" . __LINE__ . \": site_domain in auto = $site_domain");

    if ($site_domain) {
        # If a SiteName is found, store it in the session and stash
        my $site_id = $site_domain->site_id;
        my $site = $c->model('Site')->get_site_details($site_id);

        if ($site) {
            my $SiteName = $site->name;
            $c->stash->{SiteName} = $SiteName;
            $c->session->{SiteName} = $SiteName;
        }
    } else {
        # If no SiteName is found, call fetch_and_set method to handle this
        my $SiteName = $self->fetch_and_set($c, 'site');
        $c->log->debug(__PACKAGE__ . " . (split '::', __SUB__)[-1] . \" line \" . __LINE__ . \": SiteName in auto = $SiteName");

        # If the domain is not in the table, use the default home page of index.tt
        if (!defined $SiteName) {
            $c->stash(template => 'index.tt');
            $c->forward($c->view('TT'));
            return 0; # Stop further processing of this request
        }
    }

    # Call site_setup regardless of whether SiteName is found or not
    $self->site_setup($c, $c->session->{SiteName});

    # Continue with the rest of the auto method as before
    $c->log->debug('Entered auto action in Root.pm');

    my $schema = $c->model('DBEncy');
    print "Schema: $schema\n";

    # Set up universal variables

    # Call fetch_and_set method
    my $SiteName = $self->fetch_and_set($c, $schema, 'site');

    unless ($c->session->{group}) {
        $c->session->{group} = 'normal';
    }

    # Get the debug parameter from the URL
    my $debug_param = $c->req->param('debug');
    # If the debug parameter is defined
    if (defined $debug_param) {
        # If the debug parameter is different from the session value
        if ($c->session->{debug_mode} ne $debug_param) {
            # Store the new debug parameter in the session and stash
            $c->session->{debug_mode} = $debug_param;
            $c->stash->{debug_mode} = $debug_param;
        }
    } elsif (defined $c->session->{debug_mode}) {
        # If the debug parameter is not defined but there is a value in the session
        # Store the session value in the stash
        $c->stash->{debug_mode} = $c->session->{debug_mode};
    }

    # Declare the variable $page before using it
    my $page = $c->req->param('page');
    # If the debug parameter is defined
    if (defined $page) {
        # If the debug parameter is different from the session value
        if ($c->session->{page} ne $page) {
            # Store the new debug parameter in the session and stash
            $c->session->{page} = $page;
            $c->stash->{page} = $page;
        }
    } elsif (defined $c->session->{page}) {
        # If the debug parameter is not defined but there is a value in the session
        # Store the session value in the stash
        $c->stash->{page} = $c->session->{page};
    }

    # Fetch the list of todos from the database

    # Set the HostName in the stash
    $c->stash->{HostName} = $c->request->base;
    # Fetch the top 10 todos from the Todo model
    my @todos = $c->model('Todo')->get_top_todos($c, $SiteName);

    # Fetch the todos from the session
    my $todos = $c->session->{todos};

    # Store the todos in the stash
    $c->stash(todos => $todos);

    # In your Comserv::Controller::Root controller
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

    # Continue processing the rest of the request
    return 1;
}

sub fetch_and_set {
    my ($self, $c, $param) = @_;

    my $value = $c->req->query_parameters->{$param};

    $c->log->debug(__PACKAGE__ . " . (split '::', __SUB__)[-1] . \" line \" . __LINE__ . \":  in fetch_and_set: $value");

    # If value is defined in the URL, update the session and stash
    if (defined $value) {
        $c->stash->{SiteName} = $value;
        $c->session->{SiteName} = $value;
    }
    elsif (defined $c->session->{SiteName}) {
        # If value is not defined in the URL but is defined in the session, use the session value
        $c->stash->{SiteName} = $c->session->{SiteName};
    }
    else {
        # If value is not defined in the URL or session, use the domain name to fetch the site name from the Site model
        my $domain = $c->req->base->host;
        $domain =~ s/:.*//; # Remove the port number from the domain

        # Fetch the site_id from the sitedomain table
        my $site_domain = $c->model('Site')->get_site_domain($domain);
        $c->log->debug("fetch_and_set site_domain: $site_domain");

        if ($site_domain) {
            my $site_id = $site_domain->site_id;

            # Fetch the site details from the sites table
            my $site = $c->model('Site')->get_site_details($site_id);

            if ($site) {
                $value = $site->name;
                $c->stash->{SiteName} = $value;
                $c->session->{SiteName} = $value;
                print "SiteName in fetch_and_set: = $value\n";
                $c->session->{SiteDisplayName} =$site->site_display_name;
                # Fetch the home_view from the Site table
                my $home_view = $site->home_view;
                $c->stash->{ControllerName} = $site->name || 'Default';
                print "ControllerName in fetch_and_set: = $home_view\n";
                $c->log->debug("home_view: $home_view");
                $c->session->{ControllerName} = $home_view;
                $c->log->debug("home_view: $home_view");
            }
        } else {
            # If the site is not found in the Site model, set a default value in the session
            $c->session->{SiteName} = 'none';
            $c->stash->{SiteName} = 'none';
        }
    }

    return $value;
}
sub site_setup {
    my ($self, $c) = @_;
    my $SiteName = $c->session->{SiteName};

    unless (defined $SiteName) {
        $c->log->debug("SiteName is not defined in the session");
        return;
    }

    $c->log->debug("SiteName: $SiteName");

    my $site = $c->model('Site')->get_site_details_by_name($SiteName);

    unless (defined $site) {
        $c->log->debug("No site found for SiteName: $SiteName");
        return;
    }

    # Add debug logging for the site object
    $c->log->debug("Found site: " . Dumper($site));

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

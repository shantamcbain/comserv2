# perl
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

sub index :Path('/') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Starting index action");

    # Get SiteName from session
    my $SiteName = $c->session->{SiteName};

    # Get ControllerName from session
    my $ControllerName = $c->session->{SiteName};
    $self->logging->log_with_details($c,  'info', __FILE__, __LINE__, 'index', "Site setup called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Fetched SiteName from session: $SiteName");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Fetched ControllerName from session: $ControllerName");

    # Get ControllerName from the session
    my $ControllerName = $c->session->{ControllerName} || undef; # Default to undef if not set
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Fetched ControllerName from session: " . ($ControllerName // 'undefined'));

    if ($ControllerName) {
        # Forward to the controller's index action
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Forwarding to $ControllerName controller's index action");
        $c->detach($ControllerName, 'index');
    } else {
        # Default to Root's index template
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Defaulting to Root's index template");
        $c->stash(template => 'index.tt');
        $c->forward($c->view('TT'));
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Completed index action");
    return 1; # Allow the request to proceed
}


# perl
# perl
sub fetch_and_set {
    my ($self, $c, $param) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Starting fetch_and_set action");
    my $value = $c->req->query_parameters->{$param};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Checking query parameter '$param'");

    if (defined $value) {
        $c->stash->{SiteName} = $value;
        $c->session->{SiteName} = $value;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Query parameter '$param' found: $value");
    } elsif (defined $c->session->{SiteName}) {
        $c->stash->{SiteName} = $c->session->{SiteName};
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "SiteName found in session: " . $c->session->{SiteName});
    } else {
        my $domain = $c->req->uri->host;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Extracted domain: $domain");

        my $site_domain = $c->model('Site')->get_site_domain($c, $domain);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Site domain retrieved: " . Dumper($site_domain));

        if ($site_domain) {
            my $site_id = $site_domain->site_id;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Site ID: $site_id");

            my $site = $c->model('Site')->get_site_details($c, $site_id);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Site details retrieved: " . Dumper($site));

            if ($site) {
                $value = $site->name;
                $c->stash->{SiteName} = $value;
                $c->session->{SiteName} = $value;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "SiteName set to: $value");

                # Set ControllerName based on the site's home_view
                my $home_view = $site->home_view || 'Root';  # Ensure this is domain-specific
                $c->stash->{ControllerName} = $home_view;
                $c->session->{ControllerName} = $home_view;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "ControllerName set to: $home_view");
            }
        } else {
            $c->session->{SiteName} = 'none';
            $c->stash->{SiteName} = 'none';
            $c->session->{ControllerName} = 'Root';
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "No site domain found, defaulting SiteName and ControllerName to 'none' and 'Root'");
        }
    }

    return $value;
}

sub auto :Private {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Starting auto action");
    # Check if setup is needed
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Checking if setup is needed");

    # Check if setup is needed
    if ($c->req->param('setup')) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Setup mode detected");
        $c->response->redirect($c->uri_for('/setup'));
        return 0;
    }



    # Log the request path
    my $path = $c->req->path;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: '$path'");

    # Perform general setup tasks
    $self->setup_debug_mode($c);
    $self->setup_site($c);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Completed general setup tasks");

    # Call the index action only for the root path
    if ($path eq '/' || $path eq '') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Calling index action for root path");
        $self->index($c);
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Completed auto action");
    return 1; # Allow the request to proceed
}

sub setup_debug_mode {
        my ($self, $c) = @_;

        if (defined $c->req->params->{debug}) {
            $c->session->{debug_mode} = $c->session->{debug_mode} ? 0 : 1;
        }
        $c->stash->{debug_mode} = $c->session->{debug_mode};
    }

sub setup_site {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', "Starting setup_site action");

    my $SiteName = $c->session->{SiteName};
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', "Session SiteName: " . ($SiteName // 'undefined'));

    if (!defined $SiteName || $SiteName eq 'none' || $SiteName eq 'root') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', "SiteName is either undefined, 'none', or 'root'. Proceeding with domain extraction and site domain retrieval");

        my $domain = $c->req->uri->host;
        $domain =~ s/:.*//;  # Remove port if present
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', "Extracted domain: $domain");

        my $site_domain = $c->model('Site')->get_site_domain($c, $domain);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', "site_domain in setup_site = " . Dumper($site_domain));

        if ($site_domain) {
            my $site_id = $site_domain->site_id;
            my $site = $c->model('Site')->get_site_details($c, $site_id);

            if ($site) {
                $SiteName = $site->name;
                $c->stash->{SiteName} = $SiteName;
                $c->session->{SiteName} = $SiteName;

                # Set ControllerName based on the site's home_view
                my $home_view = $site->name || 'Root';  # Ensure this is domain-specific
                $c->stash->{ControllerName} = $home_view;
                $c->session->{ControllerName} = $home_view;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', "ControllerName set to: $home_view");
            }
        } else {
            $SiteName = $self->fetch_and_set($c, 'site');
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', "SiteName in setup_site = $SiteName");

            if (!defined $SiteName) {
                $c->stash(template => 'index.tt');
                $c->forward($c->view('TT'));
                return 0;
            }
        }
    }

    $self->site_setup($c, $c->session->{SiteName});
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', 'Completed site setup');
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', 'Entered auto action in Root.pm');

    my $schema = $c->model('DBEncy');
    $SiteName = $self->fetch_and_set($c, $schema, 'site');
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', "Fetched SiteName: $SiteName");

    unless ($c->session->{group}) {
        $c->session->{group} = 'normal';
    }

    unless (ref $c->session->{roles} eq 'ARRAY') {
        $c->session->{roles} = [];
    }
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', "Session Roles: " . join(', ', @{$c->session->{roles}}));

    # Check for debug parameter in the URL and toggle debug mode accordingly
    if (defined $c->req->params->{debug}) {
        if ($c->req->params->{debug} == 1) {
            $c->session->{debug_mode} = 1;
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', "Debug mode enabled");
        } elsif ($c->req->params->{debug} == 0) {
            $c->session->{debug_mode} = 0;
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', "Debug mode disabled");
        }
    }

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
        my ($self, $c, $SiteName) = @_;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "SiteName: $SiteName");

        my $site = $c->model('Site')->get_site_details_by_name($c, $SiteName);
        unless (defined $site) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'site_setup', "No site found for SiteName: $SiteName");
            return;
        }

        my $css_view_name = $site->css_view_name || '/static/css/default.css';
        my $site_display_name = $site->site_display_name || 'none';
        my $mail_to_admin = $site->mail_to_admin || 'none';
        my $mail_replyto = $site->mail_replyto || 'helpdesk.computersystemconsulting.ca';
        my $site_name = $site->name || 'none';

        $c->stash->{ScriptDisplayName} = $site_display_name;
        $c->stash->{css_view_name} = $css_view_name;
        $c->stash->{mail_to_admin} = $mail_to_admin;
        $c->stash->{mail_replyto} = $mail_replyto;
        $c->stash->{SiteName} = $site_name;
        $c->session->{SiteName} = $site_name;
   $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "Completed site_setup action");
    }

    sub debug :Path('/debug') {
        my ($self, $c) = @_;
        my $site_name = $c->stash->{SiteName};
        $c->stash(template => 'debug.tt');
        $c->forward($c->view('TT'));
   $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "Completed site_setup action");
    }

    sub accounts :Path('/accounts') :Args(0) {
        my ($self, $c) = @_;

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'accounts', "Accessing accounts page");

        $c->stash(template => 'accounts.tt');
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
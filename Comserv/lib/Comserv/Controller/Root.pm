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

    sub index :Path :Args(0) {
        my ($self, $c) = @_;

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Starting index action");

        my $SiteName = $c->session->{SiteName};
        my $ControllerName = $c->session->{SiteName};
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Fetched SiteName from session: $SiteName");
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Fetched ControllerName from session: $ControllerName");

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
                my $home_view = $site->home_view || 'Root';
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



# perl

# perl
# perl
sub auto :Private {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Starting auto action");

    # Toggle debug mode
    if (defined $c->req->params->{debug}) {
        $c->session->{debug_mode} = $c->session->{debug_mode} ? 0 : 1;
    }
    $c->stash->{debug_mode} = $c->session->{debug_mode};

    my $SiteName = $c->session->{SiteName};

    if (!defined $SiteName || $SiteName eq 'none' || $SiteName eq 'root') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "SiteName is either undefined, 'none', or 'root'. Proceeding with domain extraction and site domain retrieval");

        my $domain = $c->req->uri->host;
        $domain =~ s/:.*//;  # Remove port if present
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Extracted domain: $domain");

        my $site_domain = $c->model('Site')->get_site_domain($c, $domain);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "site_domain in auto = " . Dumper($site_domain));

        if ($site_domain) {
            my $site_id = $site_domain->site_id;
            my $site = $c->model('Site')->get_site_details($c, $site_id);

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

    # Set ControllerName to be the same as SiteName
    $c->session->{ControllerName} = $SiteName;
    $c->stash->{ControllerName} = $SiteName;

    $self->site_setup($c, $c->session->{SiteName});
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 'Completed site setup, forwarding to index');

    # Forward to index for final decision on controller or default homepage
    $c->forward('index');

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

    #$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "Found site: " . Dumper($site));

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

    # Do not override ControllerName here
}


    sub debug :Path('/debug') {
        my ($self, $c) = @_;
        my $site_name = $c->stash->{SiteName};
        $c->stash(template => 'debug.tt');
        $c->forward($c->view('TT'));
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
package Comserv::Controller::Root;
use Moose;
use namespace::autoclean;
use Template;
use Data::Dumper;
BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => '');

sub index :Path :Args(0){
    my ($self, $c) = @_;
    $c->log->debug('Entered index action in Root.pm');
    my $SiteName = $c->session->{SiteName};
    print "SiteName in root index: = $SiteName\n";
    $c->log->debug('SiteName in root index: = $SiteName\n');
    # Define a hash to map site names to controllers
    my %site_to_controller = (
        # ...
        'BMaster' => 'BMaster',
        # ...
    );

    # Check if the site name exists in the hash
    if (exists $site_to_controller{$SiteName}) {
        # Set the site controller to define site specific routes
        my $controller = $site_to_controller{$SiteName};
$c->detach($site_to_controller{$SiteName}, 'index');
    } else {
        # Handle the case when the site name doesn't exist in the hash
        #$c->detach('Default::index');
    }

    # Define a hash to map site names to templates
    my %site_to_template = (
        'SunFire' => 'SunFire/SunFire.tt',
        'Brew'    => 'Brew/Brew.tt',
        'CSC' => 'CSC/CSC.tt',
        'Dev' => 'dev/index.tt',
        'Forager' => 'Forager/Forager.tt',
        'Monashee' => 'Monashee/Monashee.tt',
        'Shanta' => 'Shanta/Shanta.tt',
        'WB' => 'Shanta/WB.tt',
        'USBM' => 'USBM/USBM.tt',
        've7tit' => 'Shanta/ve7tit.tt',
        'home' => 'home.tt',
    );

    # Check if the site name exists in the hash
    if (exists $site_to_template{$SiteName}) {
        # If it does, use the corresponding template
        $c->stash(template => $site_to_template{$SiteName});
    } else {
        # If it doesn't, default to 'index.tt'
        $c->stash(template => 'index.tt');
    }

    $c->forward($c->view('TT'));
}



sub auto :Private {
    my ($self, $c) = @_;
    $c->log->debug('Entered auto action in Root.pm');
    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');
    print "Schema: $schema\n";

    # Set up universal variables

    # Get the site name from the URL
    my $SiteName = $self->fetch_and_set($c, $schema, 'site');
    # Get the domain name
    my $domain = $self->fetch_and_set($c, $schema, 'domain');
     $self->site_setup($c, $SiteName);

    unless ($c->session->{group}) {
        $c->session(group => 'normal');
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

    # Set the Domain in the session
    $c->session->{Domain} = $domain;

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


   $c->log->debug('Finished auto action in Root.pm');

    # Continue processing the rest of the request
    return 1;
}
sub fetch_and_set {
    my ($self, $c, $schema, $param) = @_;
    my $value = $c->req->query_parameters->{$param};

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
        my $site = $schema->resultset('Site')->find({ name => $domain });
        if ($site) {
            $value = $site->name;
            $c->stash->{SiteName} = $value;
            $c->session->{SiteName} = $value;
        }
    }

    return $value;
}
sub fetch_and_set2 {
    my ($self, $c, $schema, $param) = @_;
    my $value = $c->req->query_parameters->{$param};

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
        my $site = $schema->resultset('Site')->find({ domain => $domain });
        if ($site) {
            $value = $site->name;
            $c->stash->{SiteName} = $value;
            $c->session->{SiteName} = $value;
        }
    }

    return $value;
}

sub site_setup {
    my ($self, $c, $SiteName) = @_;
       $SiteName = $c->session->{SiteName};
    # Log the SiteName
    $c->log->debug("SiteName: $SiteName");

    # Fetch the site details from the Site model using the SiteName
    my $site = $c->model('DBEncy::Site')->find({ name => $SiteName });

    my $css_view_name;
    if (defined $site) {
        $css_view_name = $site->css_view_name;
    } else {
        # Handle the case when the site is not found
        # For example, you can set a default value or throw an error
        $css_view_name = '/static/css/default.css';
    }

    my $site_display_name = $site ? $site->site_display_name : 'none';

    $c->stash->{site_display_name} = $site_display_name;
    $c->stash->{css_view_name} = $css_view_name;

    my $page = $c->req->param('page');

    $c->stash(
        default_css => $c->uri_for($c->stash->{css_view_name} || '/static/css/default.css'),
        menu_css => $c->uri_for('/static/css/menu.css'),
        log_css => $c->req->base->rel($c->uri_for('/static/css/log.css')),
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
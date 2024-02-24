package Comserv::Controller::Root;
use Moose;
use namespace::autoclean;
use Template;
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
    my ( $self, $c ) = @_;
    $c->log->debug('Entered auto action in Root.pm');
    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the site name from the URL
    my $SiteName = $c->req->param('site');
# Get the domain name
my $domain = $c->req->uri->host; # Add 'my' here

    # If site name is defined in the URL, update the session and stash
    if (defined $SiteName) {
        $c->stash->{SiteName} = $SiteName;
        $c->session->{SiteName} = $SiteName;
    }
    elsif (defined $c->session->{SiteName}) {
        # If site name is not defined in the URL but is defined in the session, use the session value
        $c->stash->{SiteName} = $c->session->{SiteName};
    }

    # If SiteName is defined, fetch the site details from the Site model using the SiteName
    if (defined $c->stash->{SiteName}) {
        my $site = $schema->resultset('Site')->find({ name => $c->stash->{SiteName} });
        if ($site) {
            # If the site exists in the database, fetch the associated site
            # Set the SiteName in the stash and the session to the site name from the database
            $c->stash->{SiteName} = $site->name;
            $c->session->{SiteName} = $site->name;
        }
        else {
            # If the site does not exist in the database, set SiteName to 'none'
            $c->stash->{SiteName} = 'none';
            $c->session->{SiteName} = 'none';
        }
    }
    else {
        # Get the domain name
        my $domain = $c->req->uri->host; # Add 'my' here

        # Store domain in stash
        $c->stash->{domain} = $domain;

        # Store domain in session
        $c->session->{domain} = $domain;

        # Fetch the site details from the SiteDomain model using the domain name
        my $site_domain = $schema->resultset('SiteDomain')->find({ domain => $domain });

        if ($site_domain) {
            # If the site domain exists in the database, fetch the associated site
            # Fetch the site record
            my $site = $schema->resultset('Site')->find($site_domain->site_id); # Remove 'my' here

            # Set the SiteName in the stash and the session to the site name from the database
            $c->stash->{SiteName} = $site->name;
            $c->session->{SiteName} = $site->name;
        }
        else {
            # If the site domain does not exist in the database, set SiteName to 'none'
            $c->stash->{SiteName} = 'none';
            $c->session->{SiteName} = 'none';
        }
    }

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
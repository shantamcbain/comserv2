package Comserv::Controller::Root;
use Moose;
use namespace::autoclean;
use Template;
BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => '');

sub index :Path :Args(0){
    my ($self, $c) = @_;
        my $SiteName = $c->session->{SiteName};
   # Define a hash to map site names to templates
    my %site_to_template = (
        'SunFire' => 'SunFire/SunFire.tt',
        'BMaster' => 'BMaster/BMaster.tt',
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
    # Get the domain name
    my $domain = $c->req->uri->host;

    # Store domain in stash
    $c->stash->{domain} = $domain;
  # Store domain in session
    $c->session->{domain} = $domain;
    unless ($c->session->{group}) {
        $c->session(group => 'normal');
    }
    # Get the site name from the URL
    my $SiteName = $c->req->param('site');
        $c->stash(template => 'css_form.tt');

    if (defined $SiteName) {
        # If site name is defined in the URL, update the session and stash
        $c->stash->{SiteName} = $SiteName;
        $c->session->{SiteName} = $SiteName;
    }
    elsif (defined $c->session->{SiteName}) {
        # If site name is not defined in the URL but is defined in the session, use the session value
        $c->stash->{SiteName} = $c->session->{SiteName};
    }
    else {
        # If site name is not defined in the URL or the session, check the domain and set the site accordingly
        if ($domain =~ /sunfire\.computersystemconsulting\.ca$/
            || $domain =~ /sunfiresystems\.ca$/) {
            $c->stash->{SiteName} = 'SunFire';
            $c->session->{SiteName} = 'SunFire';
        }
        elsif ($domain =~ /beemaster.ca\.ca$/
            || $domain =~ /BMaster$/) {
            $c->stash->{SiteName} = 'BMaster';
            $c->session->{SiteName} = 'BMaster';
        }
        elsif ($domain =~ /computersystemconsulting\.ca$/
            || $domain =~ /CSC$/) {
            $c->stash->{SiteName} = 'CSC';
            $c->session->{SiteName} = 'CSC';
        }
        elsif ($domain =~ /shanta\.computersystemconsulting\.ca$/
            || $domain =~ /shanta\.weaverbeck\.com$/ || $domain =~ /Shanta$/) {
            $c->stash->{SiteName} = 'Shanta';
            $c->session->{SiteName} = 'Shanta';
        }
        elsif ($domain =~ /dev\.computersystemconsulting\.ca$/ || $domain =~ /Dev$/) {
            $c->stash->{SiteName} = 'CSCDev';
            $c->session->{SiteName} = 'CSCDev';
        }
        elsif ($domain =~ /forager\.com$/ || $domain =~ /Forager$/) {
            $c->stash->{SiteName} = 'Forager';
            $c->session->{SiteName} = 'Forager';
        }
        elsif ($domain =~ /monashee\.computersystemconsulting\.ca$/
            || $domain =~ /Monashee$/) {
            $c->stash->{SiteName} = 'Monashee';
            $c->session->{SiteName} = 'Monashee';
        }
        elsif ($domain =~ /brew\.computersystemconsulting\.ca$/
            || $domain =~ /brew\.weaverbeck\.com$/ || $domain =~ /Brew$/) {
            $c->stash->{SiteName} = 'Brew';
            $c->session->{SiteName} = 'Brew';
        }
        elsif ($domain =~ /usbm\.computersystemconsulting\.ca$/
            || $domain =~ /usbm\.ca$/ || $domain =~ /USBM$/) {
            $c->stash->{SiteName} = 'USBM';
            $c->session->{SiteName} = 'USBM';
        }
        elsif ($domain =~ /weaverbeck\.computersystemconsulting\.ca$/
            || $domain =~ /weaverbeck\.com$/ || $domain =~ /WB$/) {
            $c->stash->{SiteName} = 'WB';
            $c->session->{SiteName} = 'WB';
        }
        elsif ($domain =~ /ve7tit\.weaverbeck\.com$/ || $domain =~ /ve7tit\.com$/ || $domain =~ /ve7tit$/) {
            $c->stash->{SiteName} = 've7tit';
            $c->session->{SiteName} = 've7tit';
        }
        elsif ($domain =~ /home$/ || $domain =~ /home/) {
            $c->stash->{SiteName} = 'home';
            $c->session->{SiteName} = 'home';
        }
        else {
            # If the domain does not match any condition, set SiteName to 'none'
            $c->stash->{SiteName} = 'none';
            $c->session->{SiteName} = 'none';
        }
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

sub end : ActionClass('RenderView') {}

__PACKAGE__->meta->make_immutable;

1;
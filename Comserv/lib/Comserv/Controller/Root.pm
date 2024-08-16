package Comserv::Controller::Root;

use Moose;
use namespace::autoclean;
use Template;
use Data::Dumper;
use Comserv::Model::DBSchemaManager;
use Try::Tiny;

BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => '');

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    # Logging to stash
    push @{$c->stash->{error_msg}}, "Entered index action in Root.pm";
    push @{$c->stash->{error_msg}}, "About to fetch SiteName from session";

    my $site_name = $c->session->{SiteName} // 'none';

    # Logging to stash
    push @{$c->stash->{error_msg}}, "Fetched SiteName from session: $site_name";

    if ($site_name ne 'Root') {
        push @{$c->stash->{error_msg}}, "Redirecting to controller: $site_name";
        $c->detach($site_name, 'index');
    } else {
        push @{$c->stash->{error_msg}}, "Rendering Root index";
        $c->stash(template => 'index.tt');
    }
}

sub auto :Private {
    my ($self, $c) = @_;

    my $SiteName = $c->session->{SiteName};

    if (defined $SiteName && $SiteName ne 'none') {
        push @{$c->stash->{error_msg}}, "SiteName found in session: $SiteName";
    } else {
        push @{$c->stash->{error_msg}}, "SiteName not found in session or is 'none', proceeding with domain extraction and site domain retrieval";

        my $domain = $c->req->base->host;
        push @{$c->stash->{error_msg}}, "Extracted domain: $domain";  # Log the extracted domain
        $domain =~ s/:.*//;

        try {
            my $site_domain = $c->model('Site')->get_site_domain($domain);
            #push @{$c->stash->{error_msg}}, "Retrieved site domain: " . Dumper($site_domain);

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

    $self->site_setup($c, $c->session->{SiteName});

    push @{$c->stash->{error_msg}}, 'Entered auto action in Root.pm';

    my $schema = $c->model('DBEncy');
    print "Schema: $schema\n";

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

    return 1;
}

sub fetch_and_set {
    my ($self, $c, $param) = @_;

    my $value = $c->req->query_parameters->{$param};

    # Logging to stash
    push @{$c->stash->{error_msg}}, __PACKAGE__ . " . (split '::', __SUB__)[-1] . \" line \" . __LINE__ . \":  in fetch_and_set: $value";

    if (defined $value) {
        $c->stash->{SiteName} = $value;
        $c->session->{SiteName} = $value;
    }
    elsif (defined $c->session->{SiteName}) {
        $c->stash->{SiteName} = $c->session->{SiteName};
        $c->session->{SiteName} = $value;
   }
    else {
        my $domain = $c->req->base->host;
        $domain =~ s/:.*//;

        my $site_domain = $c->model('Site')->get_site_domain($domain);
        push @{$c->stash->{error_msg}}, "fetch_and_set site_domain: $site_domain";

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

sub site_setup {
    my ($self, $c) = @_;
    my $SiteName = $c->session->{SiteName};

    unless (defined $SiteName) {
        push @{$c->stash->{error_msg}}, "SiteName is not defined in the session";
        return;
    }

    push @{$c->stash->{error_msg}}, "SiteName: $SiteName";

    my $site = $c->model('Site')->get_site_details_by_name($SiteName);

    unless (defined $site) {
        push @{$c->stash->{error_msg}}, "No site found for SiteName: $SiteName";
        return;
    }

    push @{$c->stash->{error_msg}}, "Found site: " . Dumper($site);

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
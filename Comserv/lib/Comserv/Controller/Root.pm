package Comserv::Controller::Root;

use Moose;
use namespace::autoclean;
use Template;
use Data::Dumper;
use Comserv::Model::DBSchemaManager;
use Try::Tiny;
use Carp qw(cluck);

BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => '');

sub auto :Private {
    my ($self, $c) = @_;

    push @{$c->stash->{error_msg}}, "Entered auto action in Root.pm at line " . __LINE__ . " in sub " . (caller(0))[3];

    # Check if the databases exist
    my $db_schema_manager = Comserv::Model::DBSchemaManager->new();
    unless ($db_schema_manager->are_databases_exist) {
        push @{$c->stash->{error_msg}}, "Databases do not exist at line " . __LINE__ . " in sub " . (caller(0))[3];
        if ($ENV{CATALYST_DEBUG}) {
            push @{$c->stash->{error_msg}}, "Catalyst debug mode is on at line " . __LINE__ . " in sub " . (caller(0))[3];
        } else {
            push @{$c->stash->{error_msg}}, "Catalyst debug mode is off at line " . __LINE__ . " in sub " . (caller(0))[3];
        }
        return 0;
    }

    my $SiteName = $c->session->{SiteName};

    if (defined $SiteName && $SiteName ne 'none') {
        push @{$c->stash->{error_msg}}, "SiteName found in session: $SiteName at line " . __LINE__ . " in sub " . (caller(0))[3];
    } else {
        push @{$c->stash->{error_msg}}, "SiteName not found in session or is 'none', proceeding with domain extraction and site domain retrieval at line " . __LINE__ . " in sub " . (caller(0))[3];

        my $domain = $c->req->base->host;
        push @{$c->stash->{error_msg}}, "Extracted domain: $domain at line " . __LINE__ . " in sub " . (caller(0))[3];  # Log the extracted domain
        $domain =~ s/:.*//;

        try {
            # Your existing code here
        } catch {
            push @{$c->stash->{error_msg}}, "Error during domain extraction: $_ at line " . __LINE__ . " in sub " . (caller(0))[3];
        };
    }

    $self->site_setup($c, $c->session->{SiteName});

    push @{$c->stash->{error_msg}}, 'Completed auto action in Root.pm at line ' . __LINE__ . " in sub " . (caller(0))[3];

    return 1;
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    push @{$c->stash->{error_msg}}, "Entered index action in Root.pm at line " . __LINE__ . " in sub " . (caller(0))[3];
    push @{$c->stash->{error_msg}}, "About to fetch SiteName from session at line " . __LINE__ . " in sub " . (caller(0))[3];

    my $site_name = $c->session->{SiteName} // 'none';

    push @{$c->stash->{error_msg}}, "Fetched SiteName from session: $site_name at line " . __LINE__ . " in sub " . (caller(0))[3];

    if ($site_name ne 'Root') {
        push @{$c->stash->{error_msg}}, "SiteName is not 'Root', detaching to $site_name at line " . __LINE__ . " in sub " . (caller(0))[3];
        $c->detach($site_name, 'index');
    } else {
        push @{$c->stash->{error_msg}}, "Rendering Root index at line " . __LINE__ . " in sub " . (caller(0))[3];
        $c->stash(template => 'index.tt');
    }
}

sub fetch_and_set {
    my ($self, $c, $site_id, $param) = @_;

    my $site = $c->model('Site')->get_site_details($site_id);

    if ($site) {
        $c->stash->{SiteName} = $site->name;
        $c->session->{SiteName} = $site->name;
    } else {
        $c->stash->{SiteName} = 'none';
        $c->session->{SiteName} = 'none';
    }

    return $c->stash->{SiteName};
}

sub site_setup {
    my ($self, $c) = @_;
    my $SiteName = $c->session->{SiteName};

    unless (defined $SiteName) {
        push @{$c->stash->{error_msg}}, "SiteName is not defined in the session at line " . __LINE__ . " in sub " . (caller(0))[3];
        return;
    }

    push @{$c->stash->{error_msg}}, "SiteName: $SiteName at line " . __LINE__ . " in sub " . (caller(0))[3];

    my $site = $c->model('Site')->get_site_details_by_name($SiteName);

    unless (defined $site) {
        push @{$c->stash->{error_msg}}, "No site found for SiteName: $SiteName at line " . __LINE__ . " in sub " . (caller(0))[3];
        return;
    }

    #push @{$c->stash->{error_msg}}, "Found site: " . Dumper($site) . " at line " . __LINE__ . " in sub " . (caller(0))[3];

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

sub documentation :Path('/documentation') :Args(0) {
    my ( $self, $c ) = @_;
    push @{$c->stash->{error_msg}}, "Entered documentation action in Root.pm at line " . __LINE__ . " in sub " . (caller(0))[3];
    $c->stash(template => 'Documentation/Documentation.tt');
    $c->forward($c->view('TT'));
}

sub end : ActionClass('RenderView') {
    my ($self, $c) = @_;

    if (scalar @{$c->stash->{error_msg}}) {
        $c->stash->{template} = 'error.tt';
    }
}

__PACKAGE__->meta->make_immutable;

1;
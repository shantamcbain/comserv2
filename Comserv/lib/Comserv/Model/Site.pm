package Comserv::Model::Site;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use Comserv::Util::Logging;
extends 'Catalyst::Model';
my $logging = Comserv::Util::Logging->instance;
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
has 'schema' => (
    is => 'ro',
    required => 1,
);

sub COMPONENT {
    my ($class, $app, $args) = @_;

    my $schema = $app->model('DBEncy')->schema;
    return $class->new({ %$args, schema => $schema });
}

sub get_all_sites {
    my ($self) = @_;
    $self->schema->storage->ensure_connected;
    my $site_rs = $self->schema->resultset('Site');
    my @sites = $site_rs->all;
    return \@sites;
}

sub setup_site {
    my ($self, $c, $domain) = @_;

    # Get domain from request if not provided
    $domain ||= $c->req->base->host;
    $domain =~ s/:.*//;

    $self->logging->log_with_details($c, __FILE__, __LINE__, "Setting up site for domain: $domain");

    try {
        # First check if site info exists in session
        my $site_domain = $self->get_site_domain($c, $domain);
        unless ($site_domain) {
            $self->logging->log_with_details($c, __FILE__, __LINE__, "No site domain found");
            return $self->_setup_default_site($c);
        }

        my $site = $self->get_site_details($site_domain->site_id);
        unless ($site) {
            $self->logging->log_with_details($c, __FILE__, __LINE__, "No site found");
            return $self->_setup_default_site($c);
        }

        $self->_setup_site_session($c, $site);
        return 1;
    } catch {
        $self->logging->log_error($c, "Error setting up site: $_");
        return $self->_setup_default_site($c);
    };
}


sub _setup_default_site {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, __FILE__, __LINE__, "Setting up default site");
    $c->stash(
        site_name => 'none',
        css_view_name => '/static/css/default.css',
        site_display_name => 'none',
        mail_to_admin => 'none',
        mail_replyto => 'helpdesk.computersystemconsulting.ca'
    );
    return 1;
}

sub _setup_site_session {
    my ($self, $c, $site) = @_;

    # Store site info in session
    $c->session->{site_name} = $site->name;
    $c->session->{site_display_name} = $site->site_display_name || 'none';
    $c->session->{mail_to_admin} = $site->mail_to_admin || 'none';
    $c->session->{mail_replyto} = $site->mail_replyto || 'helpdesk.computersystemconsulting.ca';
    $self->logging->log_with_details($c, __FILE__, __LINE__, "Site details set in session for site_name: " . $site->name);
}

sub setup_domain {
    my ($self, $domain) = @_;
    my $site = $self->setup_site($domain);
    return {
        site_name => $site ? $site->name : 'none',
        css_view_name => $site ? $site->css_view_name : '/static/css/default.css',
        # Add other configurations here
    };
}

sub fetch_and_set {
    my ($self, $c, $schema, $type) = @_;

    my $value;
    if ($type eq 'site') {
        my $site_domain = $c->req->base->host;
        $site_domain =~ s/:.*//;
        $value = $site_domain;
        Comserv::Util::Logging->log_with_details($c, "fetch_and_set site_domain: $site_domain");
    } elsif ($type eq 'user') {
        # Example user fetch and set logic
        my $user_id = $c->user->id;  # Assuming there's a user object in the context
        $value = $schema->resultset('User')->find($user_id)->username;
        Comserv::Util::Logging->log_with_details($c, "fetch_and_set user: $value");
    } else {
       $logging->log_with_details($c, "Unknown type '$type' in fetch_and_set");
        return undef;
    }

    # Log with details using the corrected approach
    my $sub_name = (split '::', (caller(0))[3])[-1];
    Comserv::Util::Logging->log_with_details($c, __PACKAGE__ . " $sub_name line " . __LINE__ . ": in fetch_and_set: $value");

    return $value;
}

sub site_setup {
    my ($self, $c) = @_;
    my $site_name = $c->session->{site_name};

    unless (defined $site_name) {
        Comserv::Util::Logging->log_with_details($c, "site_name is not defined in the session");
        return;
    }

    Comserv::Util::Logging->log_with_details($c, "site_name: $site_name");

    my $site = $c->model('Site')->get_site_details_by_name($site_name);

    unless (defined $site) {
        Comserv::Util::Logging->log_with_details($c, "No site found for site_name: $site_name");
        return;
    }

   #Comserv::Util::Logging->log_with_details($c, "Found site: " . Dumper($site);

    my $css_view_name = $site->css_view_name || '/static/css/default.css';
    my $site_display_name = $site->site_display_name || 'none';
    my $mail_to_admin = $site->mail_to_admin || 'none';
    my $mail_replyto = $site->mail_replyto || 'helpdesk.computersystemconsulting.ca';

    $c->session->{ScriptDisplayName} = $site_display_name;
    $c->session->{css_view_name} = $css_view_name;
    $c->session->{mail_to_admin} = $mail_to_admin;
    $c->session->{mail_replyto} = $mail_replyto;

    $c->stash(
        default_css => $c->uri_for($c->stash->{css_view_name} || '/static/css/default.css'),
        menu_css => $c->uri_for('/static/css/menu.css'),
        log_css => $c->uri_for('/static/css/log.css'),
        todo_css => $c->uri_for('/static/css/todo.css'),
    );
}

sub get_site_domain {
    my ($self, $c,  $domain) = @_;
    $logging->log_with_details($c, __FILE__, __LINE__ , "Fetching site domain for: $domain");
    try {
        my $result = $self->schema->resultset('SiteDomain')->find({ domain => $domain });
        return $result;
    } catch {
        if ($_ =~ /Table 'ency\.sitedomain' doesn't exist/) {
            Catalyst::Exception->throw("Schema update required");
        } else {
            die $_;
        }
    };
}

sub add_site {
    my ($self, $site_details) = @_;
    my $site_rs = $self->schema->resultset('Site');
    my $new_site = $site_rs->create($site_details);
    return $new_site;
}

sub update_site {
    my ($self, $site_id, $new_site_details) = @_;
    my $site_rs = $self->schema->resultset('Site');
    my $site = $site_rs->find($site_id);
    $site->update($new_site_details) if $site;
    return $site;
}

sub delete_site {
    my ($self, $site_id) = @_;
    my $site_rs = $self->schema->resultset('Site');
    my $site = $site_rs->find($site_id);
    $site->delete if $site;
    return $site;
}

sub get_site_details_by_name {
    my ($self, $site_name) = @_;
    my $site_rs = $self->schema->resultset('Site');
    return $site_rs->find({ name => $site_name });
}

sub get_site_details {
    my ($self, $site_id) = @_;
    my $site_rs = $self->schema->resultset('Site');
    my $site = $site_rs->find({ id => $site_id });
    return $site;
}

__PACKAGE__->meta->make_immutable;

1;

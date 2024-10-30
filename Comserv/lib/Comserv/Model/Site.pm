package Comserv::Model::Site;

use Moose;
use namespace::autoclean;
use Try::Tiny;
#use Comserv::Util::Logging;
extends 'Catalyst::Model';
my $logging = Comserv::Util::Logging->instance;
has 'schema' => (
    is => 'ro',
    required => 1,
);
#my $logging = Comserv::Util::Logging->instance;
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
sub get_site_details_by_domain {
    my ($self, $domain) = @_;
    my $site_domain = $self->get_site_domain($domain);
    return $site_domain ? $self->get_site_details($site_domain->site_id) : undef;
}
sub setup_domain {
    my ($self, $domain) = @_;
    my $site = $self->get_site_details_by_domain($domain);
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
    my $SiteName = $c->session->{SiteName};

    unless (defined $SiteName) {
        Comserv::Util::Logging->log_with_details($c, "SiteName is not defined in the session");
        return;
    }

    Comserv::Util::Logging->log_with_details($c, "SiteName: $SiteName");

    my $site = $c->model('Site')->get_site_details_by_name($SiteName);

    unless (defined $site) {
        Comserv::Util::Logging->log_with_details($c, "No site found for SiteName: $SiteName");
        return;
    }

   #Comserv::Util::Logging->log_with_details($c, "Found site: " . Dumper($site);

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
sub get_site_domain {
    my ($self, $domain) = @_;
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
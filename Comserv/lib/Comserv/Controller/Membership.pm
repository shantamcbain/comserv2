package Comserv::Controller::Membership;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'membership');

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub send_error_notification {
    my ($self, $c, $subject, $error_details) = @_;
    my $sitename   = $c->stash->{SiteName} || 'CSC';
    my $site       = $c->model('DBEncy')->resultset('Site')->search({ name => $sitename })->single;
    my $admin_email = ($site && $site->mail_to_admin)
        ? $site->mail_to_admin
        : 'helpdesk@computersystemconsulting.ca';
    eval {
        require Comserv::Util::EmailNotification;
        Comserv::Util::EmailNotification->new(logging => $self->logging)
            ->send_error_notification($c, $admin_email, $subject, $error_details);
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_error_notification',
            "Failed to send error notification: $@");
    }
}

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        "Membership controller auto method called");
    return 1;
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Membership index called");

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $plans     = [];
    my $user_membership = undef;

    eval {
        my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->single;
        if ($site) {
            my @rows = $c->model('DBEncy')->resultset('MembershipPlan')->search(
                { site_id => $site->id, is_active => 1 },
                { order_by => 'sort_order' }
            )->all;
            $plans = \@rows;

            if ($c->session->{user_id}) {
                $user_membership = $c->model('DBEncy')->resultset('UserMembership')->search(
                    {
                        user_id => $c->session->{user_id},
                        site_id => $site->id,
                        status  => [qw(active grace)],
                    },
                    { order_by => { -desc => 'created_at' }, rows => 1 }
                )->single;
            }
        }
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
            "Could not load membership plans (table may not exist yet): $err");
    }

    $c->stash(
        template       => 'membership/Index.tt',
        plans          => $plans,
        user_membership => $user_membership,
        site_name      => $site_name,
    );
    $c->forward($c->view('TT'));
}

sub plans :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'plans',
        "Membership plans page called");
    $c->forward('index');
}

sub account :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'account',
        "Membership account page called");

    unless ($c->session->{username}) {
        $c->flash->{error_msg} = "Please log in to view your membership.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $memberships = [];
    my $currency_account = undef;

    eval {
        my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->single;
        if ($site) {
            my @rows = $c->model('DBEncy')->resultset('UserMembership')->search(
                { user_id => $c->session->{user_id}, site_id => $site->id },
                { order_by => { -desc => 'created_at' }, prefetch => 'plan' }
            )->all;
            $memberships = \@rows;
        }

        $currency_account = $c->model('DBEncy')->resultset('InternalCurrencyAccount')->search(
            { user_id => $c->session->{user_id} }
        )->single;
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'account',
            "Could not load membership account data: $err");
    }

    $c->stash(
        template         => 'membership/Account.tt',
        memberships      => $memberships,
        currency_account => $currency_account,
    );
    $c->forward($c->view('TT'));
}

sub subscribe :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'subscribe',
        "Membership subscribe page called");

    unless ($c->session->{username}) {
        $c->session->{post_login_redirect} = $c->req->uri->as_string;
        $c->flash->{error_msg} = "Please log in to subscribe.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $plan_id = $c->req->param('plan_id');
    my $plan    = undef;

    if ($plan_id) {
        eval {
            $plan = $c->model('DBEncy')->resultset('MembershipPlan')->find($plan_id);
        };
        if ($@) {
            my $err = "$@";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'subscribe',
                "Error loading plan: $err");
        }
    }

    $c->stash(
        template => 'membership/Subscribe.tt',
        plan     => $plan,
    );
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;

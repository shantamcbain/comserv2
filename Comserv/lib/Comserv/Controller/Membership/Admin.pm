package Comserv::Controller::Membership::Admin;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'membership/admin');

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub _is_admin {
    my ($self, $c) = @_;
    return 0 unless $c->session->{username};
    my $roles = $c->session->{roles};
    if (ref $roles eq 'ARRAY') {
        return 1 if grep { lc($_) eq 'admin' || lc($_) eq 'site_admin' } @$roles;
    } elsif ($roles) {
        return 1 if lc($roles) eq 'admin' || lc($roles) eq 'site_admin';
    }
    return 0;
}

sub _require_admin {
    my ($self, $c) = @_;
    unless ($self->_is_admin($c)) {
        $c->flash->{error_msg} = 'Administrator access required.';
        $c->response->redirect($c->uri_for('/user/login'));
        return 0;
    }
    return 1;
}

sub _get_site {
    my ($self, $c) = @_;
    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $site;
    eval {
        $site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->single;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_get_site',
            "Could not look up site '$site_name': $@");
    }
    return $site;
}

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        "Membership::Admin controller called");
    return 1;
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Membership admin index called");

    my $site        = $self->_get_site($c);
    my $plan_count  = 0;
    my $member_count = 0;
    my $revenue_month = 0;

    eval {
        if ($site) {
            $plan_count = $c->model('DBEncy')->resultset('MembershipPlan')->count(
                { site_id => $site->id, is_active => 1 }
            );
            $member_count = $c->model('DBEncy')->resultset('UserMembership')->count(
                { site_id => $site->id, status => ['active', 'grace'] }
            );
            my @active = $c->model('DBEncy')->resultset('UserMembership')->search(
                { site_id => $site->id, status => 'active' },
                { prefetch => 'plan' }
            )->all;
            for my $m (@active) {
                $revenue_month += $m->price_paid || 0 if $m->billing_cycle eq 'monthly';
                $revenue_month += ($m->price_paid || 0) / 12 if $m->billing_cycle eq 'annual';
            }
        }
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
            "Error loading membership admin stats: $err");
    }

    $c->stash(
        template     => 'membership/admin/Index.tt',
        site         => $site,
        plan_count   => $plan_count,
        member_count => $member_count,
        revenue_month => sprintf('%.2f', $revenue_month),
    );
    $c->forward($c->view('TT'));
}

sub manage_plans :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'manage_plans',
        "Manage plans called");

    my $site  = $self->_get_site($c);
    my @plans = ();

    eval {
        if ($site) {
            @plans = $c->model('DBEncy')->resultset('MembershipPlan')->search(
                { site_id => $site->id },
                { order_by => 'sort_order' }
            )->all;
        }
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'manage_plans',
            "Error loading plans: $err");
        $c->flash->{error_msg} = "Error loading plans: $err";
    }

    $c->stash(
        template => 'membership/admin/ManagePlans.tt',
        site     => $site,
        plans    => \@plans,
    );
    $c->forward($c->view('TT'));
}

sub create_plan :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_plan',
        "Create plan called, method=" . $c->req->method);

    my $site = $self->_get_site($c);
    unless ($site) {
        $c->flash->{error_msg} = 'Site not found.';
        $c->response->redirect($c->uri_for('/membership/admin/manage_plans'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $p = $c->req->params;
        eval {
            $c->model('DBEncy')->resultset('MembershipPlan')->create({
                site_id            => $site->id,
                name               => $p->{name},
                slug               => lc($p->{slug} || $p->{name}),
                description        => $p->{description},
                price_monthly      => $p->{price_monthly}  || 0,
                price_annual       => $p->{price_annual}   || 0,
                price_currency     => $p->{price_currency} || 'USD',
                ai_models_allowed  => $p->{ai_models_allowed} || '[]',
                ai_requests_per_day => $p->{ai_requests_per_day} || 0,
                has_email          => $p->{has_email}      ? 1 : 0,
                email_addresses    => $p->{email_addresses} || 0,
                has_hosting        => $p->{has_hosting}    ? 1 : 0,
                hosting_tier       => $p->{hosting_tier}   || undef,
                has_subdomain      => $p->{has_subdomain}  ? 1 : 0,
                has_custom_domain  => $p->{has_custom_domain} ? 1 : 0,
                has_beekeeping     => $p->{has_beekeeping} ? 1 : 0,
                has_planning       => $p->{has_planning}   ? 1 : 0,
                has_currency       => $p->{has_currency}   ? 1 : 0,
                currency_bonus     => $p->{currency_bonus} || 0,
                max_services       => $p->{max_services}   || 1,
                sort_order         => $p->{sort_order}     || 0,
                is_active          => $p->{is_active}      ? 1 : 0,
                is_featured        => $p->{is_featured}    ? 1 : 0,
            });
        };
        if ($@) {
            my $err = "$@";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_plan',
                "Failed to create plan: $err");
            $c->flash->{error_msg} = "Failed to create plan: $err";
        } else {
            $c->flash->{success_msg} = "Plan '" . $p->{name} . "' created successfully.";
        }
        $c->response->redirect($c->uri_for('/membership/admin/manage_plans'));
        return;
    }

    $c->stash(
        template => 'membership/admin/EditPlan.tt',
        site     => $site,
        plan     => undef,
        action   => 'create',
    );
    $c->forward($c->view('TT'));
}

sub edit_plan :Local :Args(1) {
    my ($self, $c, $plan_id) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_plan',
        "Edit plan called for plan_id=$plan_id");

    my $site = $self->_get_site($c);
    my $plan = undef;

    eval {
        $plan = $c->model('DBEncy')->resultset('MembershipPlan')->find($plan_id);
    };
    unless ($plan) {
        $c->flash->{error_msg} = 'Plan not found.';
        $c->response->redirect($c->uri_for('/membership/admin/manage_plans'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $p = $c->req->params;
        eval {
            $plan->update({
                name               => $p->{name},
                slug               => lc($p->{slug} || $p->{name}),
                description        => $p->{description},
                price_monthly      => $p->{price_monthly}  || 0,
                price_annual       => $p->{price_annual}   || 0,
                price_currency     => $p->{price_currency} || 'USD',
                ai_models_allowed  => $p->{ai_models_allowed} || '[]',
                ai_requests_per_day => $p->{ai_requests_per_day} || 0,
                has_email          => $p->{has_email}      ? 1 : 0,
                email_addresses    => $p->{email_addresses} || 0,
                has_hosting        => $p->{has_hosting}    ? 1 : 0,
                hosting_tier       => $p->{hosting_tier}   || undef,
                has_subdomain      => $p->{has_subdomain}  ? 1 : 0,
                has_custom_domain  => $p->{has_custom_domain} ? 1 : 0,
                has_beekeeping     => $p->{has_beekeeping} ? 1 : 0,
                has_planning       => $p->{has_planning}   ? 1 : 0,
                has_currency       => $p->{has_currency}   ? 1 : 0,
                currency_bonus     => $p->{currency_bonus} || 0,
                max_services       => $p->{max_services}   || 1,
                sort_order         => $p->{sort_order}     || 0,
                is_active          => $p->{is_active}      ? 1 : 0,
                is_featured        => $p->{is_featured}    ? 1 : 0,
            });
        };
        if ($@) {
            my $err = "$@";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_plan',
                "Failed to update plan: $err");
            $c->flash->{error_msg} = "Failed to update plan: $err";
        } else {
            $c->flash->{success_msg} = "Plan updated successfully.";
        }
        $c->response->redirect($c->uri_for('/membership/admin/manage_plans'));
        return;
    }

    $c->stash(
        template => 'membership/admin/EditPlan.tt',
        site     => $site,
        plan     => $plan,
        action   => 'edit',
    );
    $c->forward($c->view('TT'));
}

sub delete_plan :Local :Args(1) {
    my ($self, $c, $plan_id) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_plan',
        "Delete plan called for plan_id=$plan_id");

    eval {
        my $plan = $c->model('DBEncy')->resultset('MembershipPlan')->find($plan_id);
        if ($plan) {
            my $member_count = $c->model('DBEncy')->resultset('UserMembership')->count(
                { plan_id => $plan_id, status => ['active', 'grace'] }
            );
            if ($member_count > 0) {
                $c->flash->{error_msg} = "Cannot delete plan: $member_count active members. Deactivate instead.";
            } else {
                $plan->delete;
                $c->flash->{success_msg} = 'Plan deleted.';
            }
        } else {
            $c->flash->{error_msg} = 'Plan not found.';
        }
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_plan',
            "Failed to delete plan: $err");
        $c->flash->{error_msg} = "Error: $err";
    }

    $c->response->redirect($c->uri_for('/membership/admin/manage_plans'));
}

sub toggle_plan :Local :Args(1) {
    my ($self, $c, $plan_id) = @_;
    return unless $self->_require_admin($c);

    eval {
        my $plan = $c->model('DBEncy')->resultset('MembershipPlan')->find($plan_id);
        if ($plan) {
            $plan->update({ is_active => $plan->is_active ? 0 : 1 });
            $c->flash->{success_msg} = 'Plan ' . ($plan->is_active ? 'deactivated' : 'activated') . '.';
        }
    };
    if ($@) {
        $c->flash->{error_msg} = "Error: $@";
    }

    $c->response->redirect($c->uri_for('/membership/admin/manage_plans'));
}

sub subscribers :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'subscribers',
        "Subscribers list called");

    my $status_filter  = $c->req->param('status')  || '';
    my $site_id_filter = $c->req->param('site_id') || '';
    my @memberships    = ();
    my @all_sites      = ();

    eval {
        @all_sites = $c->model('DBEncy')->resultset('Site')->search(
            {}, { order_by => 'name' }
        )->all;
    };

    eval {
        my %search = ();
        $search{'me.status'}  = $status_filter  if $status_filter;
        $search{'me.site_id'} = $site_id_filter if $site_id_filter;

        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'subscribers',
            "Querying memberships with status=" . ($status_filter || 'all')
            . " site_id=" . ($site_id_filter || 'all'));

        @memberships = $c->model('DBEncy')->resultset('UserMembership')->search(
            \%search,
            {
                prefetch => ['user', 'plan', 'site'],
                order_by => { -desc => 'me.created_at' },
                rows     => 200,
            }
        )->all;

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'subscribers',
            "Loaded " . scalar(@memberships) . " memberships");
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'subscribers',
            "Error loading subscribers: $err");
        $c->stash->{error_msg} = "Error loading subscribers: see application log for details.";
    }

    $c->stash(
        template       => 'membership/admin/Subscribers.tt',
        memberships    => \@memberships,
        all_sites      => \@all_sites,
        status_filter  => $status_filter,
        site_id_filter => $site_id_filter,
    );
    $c->forward($c->view('TT'));
}

sub cost_tracking :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'cost_tracking',
        "Cost tracking called");

    my $site  = $self->_get_site($c);
    my @costs = ();
    my $total_cost = 0;
    my $total_revenue = 0;

    if ($c->req->method eq 'POST') {
        my $p = $c->req->params;
        eval {
            $c->model('DBEncy')->resultset('SystemCostTracking')->create({
                cost_category     => $p->{cost_category},
                description       => $p->{description},
                amount            => $p->{amount},
                currency          => $p->{currency} || 'USD',
                site_id           => ($p->{is_global} ? undef : ($site ? $site->id : undef)),
                period_start      => $p->{period_start},
                period_end        => $p->{period_end},
                is_recurring      => $p->{is_recurring} ? 1 : 0,
                vendor            => $p->{vendor},
                invoice_reference => $p->{invoice_reference},
                created_by        => $c->session->{user_id},
            });
            $c->flash->{success_msg} = 'Cost entry added.';
        };
        if ($@) {
            my $err = "$@";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'cost_tracking',
                "Error adding cost: $err");
            $c->flash->{error_msg} = "Error adding cost: $err";
        }
    }

    eval {
        my %search = ();
        $search{'-or'} = [
            { site_id => undef },
            { site_id => $site->id }
        ] if $site;
        @costs = $c->model('DBEncy')->resultset('SystemCostTracking')->search(
            \%search,
            { order_by => { -desc => 'period_start' }, rows => 200 }
        )->all;
        $total_cost += $_->amount for @costs;

        if ($site) {
            my @active = $c->model('DBEncy')->resultset('UserMembership')->search(
                { site_id => $site->id, status => 'active' },
                { prefetch => 'plan' }
            )->all;
            for my $m (@active) {
                $total_revenue += $m->price_paid || 0 if $m->billing_cycle eq 'monthly';
                $total_revenue += ($m->price_paid || 0) / 12 if $m->billing_cycle eq 'annual';
            }
        }
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'cost_tracking',
            "Error loading costs: $err");
    }

    $c->stash(
        template      => 'membership/admin/CostTracking.tt',
        site          => $site,
        costs         => \@costs,
        total_cost    => sprintf('%.2f', $total_cost),
        total_revenue => sprintf('%.2f', $total_revenue),
        net           => sprintf('%.2f', $total_revenue - $total_cost),
    );
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;

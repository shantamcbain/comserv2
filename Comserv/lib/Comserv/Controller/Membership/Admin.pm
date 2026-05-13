package Comserv::Controller::Membership::Admin;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON;
use Comserv::Util::Logging;
use Comserv::Util::PointSystem;
use Comserv::Util::EmailNotification;

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
    my @memberships    = ();
    my @all_sites      = ();
    my $current_site   = $self->_get_site($c);

    eval {
        @all_sites = $c->model('DBEncy')->resultset('Site')->search(
            {}, { order_by => 'name' }
        )->all;
    };

    my $site_id_filter = $c->req->param('site_id');
    if (!defined $site_id_filter) {
        $site_id_filter = $current_site ? $current_site->id : '';
    } elsif ($site_id_filter eq '0' || $site_id_filter eq 'all') {
        $site_id_filter = '';
    }

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

    my $total_monthly_cost  = 0;
    my $active_member_count = 0;
    my %cat_group_totals    = ();
    my @category_totals     = ();
    my @pricing_recommendation = ();

    my %cat_group_labels = (
        facility    => 'Facility & Power (electricity, cooling, rent, UPS)',
        hardware    => 'Hardware (servers, network, storage, workstations)',
        connectivity => 'Connectivity (ISP, IP addressing, CDN)',
        hosting     => 'Hosting & Domains (cloud, domains, SSL, backup)',
        ai          => 'AI & Compute (Ollama/GPU, xAI, OpenAI, Anthropic)',
        software    => 'Software & Licensing (OS, tools, monitoring, security)',
        communication => 'Communication (email, SMS)',
        personnel   => 'Personnel & Services (dev, sysadmin, support, legal)',
        compliance  => 'Compliance & Risk (insurance, audits)',
        other       => 'Other',
    );

    my %cat_to_group = (
        power_electricity    => 'facility',
        cooling_hvac         => 'facility',
        server_room_rent     => 'facility',
        hardware_ups         => 'facility',
        hardware_servers     => 'hardware',
        hardware_network     => 'hardware',
        hardware_storage     => 'hardware',
        hardware_workstations => 'hardware',
        isp_primary          => 'connectivity',
        isp_backup           => 'connectivity',
        ip_addressing        => 'connectivity',
        cdn                  => 'connectivity',
        hosting_cloud        => 'hosting',
        domain_registration  => 'hosting',
        ssl_certificates     => 'hosting',
        backup_services      => 'hosting',
        ai_ollama_gpu        => 'ai',
        ai_xai               => 'ai',
        ai_openai            => 'ai',
        ai_anthropic         => 'ai',
        ai_other             => 'ai',
        software_os          => 'software',
        software_licenses    => 'software',
        software_monitoring  => 'software',
        software_security    => 'software',
        email_service        => 'communication',
        sms_notifications    => 'communication',
        programming_labor    => 'personnel',
        sysadmin_labor       => 'personnel',
        customer_support     => 'personnel',
        accounting_legal     => 'personnel',
        insurance            => 'compliance',
        security_audit       => 'compliance',
    );

    eval {
        my %search = ();
        $search{'-or'} = [
            { 'me.site_id' => undef },
            { 'me.site_id' => $site->id }
        ] if $site;
        @costs = $c->model('DBEncy')->resultset('SystemCostTracking')->search(
            \%search,
            { order_by => { -desc => 'period_start' }, rows => 200 }
        )->all;

        for my $c_entry (@costs) {
            my $monthly = eval { $c_entry->monthly_equivalent } || $c_entry->amount;
            $total_cost         += $c_entry->amount;
            $total_monthly_cost += $monthly;
            my $grp = $cat_to_group{ $c_entry->cost_category } || 'other';
            $cat_group_totals{$grp} += $monthly;
        }

        if ($site) {
            my @active = $c->model('DBEncy')->resultset('UserMembership')->search(
                { 'me.site_id' => $site->id, 'me.status' => 'active' },
                { prefetch => 'plan' }
            )->all;
            $active_member_count = scalar @active;
            for my $m (@active) {
                $total_revenue += $m->price_paid || 0 if $m->billing_cycle eq 'monthly';
                $total_revenue += ($m->price_paid || 0) / 12 if $m->billing_cycle eq 'annual';
            }
        }

        for my $grp (sort keys %cat_group_totals) {
            push @category_totals, {
                label   => $cat_group_labels{$grp} || $grp,
                monthly => sprintf('%.2f', $cat_group_totals{$grp}),
            };
        }

        if ($total_monthly_cost > 0 && $active_member_count > 0) {
            my $overhead       = 1.30;
            my $base_per_member = ($total_monthly_cost * $overhead) / $active_member_count;
            push @pricing_recommendation, (
                {
                    name    => 'Free',
                    monthly => '0.00',
                    annual  => '0.00',
                    notes   => 'No revenue; subsidized by paid tiers. Keep features minimal.',
                },
                {
                    name    => 'Basic',
                    monthly => sprintf('%.2f', $base_per_member * 0.6),
                    annual  => sprintf('%.2f', $base_per_member * 0.6 * 10),
                    notes   => 'Below break-even — relies on Pro/Business to offset.',
                },
                {
                    name    => 'Pro',
                    monthly => sprintf('%.2f', $base_per_member * 1.2),
                    annual  => sprintf('%.2f', $base_per_member * 1.2 * 10),
                    notes   => 'Slightly above break-even; target majority of paid members.',
                },
                {
                    name    => 'Business',
                    monthly => sprintf('%.2f', $base_per_member * 2.5),
                    annual  => sprintf('%.2f', $base_per_member * 2.5 * 10),
                    notes   => 'Premium tier — funds free/basic subsidies and growth.',
                },
            );
        }
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'cost_tracking',
            "Error loading costs: $err");
    }

    my $monthly_cost_per_member = ($active_member_count > 0)
        ? sprintf('%.2f', $total_monthly_cost / $active_member_count)
        : undef;

    my $overhead          = 1.30;
    my $avg_plan_price    = 15;
    my $break_even_members = ($total_monthly_cost > 0)
        ? int(($total_monthly_cost * $overhead) / $avg_plan_price) + 1
        : 0;

    my @benefactor_contribs = ();
    my $benefactor_total_cad = 0;
    eval {
        @benefactor_contribs = $c->model('DBEncy')->resultset('Accounting::BenefactorContribution')->search(
            {},
            {
                prefetch => 'user',
                order_by => { -desc => 'contribution_date' },
                rows     => 200,
            }
        )->all;
        for my $bc (@benefactor_contribs) {
            $benefactor_total_cad += $bc->total_value_cad;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'cost_tracking',
            "Could not load benefactor contributions (table may not exist yet): $@");
    }

    $c->stash(
        template                => 'membership/admin/CostTracking.tt',
        site                    => $site,
        costs                   => \@costs,
        total_cost              => sprintf('%.2f', $total_cost),
        total_monthly_cost      => sprintf('%.2f', $total_monthly_cost),
        total_revenue           => sprintf('%.2f', $total_revenue),
        net                     => sprintf('%.2f', $total_revenue - $total_monthly_cost),
        category_totals         => \@category_totals,
        monthly_cost_per_member => $monthly_cost_per_member,
        active_member_count     => $active_member_count,
        break_even_members      => $break_even_members,
        overhead_pct            => 30,
        pricing_recommendation  => \@pricing_recommendation,
        default_currency        => 'CAD',
        benefactor_contribs     => \@benefactor_contribs,
        benefactor_total_cad    => sprintf('%.2f', $benefactor_total_cad),
    );
    $c->forward($c->view('TT'));
}

sub benefactor_contribution :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'benefactor_contribution',
        "Benefactor contribution called, method=" . $c->req->method);

    if ($c->req->method eq 'POST') {
        my $p = $c->req->params;

        my $amount_cad = $p->{amount_cad} || 0;
        my $hours      = $p->{hours}      || 0;
        my $rate       = $p->{hourly_rate_cad} || 75;
        if ($hours > 0 && $amount_cad == 0) {
            $amount_cad = $hours * $rate;
        }

        my $coins = $amount_cad;

        eval {
            $c->model('DBEncy')->schema->txn_do(sub {
                my $contrib = $c->model('DBEncy')->resultset('Accounting::BenefactorContribution')->create({
                    user_id           => $p->{user_id},
                    contribution_type => $p->{contribution_type},
                    description       => $p->{description},
                    amount_cad        => $amount_cad,
                    hours             => $hours,
                    hourly_rate_cad   => $rate,
                    coins_credited    => $coins,
                    cost_tracking_id  => $p->{cost_tracking_id} || undef,
                    contribution_date => $p->{contribution_date},
                });

                my $ps = Comserv::Util::PointSystem->new(c => $c);
                my $ledger = $ps->credit(
                    user_id          => $p->{user_id},
                    amount           => $coins,
                    transaction_type => 'bonus',
                    description      => 'Benefactor contribution: ' . ($p->{description} || $p->{contribution_type}),
                    reference_type   => 'benefactor_contribution',
                    reference_id     => $contrib->id,
                );

                $contrib->update({ currency_transaction_id => $ledger->id });
            });
            $c->flash->{success_msg} = sprintf(
                'Contribution recorded. %.2f CAD value credited as %.2f coins.', $amount_cad, $coins);
        };
        if ($@) {
            my $err = "$@";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'benefactor_contribution',
                "Error recording contribution: $err");
            $c->flash->{error_msg} = "Error recording contribution: see application log for details.";
        }
        $c->response->redirect($c->uri_for('/membership/admin/cost_tracking'));
        return;
    }

    my @users = ();
    eval {
        @users = $c->model('DBEncy')->resultset('User')->search(
            {}, { order_by => 'username', columns => ['id','username','first_name','last_name'] }
        )->all;
    };

    $c->stash(
        template => 'membership/admin/BenefactorContribution.tt',
        users    => \@users,
    );
    $c->forward($c->view('TT'));
}

# ============================================================
# Patreon Settings (per-site)
# ============================================================
sub patreon_settings :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    my $site      = $self->_get_site($c);
    my $site_name = $site ? lc($site->name) : 'csc';
    my $uid       = $c->session->{user_id};

    my @KEYS = qw(url email active);

    if ($c->req->method eq 'POST') {
        my $rs = $c->model('DBEncy')->resultset('EnvVariable');
        for my $k (@KEYS) {
            my $val = $c->req->param($k) // '';
            $val = ($val ? '1' : '0') if $k eq 'active';
            eval {
                $rs->update_or_create(
                    {
                        key        => "patreon_${site_name}_${k}",
                        value      => $val,
                        var_type   => 'string',
                        is_secret  => 0,
                        updated_by => $uid,
                    },
                    { key => 'key_unique' }
                );
            };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                    'patreon_settings', "Error saving patreon_${site_name}_${k}: $@");
            }
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'patreon_settings', "Patreon settings saved for site=$site_name by uid=$uid");
        $c->flash->{success_msg} = 'Patreon settings saved.';
        $c->response->redirect($c->uri_for('/membership/admin/patreon_settings'));
        return;
    }

    my %current;
    eval {
        my @rows = $c->model('DBEncy')->resultset('EnvVariable')->search(
            { key => { -like => "patreon_${site_name}_%" } }
        )->all;
        for my $row (@rows) {
            my $k = $row->key;
            $k =~ s/^patreon_${site_name}_//;
            $current{$k} = $row->value;
        }
    };

    my @all_sites;
    eval {
        @all_sites = $c->model('DBEncy')->resultset('Site')->search({}, { order_by => 'name' })->all;
    };

    $c->stash(
        template    => 'membership/admin/PatreonSettings.tt',
        current     => \%current,
        site        => $site,
        site_name   => $site_name,
        all_sites   => \@all_sites,
    );
    $c->forward($c->view('TT'));
}

# ============================================================
# PayPal Settings
# ============================================================
sub paypal_settings :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    my %FIELDS = (
        paypal_sandbox    => { label => 'Sandbox Mode',      secret => 0, type => 'boolean' },
        paypal_business   => { label => 'PayPal Business Email', secret => 0, type => 'string' },
        paypal_currency   => { label => 'Currency Code',     secret => 0, type => 'string' },
        paypal_client_id  => { label => 'REST Client ID (optional)', secret => 0, type => 'string' },
        paypal_secret     => { label => 'REST Secret (optional)',     secret => 1, type => 'string' },
    );

    if ($c->req->method eq 'POST') {
        my $rs = $c->model('DBEncy')->resultset('EnvVariable');
        my $uid = $c->session->{user_id};

        my %VALID_CURRENCIES = map { $_ => 1 } qw(CAD USD AUD GBP EUR NZD CHF JPY HKD SGD);

        for my $key (keys %FIELDS) {
            my $val = $c->req->param($key) // '';
            $val = ($val ? '1' : '0') if $FIELDS{$key}{type} eq 'boolean';
            if ($key eq 'paypal_currency') {
                $val = uc($val);
                $val = 'CAD' unless $VALID_CURRENCIES{$val};
            }

            eval {
                $rs->update_or_create(
                    {
                        key        => $key,
                        value      => $val,
                        var_type   => $FIELDS{$key}{type},
                        is_secret  => $FIELDS{$key}{secret} ? 1 : 0,
                        updated_by => $uid,
                    },
                    { key => 'key_unique' }
                );
            };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                    'paypal_settings', "Error saving $key: $@");
            }
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'paypal_settings', "PayPal settings updated by user_id=$uid");
        $c->flash->{success_msg} = 'PayPal settings saved.';
        $c->response->redirect($c->uri_for('/membership/admin/paypal_settings'));
        return;
    }

    my %current;
    eval {
        my @rows = $c->model('DBEncy')->resultset('EnvVariable')->search(
            { key => { -in => [keys %FIELDS] } }
        )->all;
        $current{$_->key} = $_->value for @rows;
    };

    $current{paypal_sandbox}  //= $c->config->{PayPal}{sandbox}       // '1';
    $current{paypal_business} //= $c->config->{PayPal}{business}      // '';
    $current{paypal_currency} //= $c->config->{PayPal}{currency_code} // 'USD';

    $c->stash(
        template => 'membership/admin/PaypalSettings.tt',
        current  => \%current,
        fields   => \%FIELDS,
    );
    $c->forward($c->view('TT'));
}

sub subscriber_details :Local :Args(1) {
    my ($self, $c, $membership_id) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'subscriber_details',
        "Subscriber details called for membership_id=$membership_id");

    my $membership = undef;
    my @service_access = ();

    eval {
        $membership = $c->model('DBEncy')->resultset('UserMembership')->find(
            $membership_id,
            { prefetch => ['user', 'plan', 'site'] }
        );
    };
    unless ($membership) {
        $c->flash->{error_msg} = 'Membership record not found.';
        $c->response->redirect($c->uri_for('/membership/admin/subscribers'));
        return;
    }

    eval {
        @service_access = $c->model('DBEncy')->resultset('MembershipServiceAccess')->search(
            {
                user_id => $membership->user_id,
                site_id => $membership->site_id,
            },
            { order_by => 'service_name' }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'subscriber_details',
            "Could not load service access: $@");
    }

    $c->stash(
        template       => 'membership/admin/SubscriberDetails.tt',
        membership     => $membership,
        service_access => \@service_access,
    );
    $c->forward($c->view('TT'));
}

sub grant_access :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'grant_access',
        "Grant access called, method=" . $c->req->method);

    unless ($c->req->method eq 'POST') {
        $c->flash->{error_msg} = 'Invalid request.';
        $c->response->redirect($c->uri_for('/membership/admin/subscribers'));
        return;
    }

    my $p = $c->req->params;
    my $user_id      = $p->{user_id};
    my $site_id      = $p->{site_id};
    my $service_name = $p->{service_name};
    my $membership_id = $p->{membership_id};
    my $expires_at   = $p->{expires_at} || undef;

    unless ($user_id && $site_id && $service_name) {
        $c->flash->{error_msg} = 'Missing required fields.';
        $c->response->redirect($c->uri_for('/membership/admin/subscribers'));
        return;
    }

    eval {
        $c->model('DBEncy')->resultset('MembershipServiceAccess')->update_or_create(
            {
                user_id      => $user_id,
                site_id      => $site_id,
                service_name => $service_name,
                granted_by   => 'admin',
                membership_id => $membership_id || undef,
                is_active    => 1,
                expires_at   => $expires_at || undef,
            },
            { key => 'unique_user_site_service' }
        );
        $c->flash->{success_msg} = "Access to '$service_name' granted.";
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'grant_access',
            "Error granting access: $err");
        $c->flash->{error_msg} = "Error granting access: $err";
    }

    my $back = $membership_id
        ? $c->uri_for('/membership/admin/subscriber_details', $membership_id)
        : $c->uri_for('/membership/admin/subscribers');
    $c->response->redirect($back);
}

sub revoke_access :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'revoke_access',
        "Revoke access called, method=" . $c->req->method);

    unless ($c->req->method eq 'POST') {
        $c->flash->{error_msg} = 'Invalid request.';
        $c->response->redirect($c->uri_for('/membership/admin/subscribers'));
        return;
    }

    my $p            = $c->req->params;
    my $access_id    = $p->{access_id};
    my $membership_id = $p->{membership_id};

    unless ($access_id && $access_id =~ /^\d+$/) {
        $c->flash->{error_msg} = 'Invalid access record.';
        $c->response->redirect($c->uri_for('/membership/admin/subscribers'));
        return;
    }

    eval {
        my $row = $c->model('DBEncy')->resultset('MembershipServiceAccess')->find($access_id);
        if ($row) {
            $row->update({ is_active => 0 });
            $c->flash->{success_msg} = "Access to '" . $row->service_name . "' revoked.";
        } else {
            $c->flash->{error_msg} = 'Access record not found.';
        }
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'revoke_access',
            "Error revoking access: $err");
        $c->flash->{error_msg} = "Error revoking access: $err";
    }

    my $back = $membership_id
        ? $c->uri_for('/membership/admin/subscriber_details', $membership_id)
        : $c->uri_for('/membership/admin/subscribers');
    $c->response->redirect($back);
}

sub pricing :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'pricing',
        "Geographic pricing called, method=" . $c->req->method);

    my $site  = $self->_get_site($c);
    my @plans = ();
    my @pricing_rows = ();

    eval {
        if ($site) {
            @plans = $c->model('DBEncy')->resultset('MembershipPlan')->search(
                { site_id => $site->id, is_active => 1 },
                { order_by => 'sort_order' }
            )->all;
        }
    };

    my $selected_plan_id = $c->req->param('plan_id');

    if ($c->req->method eq 'POST') {
        my $p      = $c->req->params;
        my $action = $p->{action} || 'add';

        if ($action eq 'delete' && $p->{pricing_id} && $p->{pricing_id} =~ /^\d+$/) {
            eval {
                my $row = $c->model('DBEncy')->resultset('MembershipPlanPricing')->find($p->{pricing_id});
                $row->delete if $row;
                $c->flash->{success_msg} = 'Pricing entry deleted.';
            };
            if ($@) {
                $c->flash->{error_msg} = "Error deleting entry: $@";
            }
        } elsif ($p->{plan_id} && $p->{region_code} && defined $p->{price_monthly}) {
            eval {
                $c->model('DBEncy')->resultset('MembershipPlanPricing')->update_or_create(
                    {
                        plan_id       => $p->{plan_id},
                        region_code   => uc($p->{region_code}),
                        price_monthly => $p->{price_monthly} || 0,
                        price_annual  => $p->{price_annual}  || 0,
                        currency      => $p->{currency}      || 'USD',
                    },
                    { key => 'plan_id_region_code' }
                );
                $c->flash->{success_msg} = 'Pricing entry saved.';
            };
            if ($@) {
                my $err = "$@";
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'pricing',
                    "Error saving pricing: $err");
                $c->flash->{error_msg} = "Error saving pricing: $err";
            }
            $selected_plan_id = $p->{plan_id};
        } else {
            $c->flash->{error_msg} = 'Missing required fields (plan, region, price).';
        }

        my $redirect = $c->uri_for('/membership/admin/pricing');
        $redirect .= '?plan_id=' . $selected_plan_id if $selected_plan_id;
        $c->response->redirect($redirect);
        return;
    }

    if ($selected_plan_id) {
        eval {
            @pricing_rows = $c->model('DBEncy')->resultset('MembershipPlanPricing')->search(
                { plan_id => $selected_plan_id },
                { prefetch => 'plan', order_by => 'region_code' }
            )->all;
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'pricing',
                "Could not load pricing rows: $@");
        }
    }

    $c->stash(
        template         => 'membership/admin/Pricing.tt',
        site             => $site,
        plans            => \@plans,
        pricing_rows     => \@pricing_rows,
        selected_plan_id => $selected_plan_id,
    );
    $c->forward($c->view('TT'));
}

sub add_cost :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_cost',
        "Add cost called");

    $c->response->redirect($c->uri_for('/membership/admin/cost_tracking'));
}

sub seed_hosting_plans :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || '';
    unless (lc($site_name) eq 'csc') {
        $c->flash->{error_msg} = 'Hosting plan seeding is only available on the CSC site.';
        $c->response->redirect($c->uri_for('/membership/admin'));
        return;
    }

    my $db     = $c->model('DBEncy');
    my $csc    = $db->resultset('Site')->search({ name => 'CSC' })->single;
    unless ($csc) {
        $c->flash->{error_msg} = 'CSC site not found in database.';
        $c->response->redirect($c->uri_for('/membership/admin'));
        return;
    }

    my @hosting_plans = (
        {
            name             => 'Subdomain Hosting',
            slug             => 'hosting-subdomain',
            description      => 'Get your own subdomain on any registered SiteName domain (e.g. you.forager.com). Your site runs as an app on the CSC platform — no cPanel required. Includes full access to ENCY, AI tools, and planning modules.',
            price_monthly    => '6.00',
            price_annual     => '60.00',
            price_currency   => 'CAD',
            ai_models_allowed   => '["llama3.2","mistral"]',
            ai_requests_per_day => 20,
            has_email        => 0, email_addresses => 0,
            has_hosting      => 1, hosting_tier => 'app-subdomain',
            has_subdomain    => 1, has_custom_domain => 0,
            has_beekeeping   => 0, has_planning => 1,
            has_currency     => 1, currency_bonus => '25.00',
            max_services     => 3, sort_order => 10,
            is_active        => 1, is_featured => 0,
        },
        {
            name             => 'App-Only Hosting',
            slug             => 'hosting-app',
            description      => 'Host your own standalone application on the CSC platform. Bring your own domain or use a CSC sub-path. Ideal for co-ops, clubs, or small businesses that need a managed web presence without the overhead of a cPanel account.',
            price_monthly    => '15.00',
            price_annual     => '150.00',
            price_currency   => 'CAD',
            ai_models_allowed   => '["llama3.2","mistral","codellama"]',
            ai_requests_per_day => 30,
            has_email        => 0, email_addresses => 0,
            has_hosting      => 1, hosting_tier => 'app-only',
            has_subdomain    => 0, has_custom_domain => 1,
            has_beekeeping   => 0, has_planning => 1,
            has_currency     => 1, currency_bonus => '50.00',
            max_services     => 5, sort_order => 11,
            is_active        => 1, is_featured => 1,
        },
    );

    my ($added, $skipped) = (0, 0);
    eval {
        $db->schema->txn_do(sub {
            for my $plan (@hosting_plans) {
                my $exists = $db->resultset('MembershipPlan')->search(
                    { site_id => $csc->id, slug => $plan->{slug} }
                )->single;
                if ($exists) {
                    $exists->update({ %$plan });
                    $skipped++;
                } else {
                    $db->resultset('MembershipPlan')->create({
                        site_id => $csc->id,
                        %$plan,
                    });
                    $added++;
                }
            }
        });
    };
    if ($@) {
        $c->flash->{error_msg} = "Error seeding hosting plans: $@";
    } else {
        $c->flash->{success_msg} = "Hosting plans seeded: $added added, $skipped already existed.";
    }
    $c->response->redirect($c->uri_for('/membership/admin/manage_plans'));
}

sub backfill_hosting_invoices :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || '';
    unless (lc($site_name) eq 'csc') {
        $c->flash->{error_msg} = 'Only available on CSC.';
        $c->response->redirect($c->uri_for('/membership/admin/hosting_accounts'));
        return;
    }

    my $schema = $c->model('DBEncy');
    my @active = $schema->resultset('Accounting::HostingAccount')->search({ status => 'active' })->all;

    my ($created, $skipped) = (0, 0);
    my @log;
    for my $acct (@active) {
        my $client_sn = $acct->sitename;
        my $plan_slug = $acct->plan_slug || 'hosting-app';
        my $monthly   = $acct->monthly_cost || 0;

        # Find any existing CSC customer invoice (no notes filter — cast wide)
        my @existing_csc = $schema->resultset('Accounting::InventoryCustomerInvoice')->search({
            sitename      => 'CSC',
            customer_name => $client_sn,
        })->all;

        if (@existing_csc) {
            my $ids = join(', ', map { '#' . $_->id . ' date=' . ($_->invoice_date || 'NULL') . ' status=' . ($_->status || '?') } @existing_csc);
            push @log, "$client_sn: SKIPPED — found CSC invoice(s): $ids";
            $skipped++;
            next;
        }

        # Check if client already has a supplier invoice from CSC
        my $cli_inv_exists = $schema->resultset('Accounting::InventorySupplierInvoice')->search({
            sitename => $client_sn,
            notes    => { -like => "%$plan_slug%" },
        })->count;

        eval {
            if ($cli_inv_exists) {
                $self->_backfill_csc_ar_only($c, $acct, $monthly);
            } else {
                $self->_create_hosting_invoice($c, $acct, $monthly);
            }
        };
        if ($@) {
            my $err = "$@";
            $err =~ s/\n.*//s;
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'backfill_hosting_invoices',
                "Error for $client_sn: $@");
            push @log, "$client_sn: ERROR — $err";
            $skipped++;
        } else {
            push @log, "$client_sn: CREATED";
            $created++;
        }
    }

    $c->flash->{success_msg} = "Backfill: $created created, $skipped skipped. " . join(' | ', @log);
    $c->response->redirect($c->uri_for('/membership/admin/hosting_accounts'));
}

sub sync_invoice_payments :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || '';
    unless (lc($site_name) eq 'csc') {
        $c->flash->{error_msg} = 'Only available on CSC.';
        $c->response->redirect($c->uri_for('/membership/admin/hosting_accounts'));
        return;
    }

    my $schema = $c->model('DBEncy');
    my ($synced, $skipped) = (0, 0);
    my @log;

    my @csc_invoices = $schema->resultset('Accounting::InventoryCustomerInvoice')->search({
        sitename       => 'CSC',
        payment_status => { '!=' => 'paid' },
    })->all;

    for my $csc_inv (@csc_invoices) {
        my $inv_num = $csc_inv->invoice_number;
        next unless $inv_num;

        my $client_inv = $schema->resultset('Accounting::InventorySupplierInvoice')->search({
            invoice_number => $inv_num,
        })->single;

        unless ($client_inv) {
            push @log, "$inv_num: no client invoice found";
            $skipped++;
            next;
        }

        if ($client_inv->status eq 'paid') {
            my $amount = $csc_inv->total_amount || 0;
            $csc_inv->update({
                payment_status  => 'paid',
                amount_paid     => $amount,
                points_redeemed => $amount,
            });
            push @log, "$inv_num: synced to paid";
            $synced++;
        } else {
            push @log, "$inv_num: client invoice status=" . ($client_inv->status || '?') . ", skipped";
            $skipped++;
        }
    }

    $c->flash->{success_msg} = "Payment sync: $synced updated, $skipped skipped. " . join(' | ', @log);
    $c->response->redirect($c->uri_for('/membership/admin/hosting_accounts'));
}

sub _backfill_csc_ar_only {
    my ($self, $c, $acct, $monthly_cost) = @_;
    my $schema    = $c->model('DBEncy');
    my $client_sn = $acct->sitename;
    my $plan_slug = $acct->plan_slug || 'hosting-app';

    my $csc_ar     = $schema->resultset('Accounting::CoaAccount')->search({ sitename => 'CSC', accno => '1100' })->single;
    my $csc_income = $schema->resultset('Accounting::CoaAccount')->search({ sitename => 'CSC', accno => '4300' })->single;
    my $sku        = $plan_slug eq 'hosting-subdomain' ? 'CSC-HOST-SUB' : 'CSC-HOST-APP';
    my $item       = $schema->resultset('Accounting::InventoryItem')->search({ sitename => 'CSC', sku => $sku })->single;

    # Find the existing client supplier invoice to reuse its invoice number
    my $cli_inv = $schema->resultset('Accounting::InventorySupplierInvoice')->search(
        { sitename => $client_sn, notes => { -like => "%$plan_slug%" } },
        { order_by => { -desc => 'id' }, rows => 1 }
    )->single;

    my $now_dt   = DateTime->now;
    my $inv_date = $now_dt->strftime('%Y-%m-%d');
    my $due_date = DateTime->now->add(days => 30)->strftime('%Y-%m-%d');
    my $inv_num  = $cli_inv ? $cli_inv->invoice_number
                             : 'CSC-HOST-' . uc($client_sn) . '-' . $now_dt->strftime('%Y%m%d%H%M%S');

    my $paid = $cli_inv && $cli_inv->status eq 'paid';

    my $csc_invoice = $schema->resultset('Accounting::InventoryCustomerInvoice')->create({
        sitename          => 'CSC',
        customer_name     => $client_sn,
        customer_email    => $acct->contact_email || '',
        invoice_number    => $inv_num,
        invoice_date      => $cli_inv ? $cli_inv->invoice_date : $inv_date,
        due_date          => $cli_inv ? $cli_inv->due_date      : $due_date,
        total_amount      => $monthly_cost,
        tax_amount        => 0,
        status            => $paid ? 'paid' : 'posted',
        ar_account_id     => ($csc_ar     ? $csc_ar->id     : undef),
        income_account_id => ($csc_income ? $csc_income->id : undef),
        notes             => "Hosting — $plan_slug — $client_sn",
        created_by        => $c->session->{username} || 'system',
        payment_status    => $paid ? 'paid' : 'pending',
        amount_paid       => $paid ? $monthly_cost : 0,
        points_redeemed   => $paid ? $monthly_cost : 0,
        created_at        => \'NOW()',
        updated_at        => \'NOW()',
    });

    $csc_invoice->create_related('lines', {
        item_id     => ($item ? $item->id   : undef),
        item_name   => ($item ? $item->name : "Hosting $plan_slug"),
        sku         => ($item ? $item->sku  : $sku),
        quantity    => 1,
        unit_price  => $monthly_cost,
        line_total  => $monthly_cost,
        description => "Monthly Hosting — $client_sn ($plan_slug)",
        sort_order  => 1,
    });

    # Create GL entry if COA accounts exist and we don't already have one
    if ($csc_ar && $csc_income) {
        my $existing_gl = $schema->resultset('Accounting::GlEntry')->search(
            { sitename => 'CSC', reference => $inv_num }
        )->single;
        unless ($existing_gl) {
            my $csc_gl = $schema->resultset('Accounting::GlEntry')->create({
                sitename    => 'CSC',
                reference   => $inv_num . '-BF',
                description => "Hosting invoice (backfill) $client_sn",
                post_date   => $inv_date,
                created_at  => \'NOW()',
                updated_at  => \'NOW()',
            });
            $schema->resultset('Accounting::GlEntryLine')->create({
                gl_entry_id => $csc_gl->id,
                account_id  => $csc_ar->id,
                amount      => $monthly_cost,
                memo        => "AR — $client_sn hosting",
                created_at  => \'NOW()',
            });
            $schema->resultset('Accounting::GlEntryLine')->create({
                gl_entry_id => $csc_gl->id,
                account_id  => $csc_income->id,
                amount      => -$monthly_cost,
                memo        => "Hosting income — $client_sn",
                created_at  => \'NOW()',
            });
            $csc_invoice->update({ gl_entry_id => $csc_gl->id });
        }
    }
}

sub hosting_accounts :Local :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_admin($c);

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || '';
    unless (lc($site_name) eq 'csc') {
        $c->flash->{error_msg} = 'Hosting account management is only available on the CSC site.';
        $c->response->redirect($c->uri_for('/membership/admin'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $id     = $c->req->body_parameters->{account_id};
        my $action = $c->req->body_parameters->{action};
        eval {
            my $acct = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->find($id);
            if ($acct) {
                if ($action eq 'approve') {
                    my $monthly = $c->req->body_parameters->{monthly_cost} || $acct->monthly_cost || 0;
                    $acct->update({ status => 'active', monthly_cost => $monthly, updated_at => \'NOW()' });
                    eval {
                        my $notifier = Comserv::Util::EmailNotification->new(logging => $self->logging);
                        $notifier->send_hosting_approval_notification($c, $acct);
                    };
                    my $inv_err;
                    eval { $self->_create_hosting_invoice($c, $acct, $monthly) };
                    if ($@) {
                        $inv_err = "$@";
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'hosting_accounts',
                            "Invoice creation error: $inv_err");
                    }
                    $c->flash->{success_msg} = $acct->sitename . " hosting approved"
                        . ($inv_err ? " (invoice error: $inv_err)" : ", invoice created and emailed.");
                } elsif ($action eq 'suspend') {
                    $acct->update({ status => 'suspended', updated_at => \'NOW()' });
                    $c->flash->{success_msg} = $acct->sitename . " hosting suspended.";
                } elsif ($action eq 'cancel') {
                    $acct->update({ status => 'cancelled', updated_at => \'NOW()' });
                    $c->flash->{success_msg} = $acct->sitename . " hosting cancelled.";
                }
            }
        };
        $c->flash->{error_msg} = "Action failed: $@" if $@;
        $c->response->redirect($c->uri_for('/membership/admin/hosting_accounts'));
        return;
    }

    my @accounts = eval {
        $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
            {},
            { order_by => [{ -asc => 'status' }, { -asc => 'sitename' }] }
        )->all;
    };

    my %plan_price;
    eval {
        my $csc_site = $c->model('DBEncy')->resultset('Site')->search({ name => 'CSC' })->single;
        if ($csc_site) {
            my @plans = $c->model('DBEncy')->resultset('MembershipPlan')->search(
                { site_id => $csc_site->id, is_active => 1 }
            )->all;
            %plan_price = map { $_->slug => ($_->price_monthly || 0) } @plans;
        }
    };

    $c->stash(
        template   => 'membership/admin/hosting_accounts.tt',
        accounts   => \@accounts,
        plan_price => \%plan_price,
    );
    $c->forward($c->view('TT'));
}

sub hosting_account_edit :Local :Args(1) {
    my ($self, $c, $id) = @_;
    return unless $self->_require_admin($c);

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || '';
    unless (lc($site_name) eq 'csc') {
        $c->response->redirect($c->uri_for('/membership/admin'));
        return;
    }

    my $acct = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->find($id);
    unless ($acct) {
        $c->flash->{error_msg} = 'Hosting account not found.';
        $c->response->redirect($c->uri_for('/membership/admin/hosting_accounts'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $p = $c->req->body_parameters;
        my @addon_keys = qw(beekeeping planning ai workshops helpdesk foraging ency ecommerce membership);
        my $addons_str = join(',', grep { $p->{"addon_$_"} } @addon_keys);
        eval {
            $acct->update({
                plan_slug        => $p->{plan_slug}       || $acct->plan_slug,
                domain           => $p->{domain}          // '',
                domain_type      => $p->{domain_type}     || 'subdomain',
                parent_domain    => $p->{parent_domain}   // '',
                contact_email    => $p->{contact_email}   // '',
                monthly_cost     => $p->{monthly_cost}    // $acct->monthly_cost,
                cpanel_username  => $p->{cpanel_username} // '',
                notes            => $p->{notes}           // '',
                requested_addons => $addons_str,
                updated_at       => \'NOW()',
            });
        };
        if ($@) {
            $c->flash->{error_msg} = "Update failed: $@";
        } else {
            $c->flash->{success_msg} = $acct->sitename . ' hosting account updated.';
        }
        $c->response->redirect($c->uri_for('/membership/admin/hosting_accounts'));
        return;
    }

    $c->stash(
        template => 'membership/admin/hosting_account_edit.tt',
        acct     => $acct,
    );
    $c->forward($c->view('TT'));
}

sub _create_hosting_invoice {
    my ($self, $c, $acct, $monthly_cost) = @_;
    my $schema    = $c->model('DBEncy');
    my $client_sn = $acct->sitename;
    my $plan_slug = $acct->plan_slug || 'hosting-app';

    # --- COA lookups (CSC side) ---
    my $csc_ar     = $schema->resultset('Accounting::CoaAccount')->search({ sitename => 'CSC', accno => '1100' })->single;
    my $csc_income = $schema->resultset('Accounting::CoaAccount')->search({ sitename => 'CSC', accno => '4300' })->single;

    # --- COA lookups (client side) ---
    my $cli_ap      = $schema->resultset('Accounting::CoaAccount')->search({ sitename => $client_sn, accno => '2000' })->single;
    my $cli_expense = $schema->resultset('Accounting::CoaAccount')->search({ sitename => $client_sn, accno => '6300' })->single;

    # --- Inventory item for this plan ---
    my $sku  = $plan_slug eq 'hosting-subdomain' ? 'CSC-HOST-SUB' : 'CSC-HOST-APP';
    my $item = $schema->resultset('Accounting::InventoryItem')->search({ sitename => 'CSC', sku => $sku })->single;

    # --- Supplier on client side (CSC as supplier for client) ---
    my $supplier = $schema->resultset('Accounting::InventorySupplier')->search(
        { sitename => $client_sn, name => { -like => '%Computer System Consulting%' } }
    )->single;

    # Auto-create supplier if missing
    unless ($supplier) {
        $supplier = $schema->resultset('Accounting::InventorySupplier')->create({
            sitename     => $client_sn,
            name         => 'Computer System Consulting (CSC)',
            contact_name => 'CSC Admin',
            email        => 'helpdesk@computersystemconsulting.ca',
            website      => 'https://computersystemconsulting.ca',
            status       => 'active',
            notes        => 'CSC hosting provider. Invoices paid in Points (1 pt = CAD 1.00).',
            created_by   => 'system',
            created_at   => \'NOW()',
            updated_at   => \'NOW()',
        });
    }

    my $now_dt   = DateTime->now;
    my $inv_date = $now_dt->strftime('%Y-%m-%d');
    my $due_date = DateTime->now->add(days => 30)->strftime('%Y-%m-%d');
    my $inv_num  = 'CSC-HOST-' . uc($client_sn) . '-' . $now_dt->strftime('%Y%m%d%H%M%S');
    my $pts_rate = 1;
    my $points_due = $monthly_cost * $pts_rate;

    # --- Link hosting item to CSC supplier on client side (for Supplier view) ---
    if ($item && $supplier) {
        my $existing_link = $schema->resultset('Accounting::InventoryItemSupplier')->search({
            item_id     => $item->id,
            supplier_id => $supplier->id,
        })->single;
        unless ($existing_link) {
            $schema->resultset('Accounting::InventoryItemSupplier')->create({
                item_id      => $item->id,
                supplier_id  => $supplier->id,
                unit_cost    => $monthly_cost,
                is_preferred => 1,
                notes        => 'CSC hosting service',
            });
        }
    }

    # --- CLIENT SIDE: SupplierInvoice (bill from CSC) ---
    my $cli_invoice = $schema->resultset('Accounting::InventorySupplierInvoice')->create({
        sitename       => $client_sn,
        supplier_id    => $supplier->id,
        invoice_number => $inv_num,
        invoice_date   => $inv_date,
        due_date       => $due_date,
        total_amount   => $monthly_cost,
        status         => 'outstanding',
        ap_account_id  => ($cli_ap ? $cli_ap->id : undef),
        notes          => "Monthly hosting fee - $plan_slug. Points: $points_due pts (1 pt = CAD 1.00).",
        created_by     => $c->session->{username} || 'system',
        created_at     => \'NOW()',
        updated_at     => \'NOW()',
    });

    $schema->resultset('Accounting::InventorySupplierInvoiceLine')->create({
        invoice_id  => $cli_invoice->id,
        item_id     => ($item ? $item->id : undef),
        description => 'Monthly Hosting — ' . uc($client_sn) . ' (' . $plan_slug . ')',
        quantity    => 1,
        unit_cost   => $monthly_cost,
        line_total  => $monthly_cost,
        account_id  => ($cli_expense ? $cli_expense->id : undef),
    });

    # --- CLIENT GL: DR Hosting Expense (+) / CR Accounts Payable (-) ---
    if ($cli_expense && $cli_ap) {
        my $cli_gl = $schema->resultset('Accounting::GlEntry')->create({
            sitename    => $client_sn,
            reference   => $inv_num,
            description => "CSC Hosting invoice $inv_num",
            post_date   => $inv_date,
            created_at  => \'NOW()',
            updated_at  => \'NOW()',
        });
        $schema->resultset('Accounting::GlEntryLine')->create({
            gl_entry_id => $cli_gl->id,
            account_id  => $cli_expense->id,
            amount      => $monthly_cost,
            memo        => 'Hosting expense — CSC',
            created_at  => \'NOW()',
        });
        $schema->resultset('Accounting::GlEntryLine')->create({
            gl_entry_id => $cli_gl->id,
            account_id  => $cli_ap->id,
            amount      => -$monthly_cost,
            memo        => 'AP — CSC hosting invoice',
            created_at  => \'NOW()',
        });
        $cli_invoice->update({ gl_entry_id => $cli_gl->id });
    }

    # --- CSC SIDE: CustomerInvoice (AR — client owes CSC) ---
    my $csc_gl_id;
    my $csc_invoice = $schema->resultset('Accounting::InventoryCustomerInvoice')->create({
        sitename          => 'CSC',
        customer_name     => $client_sn,
        customer_email    => $acct->contact_email || '',
        invoice_number    => $inv_num,
        invoice_date      => $inv_date,
        due_date          => $due_date,
        total_amount      => $monthly_cost,
        tax_amount        => 0,
        status            => 'posted',
        ar_account_id     => ($csc_ar     ? $csc_ar->id     : undef),
        income_account_id => ($csc_income ? $csc_income->id : undef),
        notes             => "Hosting — $plan_slug — $client_sn",
        created_by        => $c->session->{username} || 'system',
        payment_status    => 'pending',
        amount_paid       => 0,
        created_at        => \'NOW()',
        updated_at        => \'NOW()',
    });

    $csc_invoice->create_related('lines', {
        item_id      => ($item ? $item->id : undef),
        item_name    => ($item ? $item->name : "Hosting $plan_slug"),
        sku          => ($item ? $item->sku  : $sku),
        quantity     => 1,
        unit_price   => $monthly_cost,
        line_total   => $monthly_cost,
        description  => "Monthly Hosting — $client_sn ($plan_slug)",
        sort_order   => 1,
    });

    # --- CSC GL: DR Accounts Receivable (+) / CR Hosting Income (-) ---
    if ($csc_ar && $csc_income) {
        my $csc_gl = $schema->resultset('Accounting::GlEntry')->create({
            sitename    => 'CSC',
            reference   => $inv_num,
            description => "Hosting invoice to $client_sn — $inv_num",
            post_date   => $inv_date,
            created_at  => \'NOW()',
            updated_at  => \'NOW()',
        });
        $schema->resultset('Accounting::GlEntryLine')->create({
            gl_entry_id => $csc_gl->id,
            account_id  => $csc_ar->id,
            amount      => $monthly_cost,
            memo        => "AR — $client_sn hosting",
            created_at  => \'NOW()',
        });
        $schema->resultset('Accounting::GlEntryLine')->create({
            gl_entry_id => $csc_gl->id,
            account_id  => $csc_income->id,
            amount      => -$monthly_cost,
            memo        => "Hosting income — $client_sn",
            created_at  => \'NOW()',
        });
        $csc_gl_id = $csc_gl->id;
        $csc_invoice->update({ gl_entry_id => $csc_gl_id });
    }

    # --- POINTS PAYMENT: find client admin user, transfer to CSC admin ---
    my $CSC_ADMIN_USER_ID = 178;
    my $pts_paid = 0;
    eval {
        my $client_site = $schema->resultset('Site')->search({ name => $client_sn })->single;
        if ($client_site) {
            my $admin_user = $schema->resultset('UserSite')->search(
                { site_id => $client_site->id },
                { prefetch => 'user', rows => 50 }
            )->search_related('user', { roles => { -like => '%admin%' } })->first;

            if ($admin_user) {
                my $ps = Comserv::Util::PointSystem->new(c => $c);
                my ($ok, $err) = $ps->debit(
                    user_id          => $admin_user->id,
                    amount           => $points_due,
                    transaction_type => 'hosting_payment',
                    description      => "Hosting invoice $inv_num — CAD $monthly_cost",
                    reference_type   => 'hosting_account',
                    reference_id     => $acct->id,
                );
                if ($ok) {
                    $ps->credit(
                        user_id          => $CSC_ADMIN_USER_ID,
                        amount           => $points_due,
                        transaction_type => 'hosting_income',
                        description      => "Hosting payment from $client_sn — $inv_num",
                        reference_type   => 'hosting_account',
                        reference_id     => $acct->id,
                    );
                    $cli_invoice->update({ status => 'paid' });
                    $csc_invoice->update({
                        payment_status  => 'paid',
                        amount_paid     => $monthly_cost,
                        points_redeemed => $points_due,
                        status          => 'paid',
                    });
                    $pts_paid = $points_due;
                } else {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_create_hosting_invoice',
                        "Insufficient points for $client_sn ($err) — invoice left outstanding");
                }
            }
        }
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_create_hosting_invoice',
        "Points transfer error: $@") if $@;

    # --- Email invoice to client contact ---
    eval {
        my $contact_email = $acct->contact_email;
        if ($contact_email) {
            my $notifier = Comserv::Util::EmailNotification->new(logging => $self->logging);
            $notifier->send_hosting_invoice_notification($c,
                invoice_number => $inv_num,
                invoice_id     => $cli_invoice->id,
                sitename       => $client_sn,
                plan_slug      => $plan_slug,
                amount         => $monthly_cost,
                due_date       => $due_date,
                contact_email  => $contact_email,
                pts_paid       => $pts_paid,
            );
        }
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_create_hosting_invoice',
        "Invoice email error: $@") if $@;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_create_hosting_invoice',
        "Invoice $inv_num created for $client_sn (\$$monthly_cost / ${points_due}pts paid=$pts_paid)");
}

__PACKAGE__->meta->make_immutable;

1;

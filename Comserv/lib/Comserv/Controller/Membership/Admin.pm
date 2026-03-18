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
        @benefactor_contribs = $c->model('DBEncy')->resultset('BenefactorContribution')->search(
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
                my $contrib = $c->model('DBEncy')->resultset('BenefactorContribution')->create({
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

                my $acct = $c->model('DBEncy')->resultset('InternalCurrencyAccount')->find_or_create(
                    { user_id => $p->{user_id} },
                    { key     => 'unique_user_id' }
                );

                my $new_balance = ($acct->balance || 0) + $coins;
                my $tx = $c->model('DBEncy')->resultset('InternalCurrencyTransaction')->create({
                    from_user_id     => undef,
                    to_user_id       => $p->{user_id},
                    amount           => $coins,
                    transaction_type => 'earn',
                    description      => 'Benefactor contribution: ' . ($p->{description} || $p->{contribution_type}),
                    reference_type   => 'benefactor_contribution',
                    reference_id     => $contrib->id,
                    balance_after    => $new_balance,
                });

                $acct->update({
                    balance         => $new_balance,
                    lifetime_earned => ($acct->lifetime_earned || 0) + $coins,
                });

                $contrib->update({ currency_transaction_id => $tx->id });
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

__PACKAGE__->meta->make_immutable;

1;

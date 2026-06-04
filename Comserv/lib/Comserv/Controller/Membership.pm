package Comserv::Controller::Membership;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::PointSystem;
use Comserv::Util::EmailNotification;

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

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Membership index called");

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $plans     = [];
    my $user_membership = undef;
    my $is_admin  = $self->_is_admin($c);
    my $all_members = [];
    my $site_is_csc      = (lc($site_name) eq 'csc');
    my $csc_hosting_plans = [];
    my $hosting_account   = undef;
    my $csc_not_registered = 0;

    eval {
        my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->single;
        if ($site) {
            my @rows = $c->model('DBEncy')->resultset('MembershipPlan')->search(
                { site_id => $site->id, is_active => 1 },
                { order_by => 'sort_order', prefetch => 'inventory_item' }
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

            if ($is_admin) {
                my @members = $c->model('DBEncy')->resultset('UserMembership')->search(
                    { site_id => $site->id },
                    {
                        prefetch => ['user', 'plan'],
                        order_by => [{ -asc => 'me.status' }, { -asc => 'user.username' }],
                        rows     => 200,
                    }
                )->all;
                $all_members = \@members;
            }
        }

    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
            "Could not load membership plans (table may not exist yet): $err");
    }

    unless ($site_is_csc) {
        eval {
            my $csc_site = $c->model('DBEncy')->resultset('Site')->search({ name => 'CSC' })->single;
            if ($csc_site) {
                my @hosting = $c->model('DBEncy')->resultset('MembershipPlan')->search(
                    { site_id => $csc_site->id, has_hosting => 1, is_active => 1 },
                    { order_by => 'sort_order' }
                )->all;
                $csc_hosting_plans = \@hosting;
            }
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
            "CSC hosting plans query failed: $@") if $@;

        eval {
            $hosting_account = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
                { sitename => $site_name },
                { rows => 1 }
            )->single;
        };

        if ($is_admin && !$hosting_account) {
            $csc_not_registered = 1;
        }
    }

    my $patreon_cfg = $self->_get_patreon_config($c, $site_name);
    my $user_id    = $c->session->{user_id};
    my $user_site_memberships = $self->_get_user_site_memberships($c, $user_id);

    $c->stash(
        template           => 'membership/Index.tt',
        plans              => $plans,
        user_membership    => $user_membership,
        site_name          => $site_name,
        is_admin           => $is_admin,
        all_members        => $all_members,
        patreon_cfg        => $patreon_cfg,
        site_is_csc        => $site_is_csc,
        csc_hosting_plans  => $csc_hosting_plans,
        hosting_account    => $hosting_account,
        csc_not_registered => $csc_not_registered,
        user_site_memberships => $user_site_memberships,
    );
    $c->forward($c->view('TT'));
}

sub addons :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'addons',
        "Membership addons action called");

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $is_admin  = $self->_is_admin($c);
    my $user_id   = $c->session->{user_id};

    # Define all available modules with metadata
    my @modules = (
        {
            key         => 'beekeeping',
            name        => 'Beekeeping & Apiary Management',
            owner       => 'BMaster',
            description => 'Track bee hives, apiaries, queen logs, and inspections.',
            route       => '/apiary',
        },
        {
            key         => 'planning',
            name        => 'AI Planning & Project System',
            owner       => 'CSC',
            description => 'Advanced project planning, todo tracking, and AI-assisted workflows.',
            route       => '/todo',
        },
        {
            key         => 'accounting',
            name        => 'Accounting & Ledger System',
            owner       => 'ENCY',
            description => 'Chart of accounts, general ledger entries, inventory items, and suppliers.',
            route       => '/Accounting',
        },
        {
            key         => 'ency',
            name        => 'Encyclopedia & Herbal Database',
            owner       => 'ENCY',
            description => 'Share scientific crop data, botanical encyclopedia, and medicinal herb logs.',
            route       => '/ency',
        },
        {
            key         => 'ecommerce',
            name        => 'E-Commerce & Store',
            owner       => 'CSC',
            description => 'Sell products, list items, handle currency checkout, and manage shipping.',
            route       => '/shop',
        },
        {
            key         => 'helpdesk',
            name        => 'HelpDesk Support & Guide system',
            owner       => 'CSC',
            description => 'Issue ticket tracking, linux guides, and support desk system.',
            route       => '/helpdesk',
        },
        {
            key         => 'foraging',
            name        => 'Foraging & Wild Harvesting Log',
            owner       => 'Forager',
            description => 'Map and log foraging spots, wild harvest logs, and seasonal wild botany.',
            route       => '/foraging',
        },
        {
            key         => 'membership',
            name        => 'Multi-Site Membership System',
            owner       => 'CSC',
            description => 'Set up recurring billing, regional pricing, payment gateways, and coins.',
            route       => '/membership',
        },
        {
            key         => '3d',
            name        => '3D Printing & Custom Fabrication',
            owner       => '3D',
            description => 'Order 3D prints, upload design models, and track build queues.',
            route       => '/3d',
        },
    );

    # If post and admin, handle site module updates
    if ($c->req->method eq 'POST' && $is_admin) {
        my $params = $c->req->body_parameters;
        eval {
            foreach my $mod (@modules) {
                my $key = $mod->{key};
                my $enabled = $params->{"enabled_$key"} ? 1 : 0;
                $c->model('DBEncy')->resultset('SiteModule')->update_or_create(
                    {
                        sitename    => $site_name,
                        module_name => $key,
                    },
                    {
                        key     => 'site_module_unique',
                        values  => { enabled => $enabled },
                    }
                );
            }
            $c->flash->{success_msg} = "Add-on configurations for site '$site_name' updated successfully!";
        };
        if ($@) {
            $c->stash->{error_msg} = "Failed to update add-ons: $@";
        } else {
            return $c->response->redirect($c->uri_for($self->action_for('addons')));
        }
    }

    # Fetch current site-level enablement
    my %site_status;
    eval {
        my @site_mods = $c->model('DBEncy')->resultset('SiteModule')->search({
            sitename => $site_name,
        })->all;
        for my $sm (@site_mods) {
            $site_status{$sm->module_name} = $sm->enabled ? 1 : 0;
        }
    };

    # Populate module statuses
    for my $mod (@modules) {
        my $key = $mod->{key};
        $mod->{site_enabled} = exists $site_status{$key} ? $site_status{$key} : 0;
        # Check if user has access (either site-level, user-override, or membership-granted)
        $mod->{user_access}  = $c->stash->{enabled_modules}{$key} ? 1 : 0;
    }

    my $hosting_account = undef;
    eval {
        $hosting_account = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
            {
                -or => [
                    sitename => $site_name,
                    sitename => lc($site_name),
                    sitename => uc($site_name),
                ]
            },
            { rows => 1 }
        )->single;
    };

    $c->stash(
        template        => 'membership/Addons.tt',
        modules         => \@modules,
        site_name       => $site_name,
        is_admin        => $is_admin,
        hosting_account => $hosting_account,
    );
    $c->forward($c->view('TT'));
}

sub hosting_signup :Local :Args(0) {
    my ($self, $c) = @_;

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || '';
    return $c->response->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }))
        unless $c->session->{username};
    return $c->response->redirect($c->uri_for('/membership'))
        unless $self->_is_admin($c);
    return $c->response->redirect($c->uri_for('/membership'))
        if lc($site_name) eq 'csc';

    my ($site, $domains, $csc_hosting_plans, $hosting_account) = (undef, [], [], undef);

    eval {
        $site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->single;

        if ($site) {
            my @d = $c->model('DBEncy')->resultset('SiteDomain')->search(
                { site_id => $site->id },
                { order_by => 'domain' }
            )->all;
            $domains = \@d;
        }

        my $csc_site = $c->model('DBEncy')->resultset('Site')->search({ name => 'CSC' })->single;
        if ($csc_site) {
            my @plans = $c->model('DBEncy')->resultset('MembershipPlan')->search(
                { site_id => $csc_site->id, has_hosting => 1, is_active => 1 },
                { order_by => 'sort_order' }
            )->all;
            $csc_hosting_plans = \@plans;
        }

        $hosting_account = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
            { sitename => $site_name }, { rows => 1 }
        )->single;
    };

    my %plan_price = map { $_->slug => ($_->price_monthly || 0) } @$csc_hosting_plans;

    if ($c->req->method eq 'POST') {
        my $p = $c->req->body_parameters;
        my @addon_keys = qw(beekeeping planning ai workshops helpdesk foraging ency ecommerce membership);
        my $addons_str = join(',', grep { $p->{"addon_$_"} } @addon_keys);
        my $monthly_cost = $plan_price{ $p->{plan_slug} } // 0;
        eval {
            if ($hosting_account) {
                $hosting_account->update({
                    plan_slug          => $p->{plan_slug},
                    domain             => $p->{domain},
                    domain_type        => $p->{domain_type} || 'subdomain',
                    parent_domain      => $p->{parent_domain},
                    referring_sitename => $p->{referring_sitename},
                    contact_email      => $p->{contact_email},
                    monthly_cost       => $monthly_cost,
                    notes              => $p->{notes},
                    requested_addons   => $addons_str,
                    updated_at         => \'NOW()',
                });
            } else {
                $c->model('DBEncy')->resultset('Accounting::HostingAccount')->create({
                    sitename           => $site_name,
                    plan_slug          => $p->{plan_slug},
                    domain             => $p->{domain},
                    domain_type        => $p->{domain_type} || 'subdomain',
                    parent_domain      => $p->{parent_domain},
                    referring_sitename => $p->{referring_sitename} || $site_name,
                    contact_email      => $p->{contact_email},
                    status             => 'pending',
                    monthly_cost       => $monthly_cost,
                    notes              => $p->{notes},
                    requested_addons   => $addons_str,
                    created_by         => $c->session->{username},
                });
            }
        };
        if ($@) {
            $c->stash->{error_msg} = ($hosting_account ? "Update" : "Registration") . " failed: $@";
        } else {
            my $new_account = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
                { sitename => $site_name }, { rows => 1 }
            )->single;
            if ($hosting_account) {
                $c->flash->{success_msg} = "Hosting registration for $site_name has been updated. CSC will be notified of any changes.";
            } else {
                $c->flash->{success_msg} = "$site_name has been submitted for CSC hosting registration. Status: pending.";
            }
            eval {
                my $notifier = Comserv::Util::EmailNotification->new(logging => $self->logging);
                $notifier->send_hosting_signup_notification($c, $new_account);
                $notifier->send_hosting_signup_confirmation($c, $new_account);
            };
            return $c->response->redirect($c->uri_for('/membership'));
        }
    }

    $c->session->{return_url} = $c->uri_for('/membership')->as_string;

    $c->stash(
        template          => 'membership/hosting_signup.tt',
        site              => $site,
        site_name         => $site_name,
        domains           => $domains,
        csc_hosting_plans => $csc_hosting_plans,
        hosting_account   => $hosting_account,
        selected_plan     => $c->req->query_parameters->{plan}
                            || ($hosting_account ? $hosting_account->plan_slug : '')
                            || '',
    );
    $c->forward($c->view('TT'));
}

sub plans :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'plans',
        "Membership plans page called");

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $plans     = [];

    eval {
        my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->single;
        if ($site) {
            my @rows = $c->model('DBEncy')->resultset('MembershipPlan')->search(
                { site_id => $site->id, is_active => 1 },
                { order_by => 'sort_order' }
            )->all;
            $plans = \@rows;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'plans',
            "Could not load membership plans: $@");
    }

    my $user_id = $c->session->{user_id};
    my $user_site_memberships = $self->_get_user_site_memberships($c, $user_id);

    $c->stash(
        template  => 'membership/Plans.tt',
        plans     => $plans,
        site_name => $site_name,
        user_site_memberships => $user_site_memberships,
    );
    $c->forward($c->view('TT'));
}

sub account :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'account',
        "Membership account page called");

    unless ($c->session->{username}) {
        $c->flash->{error_msg} = "Please log in to view your membership.";
        $c->response->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        return;
    }

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $user_id   = $c->session->{user_id};
    my $memberships   = [];
    my $point_balance = 0;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'account',
        "Loading account for user_id=$user_id site=$site_name");

    eval {
        my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->single;
        if ($site) {
            my @rows = $c->model('DBEncy')->resultset('UserMembership')->search(
                { 'me.user_id' => $user_id, 'me.site_id' => $site->id },
                { order_by => { -desc => 'me.created_at' }, prefetch => 'plan' }
            )->all;
            $memberships = \@rows;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'account',
                "Found " . scalar(@rows) . " membership(s) for site_id=" . $site->id);
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'account',
                "Site not found: $site_name");
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'account',
            "Membership query failed: $@");
    }

    eval {
        my $ps = Comserv::Util::PointSystem->new(c => $c);
        $point_balance = $ps->balance($user_id);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'account',
            "Point balance for user_id=$user_id: $point_balance");
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'account',
            "Balance lookup failed: $@");
    }

    $c->stash(
        template      => 'membership/Account.tt',
        memberships   => $memberships,
        point_balance => $point_balance,
    );
    $c->forward($c->view('TT'));
}

sub autopay_settings :Local :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        return;
    }

    my $membership_id = $c->req->param('membership_id');
    unless ($membership_id && $membership_id =~ /^\d+$/) {
        $c->flash->{error_msg} = 'Invalid membership.';
        $c->response->redirect($c->uri_for('/membership/account'));
        return;
    }

    my $mem;
    eval {
        $mem = $c->model('DBEncy')->resultset('UserMembership')->find($membership_id);
    };
    unless ($mem && $mem->user_id == $c->session->{user_id}) {
        $c->flash->{error_msg} = 'Membership not found.';
        $c->response->redirect($c->uri_for('/membership/account'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $enabled     = $c->req->param('autopay_enabled') ? 1 : 0;
        my $method      = $c->req->param('autopay_method') || 'coins';
        my $topup_coins = $c->req->param('autopay_topup_coins') || 0;
        $method = 'coins' unless $method eq 'paypal' || $method eq 'coins';
        $topup_coins = int($topup_coins);
        $topup_coins = 0 if $topup_coins < 0;

        eval {
            $mem->update({
                autopay_enabled     => $enabled,
                autopay_method      => $enabled ? $method : undef,
                autopay_topup_coins => $topup_coins,
            });
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'autopay_settings',
                "Error saving autopay: $@");
            $c->flash->{error_msg} = 'Could not save auto-pay settings.';
        } else {
            $c->flash->{success_msg} = $enabled
                ? 'Auto-pay enabled. You will be notified before renewals.'
                : 'Auto-pay disabled.';
        }
        $c->response->redirect($c->uri_for('/membership/account'));
        return;
    }

    $c->stash(
        template   => 'membership/Account.tt',
        autopay_mem => $mem,
    );
    $c->forward('account');
}

sub subscribe :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'subscribe',
        "Membership subscribe page called");

    unless ($c->session->{username}) {
        $c->session->{post_login_redirect} = $c->req->uri->as_string;
        $c->flash->{error_msg} = "Please log in to subscribe.";
        $c->response->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
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

    my $site_name   = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $patreon_cfg = $self->_get_patreon_config($c, $site_name);

    $c->stash(
        template    => 'membership/Subscribe.tt',
        plan        => $plan,
        patreon_cfg => $patreon_cfg,
    );
    $c->forward($c->view('TT'));
}

sub plan_details :Local :Args(1) {
    my ($self, $c, $plan_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'plan_details',
        "Membership plan_details called for plan_id=$plan_id");

    my $plan = undef;
    eval {
        $plan = $c->model('DBEncy')->resultset('MembershipPlan')->find($plan_id);
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'plan_details',
            "Error loading plan: $err");
    }

    unless ($plan) {
        $c->flash->{error_msg} = "Plan not found.";
        $c->response->redirect($c->uri_for('/membership'));
        return;
    }

    my $site_name   = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $patreon_cfg = $self->_get_patreon_config($c, $site_name);

    $c->stash(
        template    => 'membership/PlanDetails.tt',
        plan        => $plan,
        site_name   => $site_name,
        patreon_cfg => $patreon_cfg,
    );
    $c->forward($c->view('TT'));
}

sub cancel :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'cancel',
        "Membership cancel page called");

    unless ($c->session->{username}) {
        $c->flash->{error_msg} = "Please log in to manage your membership.";
        $c->response->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        return;
    }

    my $membership_id = $c->req->param('membership_id');
    unless ($membership_id && $membership_id =~ /^\d+$/) {
        $c->flash->{error_msg} = 'Invalid membership.';
        $c->response->redirect($c->uri_for('/membership/account'));
        return;
    }

    my $mem;
    eval {
        $mem = $c->model('DBEncy')->resultset('UserMembership')->find($membership_id);
    };
    unless ($mem && $mem->user_id == $c->session->{user_id}) {
        $c->flash->{error_msg} = 'Membership not found.';
        $c->response->redirect($c->uri_for('/membership/account'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $reason = $c->req->param('cancellation_reason') || '';
        eval {
            $mem->update({
                status              => 'cancelled',
                cancelled_at        => \'NOW()',
                cancellation_reason => $reason,
            });
        };
        if ($@) {
            my $err = "$@";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'cancel',
                "Error cancelling membership: $err");
            $c->flash->{error_msg} = 'Could not cancel membership. Please contact support.';
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'cancel',
                "Membership id=$membership_id cancelled for user_id=" . $c->session->{user_id});
            $c->flash->{success_msg} = 'Your membership has been cancelled.';
        }
        $c->response->redirect($c->uri_for('/membership/account'));
        return;
    }

    $c->stash(
        template   => 'membership/Cancel.tt',
        membership => $mem,
    );
    $c->forward($c->view('TT'));
}

sub upgrade :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'upgrade',
        "Membership upgrade page called");

    unless ($c->session->{username}) {
        $c->session->{post_login_redirect} = $c->req->uri->as_string;
        $c->flash->{error_msg} = "Please log in to upgrade your membership.";
        $c->response->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        return;
    }

    my $site_name  = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $user_id    = $c->session->{user_id};
    my $plans      = [];
    my $current_membership = undef;

    eval {
        my $site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->single;
        if ($site) {
            $current_membership = $c->model('DBEncy')->resultset('UserMembership')->search(
                {
                    user_id => $user_id,
                    site_id => $site->id,
                    status  => [qw(active grace)],
                },
                { order_by => { -desc => 'created_at' }, rows => 1, prefetch => 'plan' }
            )->single;

            my @rows = $c->model('DBEncy')->resultset('MembershipPlan')->search(
                { site_id => $site->id, is_active => 1 },
                { order_by => 'sort_order' }
            )->all;
            $plans = \@rows;
        }
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'upgrade',
            "Error loading upgrade options: $err");
        $c->stash->{error_msg} = 'Could not load upgrade options.';
    }

    my $patreon_cfg = $self->_get_patreon_config($c, $site_name);
    my $user_site_memberships = $self->_get_user_site_memberships($c, $user_id);

    $c->stash(
        template           => 'membership/Upgrade.tt',
        plans              => $plans,
        current_membership => $current_membership,
        patreon_cfg        => $patreon_cfg,
        user_site_memberships => $user_site_memberships,
    );
    $c->forward($c->view('TT'));
}

sub csc_account :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'csc_account',
        "CSC account management page called");

    unless ($c->session->{username}) {
        $c->flash->{error_msg} = "Please log in to manage your CSC membership.";
        $c->response->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        return;
    }

    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $user_id   = $c->session->{user_id};
    my $csc_memberships  = [];
    my $csc_plans        = [];
    my $point_balance    = 0;
    my $hosting_account  = undef;

    eval {
        my $csc_site = $c->model('DBEncy')->resultset('Site')->search({ name => 'CSC' })->single;
        if ($csc_site) {
            my @rows = $c->model('DBEncy')->resultset('UserMembership')->search(
                { 'me.user_id' => $user_id, 'me.site_id' => $csc_site->id },
                { order_by => { -desc => 'me.created_at' }, prefetch => 'plan' }
            )->all;
            $csc_memberships = \@rows;

            my @plans = $c->model('DBEncy')->resultset('MembershipPlan')->search(
                { site_id => $csc_site->id, is_active => 1 },
                { order_by => 'sort_order' }
            )->all;
            $csc_plans = \@plans;
        }
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'csc_account',
        "CSC membership query failed: $@") if $@;

    eval {
        $hosting_account = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
            { sitename => $site_name },
            { rows => 1 }
        )->single;
    };

    eval {
        require Comserv::Util::PointSystem;
        my $ps = Comserv::Util::PointSystem->new(c => $c);
        $point_balance = $ps->balance($user_id);
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'csc_account',
        "Point balance query failed: $@") if $@;

    $c->stash(
        template         => 'membership/csc_account.tt',
        csc_memberships  => $csc_memberships,
        csc_plans        => $csc_plans,
        hosting_account  => $hosting_account,
        point_balance    => $point_balance,
        site_name        => $site_name,
    );
    $c->forward($c->view('TT'));
}

sub _get_patreon_config {
    my ($self, $c, $site_name) = @_;
    $site_name = lc($site_name || 'csc');
    my %cfg;
    eval {
        my @rows = $c->model('DBEncy')->resultset('EnvVariable')->search(
            { key => { -like => "patreon_${site_name}_%" } }
        )->all;
        for my $row (@rows) {
            my $key = $row->key;
            $key =~ s/^patreon_${site_name}_//;
            $cfg{$key} = $row->value;
        }
    };
    return keys %cfg ? \%cfg : undef;
}

sub _get_user_site_memberships {
    my ($self, $c, $user_id) = @_;
    return [] unless $user_id;

    my @site_info;
    eval {
        my @memberships = $c->model('DBEncy')->resultset('UserMembership')->search(
            { 'me.user_id' => $user_id },
            { prefetch => ['site', 'plan'] }
        )->all;

        my @user_roles = $c->model('DBEncy')->resultset('UserSiteRole')->search(
            { 'me.user_id' => $user_id },
            { prefetch => 'site' }
        )->all;

        my %sites_seen;

        for my $ur (@user_roles) {
            my $site = $ur->site;
            next unless $site;
            my $sname = $site->name;
            my $role  = $ur->role || '';
            
            $sites_seen{$sname} ||= {
                site_name       => $sname,
                display_name    => $site->site_display_name || $sname,
                site_id         => $site->id,
                personal_plan   => 'Free',
                personal_status => 'active',
                is_admin        => 0,
                roles           => [],
            };
            
            push @{ $sites_seen{$sname}->{roles} }, $role;
            if (lc($role) eq 'admin' || lc($role) eq 'site_admin') {
                $sites_seen{$sname}->{is_admin} = 1;
            }
        }

        for my $m (@memberships) {
            my $site = $m->site;
            next unless $site;
            my $sname = $site->name;
            
            $sites_seen{$sname} ||= {
                site_name       => $sname,
                display_name    => $site->site_display_name || $sname,
                site_id         => $site->id,
                is_admin        => 0,
                roles           => [],
            };
            
            $sites_seen{$sname}->{personal_plan}   = $m->plan ? $m->plan->name : 'Free';
            $sites_seen{$sname}->{personal_status} = $m->status;
        }

        for my $sname (keys %sites_seen) {
            my $site_info = $sites_seen{$sname};
            
            my $hosting = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
                {
                    -or => [
                        sitename => $sname,
                        sitename => lc($sname),
                        sitename => uc($sname),
                    ]
                },
                { rows => 1 }
            )->single;

            if ($hosting) {
                $site_info->{hosting_plan}   = $hosting->plan_slug;
                $site_info->{hosting_status} = $hosting->status;
                $site_info->{hosting_cost}   = $hosting->monthly_cost;
            }
        }

        @site_info = sort { $a->{display_name} cmp $b->{display_name} } values %sites_seen;
    };
    if ($@) {
        my $err = $@;
        $c->log->error("Error in _get_user_site_memberships: $err");
    }

    return \@site_info;
}

__PACKAGE__->meta->make_immutable;

1;

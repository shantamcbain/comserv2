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

sub _get_modules_data {
    my ($self, $c, $site_name) = @_;

    # Ensure system_modules table exists
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        $dbh->do(q{
            CREATE TABLE IF NOT EXISTS `system_modules` (
                `key` VARCHAR(100) NOT NULL,
                `name` VARCHAR(255) NOT NULL,
                `owner` VARCHAR(100) NOT NULL,
                `description` TEXT,
                `route` VARCHAR(255) NOT NULL,
                `monthly_cost` DECIMAL(10,2) NOT NULL DEFAULT '0.00',
                `is_active` TINYINT(1) NOT NULL DEFAULT '1',
                `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`key`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        });
    };

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
            owner       => 'CSC',
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
            key         => 'brew',
            name        => 'Brew — Brewhouse Management',
            owner       => 'Brew',
            description => 'Brewhouse and brewery operations (legacy forager Brew app). Use brew.yourdomain.com.',
            route       => '/brew',
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

    my %site_status;
    eval {
        my @site_mods = $c->model('DBEncy')->resultset('SiteModule')->search({
            sitename => $site_name,
        })->all;
        for my $sm (@site_mods) {
            $site_status{$sm->module_name} = $sm->enabled ? 1 : 0;
        }
    };

    # Load hosting account subscribed addons
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

    my %subscribed;
    if ($hosting_account && $hosting_account->requested_addons) {
        my @addons = split(/\s*,\s*/, $hosting_account->requested_addons);
        for my $a (@addons) {
            my $lc_addon = lc($a);
            $subscribed{$lc_addon} = 1;
            # Map aliases to ensure unified matching (e.g. 3d vs printing_3d)
            if ($lc_addon eq 'printing_3d' || $lc_addon eq '3d') {
                $subscribed{'3d'} = 1;
                $subscribed{'printing_3d'} = 1;
            }
            if ($lc_addon eq 'workshops' || $lc_addon eq 'workshop') {
                $subscribed{'workshop'} = 1;
                $subscribed{'workshops'} = 1;
            }
            if ($lc_addon eq 'beekeeping' || $lc_addon eq 'apiary' || $lc_addon eq 'bmaster') {
                $subscribed{'beekeeping'} = 1;
                $subscribed{'apiary'}     = 1;
            }
        }
    }

    for my $mod (@modules) {
        my $key = $mod->{key};

        # Override with DB data if exists in system_modules
        eval {
            my $db_mod = $c->model('DBEncy')->resultset('SystemModule')->find($key);
            if ($db_mod) {
                $mod->{name}         = $db_mod->name if $db_mod->name;
                $mod->{owner}        = $db_mod->owner if $db_mod->owner;
                $mod->{description}  = $db_mod->description if $db_mod->description;
                $mod->{route}        = $db_mod->route if $db_mod->route;
                $mod->{monthly_cost} = $db_mod->monthly_cost;
            }
        };

        my $default_val = $subscribed{$key} ? 1 : 0;
        $mod->{site_enabled} = exists $site_status{$key} ? $site_status{$key} : $default_val;
        $mod->{subscribed}   = $subscribed{$key} ? 1 : 0;
        $mod->{user_access}  = $c->stash->{enabled_modules}{$key} ? 1 : 0;
    }

    return \@modules;
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

    my $modules = [];
    if ($is_admin) {
        $modules = $self->_get_modules_data($c, $site_name);
    }

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
        modules            => $modules,
        is_embedded        => 1,
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

    # If post and admin, handle site module updates
    if ($c->req->method eq 'POST' && $is_admin) {
        my $params = $c->req->body_parameters;
        eval {
            my $modules_ref = $self->_get_modules_data($c, $site_name);
            foreach my $mod (@$modules_ref) {
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
            my $referer = $c->req->referer || '';
            if ($referer =~ /membership$/ || $referer =~ /membership\?/) {
                return $c->response->redirect($c->uri_for('/membership'));
            }
            return $c->response->redirect($c->uri_for($self->action_for('addons')));
        }
    }

    my $modules = $self->_get_modules_data($c, $site_name);

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

    my $site_is_csc = (lc($site_name) eq 'csc');

    $c->stash(
        template        => 'membership/Addons.tt',
        modules         => $modules,
        site_name       => $site_name,
        is_admin        => $is_admin,
        hosting_account => $hosting_account,
        site_is_csc     => $site_is_csc,
    );
    $c->forward($c->view('TT'));
}

sub hosting_signup :Local :Args(0) {
    my ($self, $c) = @_;

    my $site_name = $c->req->param('site_name') || $c->req->param('sitename') || $c->stash->{SiteName} || $c->session->{SiteName} || '';
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

        unless ($c->req->param('new')) {
            $hosting_account = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
                { sitename => $site_name }, { rows => 1 }
            )->single;
        }
    };

    # If user clicked "Learn More & Join" with new=1, render the new-site details form directly
    # (plan already chosen, form pre-filled from logged-in user)
    if ($c->req->param('new') && $c->req->param('plan')) {
        my $plan_slug = $c->req->param('plan');
        my $plan = $c->model('DBEncy')->resultset('MembershipPlan')->search(
            { slug => $plan_slug },
            { prefetch => 'inventory_item' }
        )->first;

        my $user_data = {};
        if ($c->session->{username}) {
            my $u = $c->model('DBEncy')->resultset('User')->find({ username => $c->session->{username} });
            if ($u) {
                $user_data = {
                    first_name => $u->first_name || '',
                    last_name  => $u->last_name  || '',
                    email      => $u->email      || '',
                    username   => $u->username   || '',
                };
            }
        }

        $c->stash(
            template    => 'hosting/hosting_details_form.tt',
            title       => 'Hosting Application',
            plan        => $plan,
            plan_slug   => $plan_slug,
            form_data   => $user_data,
            form_action => $c->uri_for('/hosting_signup/process'),
        );
        return $c->forward($c->view('TT'));
    }

    my %plan_price = map { $_->slug => ($_->price_monthly || 0) } @$csc_hosting_plans;

    if ($c->req->method eq 'POST') {
        my $p = $c->req->body_parameters;
        my @addon_keys = qw(beekeeping planning ai workshops helpdesk foraging ency ecommerce membership accounting printing_3d brew);
        my $addons_str = join(',', grep { $p->{"addon_$_"} } @addon_keys);
        
        my $base_price = $plan_price{ $p->{plan_slug} } // 0;
        
        my $plan_row = undef;
        eval {
            my $csc_site = $c->model('DBEncy')->resultset('Site')->search({ name => 'CSC' })->single;
            if ($csc_site) {
                $plan_row = $c->model('DBEncy')->resultset('MembershipPlan')->search({
                    site_id => $csc_site->id,
                    slug    => $p->{plan_slug},
                })->single;
            }
        };

        my %included_modules;
        if ($plan_row) {
            $included_modules{beekeeping} = $plan_row->has_beekeeping ? 1 : 0;
            $included_modules{planning}   = $plan_row->has_planning ? 1 : 0;
            $included_modules{membership} = 1;
        }

        my %module_cost = (
            beekeeping => 10.00,
            planning   => 15.00,
            accounting => 20.00,
            ency       => 5.00,
            ecommerce  => 15.00,
            helpdesk   => 10.00,
            foraging   => 5.00,
            membership => 0.00,
            '3d'       => 10.00,
        );

        eval {
            my @db_mods = $c->model('DBEncy')->resultset('SystemModule')->search({ is_active => 1 })->all;
            for my $db_mod (@db_mods) {
                $module_cost{$db_mod->key} = $db_mod->monthly_cost if defined $db_mod->monthly_cost;
            }
        };

        my $addons_extra = 0;
        foreach my $addon (grep { $p->{"addon_$_"} } @addon_keys) {
            my $key = lc($addon);
            $key = '3d' if $key eq 'printing_3d';
            $key = 'planning' if $key eq 'ai';
            
            unless ($included_modules{$key}) {
                $addons_extra += $module_cost{$key} || 0;
            }
        }

        my $monthly_cost = $base_price + $addons_extra;

        require Comserv::Util::HostingAccount;
        my $existing_url = $p->{existing_site_url} // '';
        $existing_url =~ s/^\s+|\s+$//g;
        my $save_ok = 0;
        if ($existing_url ne '' && $existing_url !~ m{^https?://}i) {
            $c->stash->{error_msg} = "Existing website URL must start with http:// or https://";
        } else {
            my $merged_notes = Comserv::Util::HostingAccount::merge_notes_with_existing_site_url(
                $p->{notes}, $existing_url
            );

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
                        notes              => $merged_notes,
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
                        notes              => $merged_notes,
                        requested_addons   => $addons_str,
                        created_by         => $c->session->{username},
                    });
                }
                $save_ok = 1;
            };
            if ($@) {
                $c->stash->{error_msg} = ($hosting_account ? "Update" : "Registration") . " failed: $@";
            }
        }
        if ($save_ok) {
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

    if ($hosting_account) {
        require Comserv::Util::HostingAccount;
        $hosting_account->{existing_site_url} = Comserv::Util::HostingAccount::extract_existing_site_url(
            $hosting_account->notes
        );
    }

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

    # Detect if logged-in user already has this plan (modify vs signup view)
    my $user_has_plan = 0;
    if ($c->session->{user_id}) {
        $user_has_plan = $c->model('DBEncy')->resultset('UserMembership')->search(
            { user_id => $c->session->{user_id}, plan_id => $plan->id, status => ['active','grace'] }
        )->count > 0;
    }

    $c->stash(
        template      => 'membership/PlanDetails.tt',
        plan          => $plan,
        site_name     => $site_name,
        patreon_cfg   => $patreon_cfg,
        user_has_plan => $user_has_plan,
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

sub _calculate_hosting_total_cost {
    my ($self, $c, $hosting) = @_;
    return 0 unless $hosting;

    my $plan_slug = $hosting->plan_slug;
    return 0 unless $plan_slug;

    # 1. Get base plan price
    my $base_price = 0;
    my $plan_row = undef;
    eval {
        my $csc_site = $c->model('DBEncy')->resultset('Site')->search({ name => 'CSC' })->single;
        if ($csc_site) {
            $plan_row = $c->model('DBEncy')->resultset('MembershipPlan')->search({
                site_id => $csc_site->id,
                slug    => $plan_slug,
            })->single;
            if ($plan_row) {
                $base_price = $plan_row->price_monthly || 0;
            }
        }
    };

    # 2. Get all system modules/addons and their pricing
    my %module_cost;
    my %included_modules;

    # Check what is included in the plan row
    if ($plan_row) {
        $included_modules{beekeeping} = $plan_row->has_beekeeping ? 1 : 0;
        $included_modules{planning}   = $plan_row->has_planning ? 1 : 0;
        $included_modules{membership} = 1; # Core membership is always included
    }

    # Fetch default/DB costs for all modules
    my @defaults = (
        { key => 'beekeeping', name => 'Beekeeping & Apiary Management', owner => 'BMaster', route => '/apiary', cost => 10.00 },
        { key => 'planning', name => 'AI Planning & Project System', owner => 'CSC', route => '/todo', cost => 15.00 },
        { key => 'accounting', name => 'Accounting & Ledger System', owner => 'CSC', route => '/Accounting', cost => 20.00 },
        { key => 'ency', name => 'Encyclopedia & Herbal Database', owner => 'ENCY', route => '/ency', cost => 5.00 },
        { key => 'ecommerce', name => 'E-Commerce & Store', owner => 'CSC', route => '/shop', cost => 15.00 },
        { key => 'helpdesk', name => 'HelpDesk Support & Guide system', owner => 'CSC', route => '/helpdesk', cost => 10.00 },
        { key => 'foraging', name => 'Foraging & Wild Harvesting Log', owner => 'Forager', route => '/foraging', cost => 5.00 },
        { key => 'membership', name => 'Multi-Site Membership System', owner => 'CSC', route => '/membership', cost => 0.00 },
        { key => '3d', name => '3D Printing & Custom Fabrication', owner => '3D', route => '/3d', cost => 10.00 },
    );

    for my $d (@defaults) {
        $module_cost{$d->{key}} = $d->{cost};
    }

    # Override costs with values from system_modules database table
    eval {
        my @db_mods = $c->model('DBEncy')->resultset('SystemModule')->search({ is_active => 1 })->all;
        for my $db_mod (@db_mods) {
            $module_cost{$db_mod->key} = $db_mod->monthly_cost if defined $db_mod->monthly_cost;
        }
    };

    # 3. Calculate cost of requested addons that are NOT included in the plan
    my $addons_cost = 0;
    if ($hosting->requested_addons) {
        my @requested = split(/\s*,\s*/, $hosting->requested_addons);
        for my $addon (@requested) {
            my $key = lc($addon);
            # Map aliases
            $key = '3d' if $key eq 'printing_3d';
            $key = 'planning' if $key eq 'ai';

            # If requested addon is not included in the plan, charge its cost
            unless ($included_modules{$key}) {
                $addons_cost += $module_cost{$key} || 0;
            }
        }
    }

    return $base_price + $addons_cost;
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
                $site_info->{hosting_cost}   = $self->_calculate_hosting_total_cost($c, $hosting);
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

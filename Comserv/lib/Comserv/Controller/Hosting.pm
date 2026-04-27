package Comserv::Controller::Hosting;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::PointSystem;
use JSON::MaybeXS qw(encode_json decode_json);
use LWP::UserAgent;
use Try::Tiny;
use Config::General;
use DateTime;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'npm_api' => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;
        
        # Default values (fallback)
        my $api_config = {
            url => $ENV{NPM_API_URL} || 'http://localhost:81/api',
            key => $ENV{NPM_API_KEY} || 'dummy_key_for_development',
            environment => $ENV{CATALYST_ENV} || 'development',
            access_scope => 'localhost-only'
        };
        
        # Try to load from environment-specific config file
        my $environment = $ENV{CATALYST_ENV} || 'development';
        my $config_file = Catalyst::Utils::home('Comserv') . "/config/npm-$environment.conf";
        
        if (-e $config_file) {
            eval {
                my $conf = Config::General->new($config_file);
                my %config_hash = $conf->getall();
                if ($config_hash{NPM}) {
                    $api_config = {
                        url => $config_hash{NPM}->{endpoint} || $api_config->{url},
                        key => $config_hash{NPM}->{api_key} || $api_config->{key},
                        environment => $config_hash{NPM}->{environment} || $api_config->{environment},
                        access_scope => $config_hash{NPM}->{access_scope} || $api_config->{access_scope}
                    };
                }
            };
            # If there's an error loading the config, we'll use the default values
            if ($@) {
                warn "Error loading NPM config from $config_file: $@";
            }
        }
        
        return $api_config;
    }
);

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        "Hosting controller auto method called");

    # Check if we have a valid API key
    if ($self->npm_api->{key} eq 'dummy_key_for_development') {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
            "NPM API key not configured. Using dummy key for development.");
        $c->stash->{api_warning} = "NPM API key not configured. Some features may not work correctly.";
    }
    
    # Log environment information
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto',
        "Using NPM environment: " . $self->npm_api->{environment} . 
        " with access scope: " . $self->npm_api->{access_scope});

    # Initialize API client
    $c->stash->{npm_ua} = LWP::UserAgent->new(
        timeout => 10,
        default_headers => HTTP::Headers->new(
            Authorization => "Bearer " . $self->npm_api->{key},
            'Content-Type' => 'application/json'
        )
    );

    return 1;
}

sub redirect_Hosted        :Path('/Hosted')   :Args(0) { $_[1]->response->redirect($_[1]->uri_for('/hosted'),  302); $_[1]->detach }
sub redirect_apply         :Path('/apply')    :Args(0) { $_[1]->response->redirect($_[1]->uri_for('/hosting_signup'), 302); $_[1]->detach }

sub hosted_dashboard :Path('/hosted') :Args(0) {
    my ($self, $c) = @_;

    my $schema   = $c->model('DBEncy');
    my $sitename = $c->session->{SiteName} || 'CSC';
    my $is_admin = $c->session->{is_admin} || 0;

    my $acct = eval { $schema->resultset('HostingAccount')->find({ sitename => $sitename }) };

    my $cost_cfg = eval {
        $schema->resultset('HostingCostConfig')->search(
            {}, { order_by => { -desc => 'id' }, rows => 1 }
        )->first;
    };

    my $all_plans = [
        { slug => 'hosting-app',      name => 'App-only (Proxy)',   sku => 'HOST-APP',    monthly => ($cost_cfg ? $cost_cfg->unit_price : 10.00) },
        { slug => 'hosting-subdomain', name => 'Subdomain + cPanel', sku => 'HOST-CPANEL', monthly => ($cost_cfg ? sprintf('%.2f', $cost_cfg->unit_price * 1.5) : 15.00) },
    ];

    $c->stash(
        template  => 'hosting/hosted_dashboard.tt',
        acct      => $acct,
        cost_cfg  => $cost_cfg,
        all_plans => $all_plans,
        sitename  => $sitename,
        is_admin  => $is_admin,
    );
}

sub hosting_accounts :Path('/accounts') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{is_admin}) {
        $c->flash->{error_msg} = 'Admin access required.';
        $c->response->redirect($c->uri_for('/hosted'));
        $c->detach;
    }

    my $schema  = $c->model('DBEncy');
    my $status  = $c->req->param('status') || 'all';
    my $search  = {};
    $search->{status} = $status unless $status eq 'all';

    my @accounts = eval { $schema->resultset('HostingAccount')->search(
        $search, { order_by => 'sitename' }
    )->all };

    my $cost_cfg = eval {
        $schema->resultset('HostingCostConfig')->search(
            {}, { order_by => { -desc => 'id' }, rows => 1 }
        )->first;
    };

    my @site_accounts = eval { $schema->resultset('SitePointAccount')->search(
        {}, { order_by => 'sitename' }
    )->all };

    my $founder_cfg = eval {
        $schema->resultset('FounderRoyaltyConfig')->search(
            { active => 1 }, { rows => 1 }
        )->first;
    };

    $c->stash(
        template      => 'hosting/admin_accounts.tt',
        accounts      => \@accounts,
        cost_cfg      => $cost_cfg,
        site_accounts => \@site_accounts,
        founder_cfg   => $founder_cfg,
        status_filter => $status,
    );
}

sub activate_hosting :Path('/hosting/activate') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{is_admin}) {
        $c->res->status(403);
        $c->stash(template => 'error.tt');
        return;
    }

    my $schema     = $c->model('DBEncy');
    my $acct_id    = $c->req->param('account_id') or do {
        $c->flash->{error_msg} = 'account_id required';
        $c->response->redirect($c->uri_for('/accounts'));
        return;
    };
    my $payment_amount = $c->req->param('payment_amount') || 0;

    my $acct = $schema->resultset('HostingAccount')->find($acct_id);
    unless ($acct) {
        $c->flash->{error_msg} = "Hosting account #$acct_id not found.";
        $c->response->redirect($c->uri_for('/accounts'));
        return;
    }

    eval {
        my $renewal = DateTime->now->add(months => 1)->strftime('%Y-%m-%d');
        $acct->update({ status => 'active', next_renewal_date => $renewal });

        if ($payment_amount > 0) {
            my $ps = Comserv::Util::PointSystem->new(c => $c);
            $ps->apply_hosting_commission($acct, $payment_amount);
        }
    };
    if ($@) {
        $c->flash->{error_msg} = "Activation error: $@";
    } else {
        $c->flash->{success_msg} = "Hosting account for " . $acct->sitename . " activated.";
    }

    $c->response->redirect($c->uri_for('/accounts'));
}

sub hosting_cost_admin :Path('/hosting/cost') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{is_admin}) {
        $c->flash->{error_msg} = 'Admin access required.';
        $c->response->redirect($c->uri_for('/user/login'));
        $c->detach;
    }

    my $schema = $c->model('DBEncy');
    my $cfg    = eval {
        $schema->resultset('HostingCostConfig')->search(
            {}, { order_by => { -desc => 'id' }, rows => 1 }
        )->first;
    };

    if ($c->req->method eq 'POST') {
        my $p = $c->req->params;
        eval {
            if ($cfg) {
                $cfg->update({
                    server_cost_monthly     => $p->{server_cost_monthly}     || $cfg->server_cost_monthly,
                    active_site_count       => $p->{active_site_count}       || $cfg->active_site_count,
                    overhead_percent        => $p->{overhead_percent}        || $cfg->overhead_percent,
                    commission_percent      => $p->{commission_percent}      || $cfg->commission_percent,
                    member_discount_percent => $p->{member_discount_percent} || $cfg->member_discount_percent,
                    notes                   => $p->{notes},
                    updated_by              => $c->session->{username},
                });
            } else {
                $cfg = $schema->resultset('HostingCostConfig')->create({
                    server_cost_monthly     => $p->{server_cost_monthly}     || 0,
                    active_site_count       => $p->{active_site_count}       || 1,
                    overhead_percent        => $p->{overhead_percent}        || 20,
                    commission_percent      => $p->{commission_percent}      || 10,
                    member_discount_percent => $p->{member_discount_percent} || 10,
                    notes                   => $p->{notes},
                    updated_by              => $c->session->{username},
                });
            }
        };
        if ($@) {
            $c->flash->{error_msg} = "Save error: $@";
        } else {
            $c->flash->{success_msg} = 'Hosting cost config saved.';
        }
        $c->response->redirect($c->uri_for('/hosting/cost'));
        return;
    }

    $c->stash(
        template => 'hosting/cost_config.tt',
        cfg      => $cfg,
    );
}

sub setup_hosting :Path('/hosting/setup') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{is_admin}) {
        $c->flash->{error_msg} = 'Admin access required.';
        $c->response->redirect($c->uri_for('/user/login'));
        $c->detach;
    }

    my $schema = $c->model('DBEncy')->schema;
    my $dbh    = $schema->storage->dbh;
    my @log;
    my @errors;

    my @tables_to_create = (
        { result => 'SitePointAccount',   table => 'site_point_accounts'   },
        { result => 'FounderRoyaltyConfig', table => 'founder_royalty_config' },
        { result => 'HostingCostConfig',  table => 'hosting_cost_config'   },
    );

    for my $spec (@tables_to_create) {
        my ($result, $table) = @{$spec}{qw(result table)};
        eval {
            my $sth = $dbh->prepare("SHOW TABLES LIKE ?");
            $sth->execute($table);
            if ($sth->fetch) {
                push @log, "Table '$table' already exists — skipped.";
            } else {
                my @stmts = $schema->deployment_statements('MySQL');
                my ($stmt) = grep { /CREATE TABLE\s+`?\Q$table\E`?/i } @stmts;
                if ($stmt) {
                    ($stmt) = ($stmt =~ /(CREATE\s+TABLE\b.*)/si);
                    $stmt =~ s/\s+CONSTRAINT\s+`[^`]+`\s+FOREIGN KEY[^,)]+(?:,\s*)?//gsi;
                    $dbh->do('SET FOREIGN_KEY_CHECKS=0');
                    $dbh->do($stmt);
                    $dbh->do('SET FOREIGN_KEY_CHECKS=1');
                    push @log, "Created table '$table' from Result '$result'.";
                } else {
                    push @errors, "No CREATE TABLE statement found for '$table'. Check the Result class.";
                }
            }
        };
        if ($@) {
            push @errors, "Error creating '$table': $@";
        }
    }

    my $now = do {
        my @t = localtime;
        sprintf('%04d-%02d-%02d %02d:%02d:%02d', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
    };

    eval {
        my $existing = $schema->resultset('HostingCostConfig')->search({}, { rows => 1 })->first;
        if ($existing) {
            push @log, "hosting_cost_config already has a row (id=" . $existing->id . ") — skipped.";
        } else {
            my $row = $schema->resultset('HostingCostConfig')->create({
                server_cost_monthly     => '50.00',
                active_site_count       => 5,
                overhead_percent        => '20.00',
                commission_percent      => '10.00',
                member_discount_percent => '10.00',
                notes                   => 'Initial seed: CAD 50/mo ÷ 5 sites + 20% overhead = CAD 12/site/mo',
                updated_by              => $c->session->{username},
            });
            push @log, "Created hosting_cost_config (id=" . $row->id . "). Unit price: CAD " . $row->unit_price . "/mo.";
        }
    };
    push @errors, "Error seeding hosting_cost_config: $@" if $@;

    eval {
        my $existing = $schema->resultset('FounderRoyaltyConfig')->search({ active => 1 }, { rows => 1 })->first;
        if ($existing) {
            push @log, "founder_royalty_config already has an active row (" . $existing->founder_username . ") — skipped.";
        } else {
            my $row = $schema->resultset('FounderRoyaltyConfig')->create({
                founder_username => 'Shanta',
                royalty_percent  => '5.00',
                active           => 1,
                note             => 'Founder royalty on all hosting revenue',
            });
            push @log, "Created founder_royalty_config for Shanta 5% (id=" . $row->id . ").";
        }
    };
    push @errors, "Error seeding founder_royalty_config: $@" if $@;

    my @items = (
        {
            sku              => 'HOST-APP',
            name             => 'CSC App-only Hosting (Proxy)',
            sitename         => 'CSC',
            category         => 'Service',
            item_origin      => 'service',
            description      => 'App-only hosting via Nginx Proxy Manager. Your Catalyst app served under a CSC subdomain or custom domain. No cPanel.',
            unit_of_measure  => 'month',
            unit_price       => '10.00',
            unit_cost        => '12.00',
            status           => 'active',
            show_in_shop     => 0,
            hide_stock_count => 1,
            is_consumable    => 0,
            is_reusable      => 1,
            is_assemblable   => 0,
            created_by       => $c->session->{username},
            updated_by       => $c->session->{username},
            created_at       => $now,
            updated_at       => $now,
        },
        {
            sku              => 'HOST-CPANEL',
            name             => 'CSC Subdomain + cPanel Hosting',
            sitename         => 'CSC',
            category         => 'Service',
            item_origin      => 'service',
            description      => 'Full cPanel hosting account on WHC.ca with a CSC subdomain or custom domain. Includes email, databases, file manager.',
            unit_of_measure  => 'month',
            unit_price       => '15.00',
            unit_cost        => '18.00',
            status           => 'active',
            show_in_shop     => 0,
            hide_stock_count => 1,
            is_consumable    => 0,
            is_reusable      => 1,
            is_assemblable   => 0,
            created_by       => $c->session->{username},
            updated_by       => $c->session->{username},
            created_at       => $now,
            updated_at       => $now,
        },
    );

    for my $item_data (@items) {
        eval {
            my $existing = $schema->resultset('InventoryItem')->find({
                sku      => $item_data->{sku},
                sitename => 'CSC',
            });
            if ($existing) {
                push @log, "InventoryItem " . $item_data->{sku} . " already exists (id=" . $existing->id . ") — skipped.";
            } else {
                my $row = $schema->resultset('InventoryItem')->create($item_data);
                push @log, "Created InventoryItem " . $item_data->{sku} . " (id=" . $row->id . ").";
            }
        };
        push @errors, "Error seeding " . $item_data->{sku} . ": $@" if $@;
    }

    $c->stash(
        template => 'hosting/setup.tt',
        log      => \@log,
        errors   => \@errors,
    );
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Hosting dashboard accessed");

    # Check if user is logged in and has admin privileges
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $root_controller->check_user_roles($c, 'admin')) {
        # Format roles for logging
        my $roles_debug = 'none';
        if (defined $c->session->{roles}) {
            if (ref($c->session->{roles}) eq 'ARRAY') {
                $roles_debug = join(', ', @{$c->session->{roles}});
            } else {
                $roles_debug = $c->session->{roles};
            }
        }
        
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
            "Unauthorized access attempt to Hosting dashboard. User: " . 
            ($c->session->{username} || 'none') . ", Roles: " . $roles_debug);
        $c->response->status(403);
        $c->stash(
            template => 'CSC/error/access_denied.tt',
            error_message => 'You do not have permission to access the Hosting dashboard.'
        );
        return;
    }

    # For admin users, we allow access from any location (including remote)
    # This is used for creating proxies for new customer sites over ZeroTier VPN
    if ($c->req->address !~ /^127\.0\.0\.1$|^::1$|^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
        # Just log the remote access for auditing purposes
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "Remote access to Hosting from IP: " . $c->req->address . 
            " by user: " . ($c->session->{username} || 'none') . 
            ", Roles: " . (ref($c->session->{roles}) eq 'ARRAY' ? 
                          join(', ', @{$c->session->{roles}}) : 
                          ($c->session->{roles} || 'none')));
        
        # Push debug message to stash as requested (no warning displayed to user)
        $c->stash->{debug_msg} = "Remote access from " . $c->req->address . 
            " by user " . ($c->session->{username} || 'none');
    }

    if ($self->npm_api->{key} eq 'dummy_key_for_development' || !$ENV{NPM_API_URL}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "NPM not configured — showing unconfigured state");
        $c->stash(
            proxies      => [],
            template     => 'CSC/proxy_manager.tt',
            environment  => $self->npm_api->{environment},
            access_scope => $self->npm_api->{access_scope},
            npm_not_configured => 1,
        );
        return;
    }

    try {
        my $res = $c->stash->{npm_ua}->get($self->npm_api->{url} . "/nginx/proxy-hosts");
        unless ($res->is_success) {
            my $error_details = "Status: " . $res->status_line;
            if    ($res->code == 401) { $error_details .= " — invalid API key";            }
            elsif ($res->code == 404) { $error_details .= " — incorrect API URL";          }
            elsif ($res->code == 0)   { $error_details .= " — NPM not running/accessible"; }

            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                "Failed to fetch proxies: $error_details");
            $c->stash(
                proxies           => [],
                template          => 'CSC/proxy_manager.tt',
                environment       => $self->npm_api->{environment},
                access_scope      => $self->npm_api->{access_scope},
                npm_fetch_error   => "NPM API request failed: $error_details",
            );
            return;
        }

        $c->stash(
            proxies      => decode_json($res->decoded_content),
            template     => 'CSC/proxy_manager.tt',
            environment  => $self->npm_api->{environment},
            access_scope => $self->npm_api->{access_scope},
        );
    } catch {
        my $error_message = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            "Proxy fetch exception: $error_message");
        $c->stash(
            proxies         => [],
            template        => 'CSC/proxy_manager.tt',
            environment     => $self->npm_api->{environment},
            access_scope    => $self->npm_api->{access_scope},
            npm_fetch_error => "Connection error: $error_message",
        );
        return;
    };
}

sub create_proxy :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_proxy',
        "Creating new proxy mapping");

    # Check if user is logged in and has admin privileges
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $root_controller->check_user_roles($c, 'admin')) {
        # Format roles for logging
        my $roles_debug = 'none';
        if (defined $c->session->{roles}) {
            if (ref($c->session->{roles}) eq 'ARRAY') {
                $roles_debug = join(', ', @{$c->session->{roles}});
            } else {
                $roles_debug = $c->session->{roles};
            }
        }
        
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_proxy',
            "Unauthorized access attempt to create proxy. User: " . 
            ($c->session->{username} || 'none') . ", Roles: " . $roles_debug);
        $c->response->status(403);
        $c->stash(
            template => 'CSC/error/access_denied.tt',
            error_message => 'You do not have permission to create proxy mappings.'
        );
        return;
    }

    # Check if this is a read-only or localhost-only environment
    if ($self->npm_api->{access_scope} eq 'read-only') {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_proxy',
            "Attempted to create proxy in read-only environment");
        $c->stash(
            template => 'CSC/error/access_denied.tt',
            error_message => 'This environment is read-only. You cannot create proxy mappings in this environment.'
        );
        return;
    }
    
    # For admin users, we allow proxy creation from any location (including remote)
    # This is used for creating proxies for new customer sites over ZeroTier VPN
    if ($c->req->address !~ /^127\.0\.0\.1$|^::1$|^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
        # Just log the remote access for auditing purposes
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_proxy',
            "Remote proxy creation attempt from IP: " . $c->req->address . 
            " by user: " . ($c->session->{username} || 'none') . 
            ", Roles: " . (ref($c->session->{roles}) eq 'ARRAY' ? 
                          join(', ', @{$c->session->{roles}}) : 
                          ($c->session->{roles} || 'none')));
        
        # Push debug message to stash as requested (no warning displayed to user)
        $c->stash->{debug_msg} = "Remote proxy creation from " . $c->req->address . 
            " by user " . ($c->session->{username} || 'none');
    }

    my $params = {
        domain_names    => [$c->req->params->{domain}],
        forward_scheme  => $c->req->params->{scheme} || 'http',
        forward_host    => $c->req->params->{backend_ip},
        forward_port    => $c->req->params->{backend_port},
        ssl_forced      => $c->req->params->{ssl} ? JSON::true : JSON::false,
        advanced_config => join("\n",
            "proxy_set_header Host \$host;",
            "proxy_set_header X-Real-IP \$remote_addr;")
    };

    try {
        # Make sure npm_ua is defined before trying to use it
        if (!defined $c->stash->{npm_ua}) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
                "npm_ua is not defined. Initializing it now.");
            
            # Initialize API client if it wasn't done in auto
            $c->stash->{npm_ua} = LWP::UserAgent->new(
                timeout => 10,
                default_headers => HTTP::Headers->new(
                    Authorization => "Bearer " . $self->npm_api->{key},
                    'Content-Type' => 'application/json'
                )
            );
            
            # Add debug message to stash
            $c->stash->{debug_msg} = "Had to initialize npm_ua in create_proxy action because it wasn't defined";
        }
        
        # Double-check that npm_ua is now defined
        unless (defined $c->stash->{npm_ua}) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
                "Failed to initialize npm_ua");
            
            # Use the general error template with specific error details
            $c->response->status(500);
            $c->stash(
                template => 'error.tt',
                error_title => 'Hosting Proxy Creation Error',
                error_msg => 'Failed to initialize the API client for Nginx Proxy Manager.',
                technical_details => 'The npm_ua object could not be created. This may indicate a configuration issue.',
                action_required => 'Please check your NPM API configuration in the environment or config file.',
                debug_msg => "Failed to initialize npm_ua in Hosting create_proxy action"
            );
            return;
        }
        
        # Log the API request for debugging
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_proxy',
            "Making API request to: " . $self->npm_api->{url} . "/nginx/proxy-hosts for domain: " . $params->{domain_names}[0]);
        
        my $res = $c->stash->{npm_ua}->post(
            $self->npm_api->{url} . "/nginx/proxy-hosts",
            Content => encode_json($params)
        );

        unless ($res->is_success) {
            my $error_details = "Status: " . $res->status_line;
            if ($res->code == 401) {
                $error_details .= " - This may indicate an invalid API key";
            } elsif ($res->code == 404) {
                $error_details .= " - This may indicate an incorrect API URL";
            } elsif ($res->code == 0) {
                $error_details .= " - This may indicate that the Nginx Proxy Manager is not running or not accessible";
            } elsif ($res->code == 400) {
                $error_details .= " - This may indicate invalid parameters or a duplicate domain";
            }
            
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
                "Proxy creation failed: " . $error_details);
            
            # Use the general error template with more specific error details
            $c->response->status(500);
            $c->stash(
                template => 'error.tt',
                error_title => 'Hosting Proxy Creation Error',
                error_msg => 'Failed to create proxy for domain: ' . $params->{domain_names}[0],
                technical_details => 'API request failed: ' . $error_details,
                action_required => 'Please check that the Nginx Proxy Manager is running and accessible, and that your API key is valid.',
                debug_msg => "Failed to create proxy in Hosting create_proxy action"
            );
            return;
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_proxy',
            "Successfully created proxy for " . $params->{domain_names}[0]);
        $c->res->redirect($c->uri_for('/hosting'));
    } catch {
        my $error_message = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
            "Proxy creation error: $error_message");
        
        # Determine the likely cause of the error
        my $action_required = 'Please check that the Nginx Proxy Manager is running and accessible.';
        if ($error_message =~ /Can't call method "post" on an undefined value/) {
            $action_required = 'The API client was not properly initialized. Please check your NPM API configuration and ensure the auto method is being called correctly.';
        } elsif ($error_message =~ /Connection refused/) {
            $action_required = 'Connection to the Nginx Proxy Manager was refused. Please check that the service is running and the URL is correct.';
        } elsif ($error_message =~ /timeout/i) {
            $action_required = 'The connection to the Nginx Proxy Manager timed out. Please check that the service is running and responsive.';
        } elsif ($error_message =~ /certificate/i) {
            $action_required = 'There was an SSL certificate issue connecting to the Nginx Proxy Manager. Please check your SSL configuration.';
        } elsif ($error_message =~ /JSON/i) {
            $action_required = 'There was an error encoding the request parameters. Please check that all required fields are provided and valid.';
        }
        
        # Use the general error template with more specific error details
        $c->response->status(500);
        $c->stash(
            template => 'error.tt',
            error_title => 'Hosting Proxy Creation Error',
            error_msg => 'Failed to create proxy for domain: ' . $params->{domain_names}[0],
            technical_details => 'Exception: ' . $error_message,
            action_required => $action_required,
            debug_msg => "Exception caught in Hosting create_proxy action"
        );
        return;
    };
}

# ============================================================
# renew_hosting — member self-service hosting plan renewal via points
# GET  /hosting/renew?site_id=N   — show renewal form
# POST /hosting/renew             — process renewal, debit points
# ============================================================
sub renew_hosting :Path('renew') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->flash->{error_msg} = 'Please log in to renew your hosting.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $user_id  = $c->session->{user_id};
    my $site_id  = $c->req->param('site_id') || 0;
    my $plan_id  = $c->req->param('plan_id')  || 0;
    my $billing  = $c->req->param('billing_cycle') || 'monthly';

    my ($membership, $plan, $ps, $balance);

    eval {
        $ps      = Comserv::Util::PointSystem->new(c => $c);
        $balance = $ps->balance($user_id);

        $membership = $c->model('DBEncy')->resultset('UserMembership')->search(
            { 'me.user_id' => $user_id, 'me.site_id' => $site_id },
            { prefetch => ['plan', 'site'] }
        )->first if $site_id;

        $plan = $c->model('DBEncy')->resultset('MembershipPlan')->find($plan_id) if $plan_id;
        $plan ||= $membership->plan if $membership;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'renew_hosting',
            "Error loading renewal data: $@");
        $c->flash->{error_msg} = 'Error loading hosting data.';
        $c->response->redirect($c->uri_for('/membership/account'));
        return;
    }

    unless ($membership && $plan) {
        $c->flash->{error_msg} = 'No active hosting membership found for this site.';
        $c->response->redirect($c->uri_for('/membership/account'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $cost = $billing eq 'annual' ? $plan->price_annual : $plan->price_monthly;

        if ($cost > 0) {
            my ($ok, $err) = $ps->debit(
                user_id          => $user_id,
                amount           => $cost,
                transaction_type => 'spend',
                description      => 'Hosting renewal: ' . $plan->name
                                  . ' (' . $billing . ') for site_id=' . $site_id,
                reference_type   => 'hosting',
                reference_id     => $site_id,
            );
            unless ($ok) {
                $c->flash->{error_msg} = $err;
                $c->response->redirect($c->uri_for('/hosting/renew', { site_id => $site_id }));
                return;
            }
        }

        my $new_expiry = $billing eq 'annual'
            ? DateTime->now->add(years  => 1)->strftime('%Y-%m-%d %H:%M:%S')
            : DateTime->now->add(months => 1)->strftime('%Y-%m-%d %H:%M:%S');

        $membership->update({
            plan_id       => $plan->id,
            billing_cycle => $billing,
            status        => 'active',
            expires_at    => $new_expiry,
        });

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'renew_hosting',
            "Hosting renewed: user_id=$user_id site_id=$site_id plan=" . $plan->name
            . " billing=$billing cost=$cost expiry=$new_expiry");

        $c->flash->{success_msg} = 'Hosting renewed until ' . $new_expiry . '.';
        $c->response->redirect($c->uri_for('/membership/account'));
        return;
    }

    my $cost_monthly = $plan->price_monthly;
    my $cost_annual  = $plan->price_annual;

    $c->stash(
        template      => 'hosting/RenewHosting.tt',
        membership    => $membership,
        plan          => $plan,
        balance       => $balance,
        cost_monthly  => $cost_monthly,
        cost_annual   => $cost_annual,
        site_id       => $site_id,
    );
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;
1;
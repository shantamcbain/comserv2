package Comserv::Controller::Mail;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Comserv::Util::Logging;
BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub auto :Private {
    my ($self, $c) = @_;
    return 1;
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Accessing mail index page");
    
    my $username = $c->session->{username};
    my $roles = $c->session->{roles} || [];
    
    # Convert roles to array if it's a string
    if (!ref $roles) {
        $roles = $roles ? [$roles] : [];
    }
    
    # Determine user type and permissions
    my $is_admin = grep { $_ eq 'admin' } @$roles;
    my $is_developer = grep { $_ eq 'developer' } @$roles;
    my $is_member = grep { $_ eq 'member' } @$roles;
    my $is_logged_in = $username ? 1 : 0;
    
    # Check if user has a mail account (assume username-based for now)
    my $has_mail_account = 0;
    if ($is_logged_in) {
        # TODO: Query actual mail account database when available
        # For now, members, developers, and admins get mail access
        $has_mail_account = $is_member || $is_developer || $is_admin;
    }
    
    # Set stash variables for template
    $c->stash(
        is_admin => $is_admin,
        is_developer => $is_developer,
        is_member => $is_member,
        is_logged_in => $is_logged_in,
        has_mail_account => $has_mail_account,
        template => 'mail/mail.index.tt'
    );

    # Forward to the TT view to render the template
    $c->forward($c->view('TT'));
}

sub send_welcome_email :Local {
    my ($self, $c, $user) = @_;
    
    my $site_id = $user->site_id;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_welcome_email', 
        "Sending welcome email to " . $user->email);
    
    try {
        my $mail_model = $c->model('Mail');
        my $subject = "Welcome to the Application";
        my $body = "Hello " . $user->first_name . ",\n\nWelcome to our application!";
        
        my $result = $mail_model->send_email($c, $user->email, $subject, $body, $site_id);
        
        unless ($result) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_welcome_email', 
                "Failed to send welcome email to " . $user->email);
            $c->stash->{debug_msg} = "Could not send welcome email";
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_welcome_email', 
            "Welcome email error: $_");
        $c->stash->{debug_msg} = "Welcome email failed: $_";
    };
}

sub add_mail_config_form :Local {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config_form', 
        "Displaying mail configuration form");
    
    # Check if user is admin
    my $roles = $c->session->{roles} || [];
    if (!ref $roles) {
        $roles = $roles ? [$roles] : [];
    }
    
    my $is_admin = grep { $_ eq 'admin' } @$roles;
    
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_mail_config_form', 
            "Non-admin user attempted to access mail config form");
        $c->stash(
            error_msg => 'Access denied. Admin privileges required.',
            template => 'mail/mail.index.tt'
        );
        return;
    }
    
    # Get current site name from stash or session
    my $current_sitename = $c->stash->{SiteName} || $c->session->{SiteName} || '';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config_form', 
        "Current SiteName: '$current_sitename', Username: " . ($c->session->{username} || 'none'));
    
    # Determine if user is CSC admin (has access to all sites)
    # CSC admin can be identified by SiteName='CSC' OR by having admin role
    my $is_csc = ($current_sitename eq 'CSC') ? 1 : 0;
    
    # If SiteName is not set but user is admin, default to CSC
    if (!$current_sitename && $is_admin) {
        $current_sitename = 'CSC';
        $is_csc = 1;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config_form', 
            "No SiteName found for admin user, defaulting to CSC");
    }
    
    # Load all sites if CSC user
    my @all_sites = ();
    if ($is_csc) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config_form', 
            "Loading all sites for CSC user");
        
        my $schema = $c->model('DBEncy');
        my $sites_rs = $schema->resultset('Site')->search(
            {},
            { order_by => 'name' }
        );
        
        while (my $site = $sites_rs->next) {
            push @all_sites, {
                id => $site->id,
                name => $site->name,
            };
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config_form', 
            "Loaded " . scalar(@all_sites) . " sites");
    }
    
    $c->stash(
        current_sitename => $current_sitename,
        is_csc => $is_csc,
        all_sites => \@all_sites,
        template => 'mail/add_mail_config_form.tt'
    );
}

sub add_mail_config :Local {
    my ($self, $c) = @_;
    
    
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config', 
        "add_mail_config action called - Method: " . $c->req->method);
    
    # Check if user is admin
    my $roles = $c->session->{roles} || [];
    if (!ref $roles) {
        $roles = $roles ? [$roles] : [];
    }
    
    my $is_admin = grep { $_ eq 'admin' } @$roles;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config', 
        "User: " . ($c->session->{username} || 'not logged in') . ", Is Admin: " . ($is_admin ? 'yes' : 'no'));
    
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_mail_config', 
            "Non-admin user attempted to save mail config");
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->res->redirect($c->uri_for('/mail'));
        return;
    }
    
    my $params = $c->req->params;
    my $site_input = $params->{site_id};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config', 
        "Processing mail configuration for site input: '$site_input'");
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'add_mail_config', 
        "Params: smtp_host=" . ($params->{smtp_host} || 'undef') . 
        ", smtp_port=" . ($params->{smtp_port} || 'undef') .
        ", smtp_user=" . ($params->{smtp_user} || 'undef'));
    
    # Validate required fields
    unless ($site_input) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_mail_config', 
            "Missing site_id parameter");
        $c->stash(
            error_msg => "Please provide a Site ID or Site Name",
            template => 'mail/add_mail_config_form.tt'
        );
        $c->forward($c->view('TT'));
        return;
    }
    
    # Lookup site_id if user entered a site name instead of numeric ID
    my $site_id;
    if ($site_input =~ /^\d+$/) {
        # It's already a numeric ID
        $site_id = $site_input;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'add_mail_config', 
            "Using numeric site_id: $site_id");
    } else {
        # It's a site name, look it up
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config', 
            "Looking up site by name: '$site_input'");
        
        my $schema = $c->model('DBEncy');
        my $site = $schema->resultset('Site')->search(
            { name => $site_input },
            { rows => 1 }
        )->single;
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'add_mail_config', 
            "Site lookup result: " . (defined $site ? "found" : "not found"));
        
        if ($site) {
            $site_id = $site->id;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config', 
                "Found site '$site_input' with ID: $site_id");
        } else {
            # Debug: List all available sites
            my @all_site_names = ();
            my $sites_rs = $schema->resultset('Site')->search({}, { order_by => 'name' });
            while (my $s = $sites_rs->next) {
                push @all_site_names, $s->name;
            }
            
            my $available_sites = join(', ', @all_site_names);
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_mail_config', 
                "Site not found: '$site_input'. Available sites: $available_sites");
            
            # Reload the form with error and site list
            my @all_sites_for_form = ();
            my $current_sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
            my $is_csc = 1; # Assume CSC if we're in site lookup
            
            $sites_rs->reset; # Reset the iterator
            while (my $s = $sites_rs->next) {
                push @all_sites_for_form, {
                    id => $s->id,
                    name => $s->name,
                };
            }
            
            $c->stash(
                error_msg => "Site '$site_input' not found. Available sites: $available_sites",
                current_sitename => $current_sitename,
                is_csc => $is_csc,
                all_sites => \@all_sites_for_form,
                template => 'mail/add_mail_config_form.tt'
            );
            $c->forward($c->view('TT'));
            return;
        }
    }
    
    unless ($params->{smtp_host} && $params->{smtp_port}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_mail_config', 
            "Incomplete SMTP config for site_id $site_id");
        $c->stash(
            error_msg => "Please provide SMTP host and port",
            template => 'mail/add_mail_config_form.tt'
        );
        $c->forward($c->view('TT'));
        return;
    }
    
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config', 
            "Connecting to database to save SMTP config");
        
        my $schema = $c->model('DBEncy');
        my $site_config_rs = $schema->resultset('SiteConfig');
        
        # Create or update SMTP configuration
        my $saved_count = 0;
        for my $config_key (qw(smtp_host smtp_port smtp_user smtp_password smtp_from smtp_ssl)) {
            # Handle checkbox: smtp_ssl will be '1' if checked, undefined if not
            my $value = $params->{$config_key};
            
            # For smtp_ssl, default to 0 if not checked
            if ($config_key eq 'smtp_ssl' && !defined $value) {
                $value = 0;
            }
            
            next unless defined $value;
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'add_mail_config', 
                "Saving $config_key for site_id $site_id, value: " . (defined $value ? $value : 'undef'));
            
            my $result = $site_config_rs->update_or_create({
                site_id => $site_id,
                config_key => $config_key,
                config_value => $value,
            });
            $saved_count++;
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'add_mail_config', 
                "Saved $config_key: " . ($result->in_storage ? "exists" : "created"));
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config', 
            "SMTP config saved for site_id $site_id ($saved_count fields saved)");
        $c->flash->{success_msg} = "SMTP configuration saved successfully for site ID $site_id ($saved_count settings)";
        $c->res->redirect($c->uri_for('/mail/mail_admin_dashboard'));
        return;
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_mail_config', 
            "Failed to save SMTP config: $error");
        $c->flash->{error_msg} = "Failed to save configuration: $error";
        $c->res->redirect($c->uri_for('/mail/add_mail_config_form'));
        return;
    };
}

sub edit_smtp_config :Local {
    my ($self, $c) = @_;
    
    # Check if user is admin
    my $roles = $c->session->{roles} || [];
    if (!ref $roles) {
        $roles = $roles ? [$roles] : [];
    }
    
    my $is_admin = grep { $_ eq 'admin' } @$roles;
    
    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->res->redirect($c->uri_for('/mail'));
        return;
    }
    
    my $site_id = $c->req->param('site_id');
    
    unless ($site_id) {
        $c->flash->{error_msg} = 'Site ID is required';
        $c->res->redirect($c->uri_for('/mail/mail_admin_dashboard'));
        return;
    }
    
    # If this is a POST request, update the configuration
    if ($c->req->method eq 'POST') {
        
        my $params = $c->req->params;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_smtp_config', 
            "Processing SMTP config update for site_id $site_id");
        
        try {
            my $schema = $c->model('DBEncy');
            my $site_config_rs = $schema->resultset('SiteConfig');
            
            # Update SMTP configuration
            my $updated_count = 0;
            for my $config_key (qw(smtp_host smtp_port smtp_user smtp_password smtp_from smtp_ssl)) {
                # Handle checkbox: smtp_ssl will be 'ssl' if checked, undefined if not
                my $value = $params->{$config_key};
                
                # For smtp_ssl, default to '' if not checked (empty = no SSL)
                if ($config_key eq 'smtp_ssl' && !defined $value) {
                    $value = '';
                }
                
                next unless defined $value;
                
                # Skip password if it's empty (user wants to keep existing password)
                if ($config_key eq 'smtp_password' && $value eq '') {
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_smtp_config', 
                        "Skipping empty password field (keeping existing)");
                    next;
                }
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_smtp_config', 
                    "Updating $config_key for site_id $site_id, value: $value");
                
                $site_config_rs->update_or_create({
                    site_id => $site_id,
                    config_key => $config_key,
                    config_value => $value,
                });
                $updated_count++;
            }
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_smtp_config', 
                "SMTP config updated for site_id $site_id ($updated_count fields updated)");
            $c->flash->{success_msg} = "SMTP configuration updated successfully ($updated_count settings)";
            $c->res->redirect($c->uri_for('/mail/mail_admin_dashboard'));
            return;
        } catch {
            my $error = $_;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_smtp_config', 
                "Failed to update SMTP config: $error");
            $c->flash->{error_msg} = "Failed to update configuration: $error";
        };
    }
    
    # Load existing configuration and site name
    my %config;
    my $site_name = '';
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_smtp_config',
            "Loading existing SMTP config for site_id $site_id");
        
        my $schema = $c->model('DBEncy');
        
        # Get site name
        my $site = $schema->resultset('Site')->find($site_id);
        if ($site) {
            $site_name = $site->name;
        }
        
        my $dbh = $schema->schema->storage->dbh;
        my $sth = $dbh->prepare("
            SELECT config_key, config_value 
            FROM site_config 
            WHERE site_id = ? AND config_key LIKE 'smtp_%'
        ");
        $sth->execute($site_id);
        
        my $row_count = 0;
        while (my $row = $sth->fetchrow_hashref()) {
            $row_count++;
            $config{$row->{config_key}} = $row->{config_value};
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_smtp_config',
                "Loaded config: " . $row->{config_key});
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_smtp_config',
            "Loaded $row_count SMTP config items for site_id $site_id ($site_name)");
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_smtp_config',
            "Failed to load SMTP config: $error");
    };
    
    $c->stash(
        site_id => $site_id,
        site_name => $site_name,
        smtp_config => \%config,
        template => 'mail/EditSmtpConfig.tt'
    );
    
    $c->forward($c->view('TT'));
}

sub test_smtp_config :Local {
    my ($self, $c) = @_;
    
    # Check if user is admin
    my $roles = $c->session->{roles} || [];
    if (!ref $roles) {
        $roles = $roles ? [$roles] : [];
    }
    
    my $is_admin = grep { $_ eq 'admin' } @$roles;
    
    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->res->redirect($c->uri_for('/mail'));
        return;
    }
    
    my $site_id = $c->req->param('site_id');
    
    unless ($site_id) {
        $c->flash->{error_msg} = 'Site ID is required';
        $c->res->redirect($c->uri_for('/mail/mail_admin_dashboard'));
        return;
    }
    
    # Load SMTP configuration
    my %config;
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_smtp_config',
            "Loading SMTP config for testing site_id $site_id");
        
        my $schema = $c->model('DBEncy');
        my $dbh = $schema->schema->storage->dbh;
        my $sth = $dbh->prepare("
            SELECT config_key, config_value 
            FROM site_config 
            WHERE site_id = ? AND config_key LIKE 'smtp_%'
        ");
        $sth->execute($site_id);
        
        my $row_count = 0;
        while (my $row = $sth->fetchrow_hashref()) {
            $row_count++;
            $config{$row->{config_key}} = $row->{config_value};
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_smtp_config',
            "Loaded $row_count SMTP config items for testing");
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'test_smtp_config',
            "Failed to load SMTP config: $error");
        $c->flash->{error_msg} = "Failed to load SMTP configuration: $error";
        $c->res->redirect($c->uri_for('/mail/mail_admin_dashboard'));
        return;
    };
    
    # Validate that we have the required config
    unless ($config{smtp_host} && $config{smtp_port}) {
        $c->flash->{error_msg} = 'SMTP host and port must be configured before testing';
        $c->res->redirect($c->uri_for('/mail/mail_admin_dashboard'));
        return;
    }
    
    # Test SMTP connection
    my $test_result = {
        success => 0,
        message => '',
    };
    
    try {
        my $use_ssl = $config{smtp_ssl} && $config{smtp_ssl} ne '0';
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_smtp_config',
            "Testing SMTP: host=$config{smtp_host}, port=$config{smtp_port}, SSL=" . ($use_ssl ? 'yes' : 'no'));
        
        require Net::SMTP;
        
        my $smtp = Net::SMTP->new(
            $config{smtp_host},
            Port => $config{smtp_port},
            Timeout => 10,
            Debug => 1,
            SSL => $use_ssl,
        );
        
        if ($smtp) {
            # Check both smtp_user and legacy smtp_username key
            my $smtp_user = $config{smtp_user} || $config{smtp_username} || '';
            my $smtp_pass = $config{smtp_password} || '';

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_smtp_config',
                "Auth check: user='" . ($smtp_user ? $smtp_user : '(none)') . "' password=" . ($smtp_pass ? '(set)' : '(not set)'));

            if ($smtp_user && $smtp_pass) {
                require Authen::SASL;
                if ($smtp->auth($smtp_user, $smtp_pass)) {
                    $test_result->{success} = 1;
                    $test_result->{message} = "Connected and authenticated as $smtp_user on $config{smtp_host}:$config{smtp_port}";
                } else {
                    $test_result->{message} = "Connected to $config{smtp_host}:$config{smtp_port} but AUTH failed for $smtp_user: " . $smtp->message();
                }
            } elsif ($smtp_user && !$smtp_pass) {
                $test_result->{message} = "Connected to $config{smtp_host}:$config{smtp_port} but password not set for $smtp_user — save the password first";
            } else {
                $test_result->{success} = 1;
                $test_result->{message} = "Connected to $config{smtp_host}:$config{smtp_port} (no credentials configured — OK for PMG relay)";
            }
            $smtp->quit();
        } else {
            $test_result->{message} = "Failed to connect to SMTP server: $@";
        }
    } catch {
        $test_result->{message} = "SMTP test error: $_";
    };
    
    if ($test_result->{success}) {
        $c->flash->{success_msg} = $test_result->{message};
    } else {
        $c->flash->{error_msg} = $test_result->{message};
    }
    
    $c->res->redirect($c->uri_for('/mail/mail_admin_dashboard'));
}

# New method to create a mail account using Virtualmin API
sub create_mail_account :Local {
    my ($self, $c) = @_;
    
    my $params = $c->req->params;
    my $email = $params->{email};
    my $password = $params->{password};
    my $domain = $params->{domain};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_mail_account', 
        "Creating mail account for $email on domain $domain");
    
    # Validate required fields
    unless ($email && $password && $domain) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account', 
            "Missing required parameters for mail account creation");
        $c->stash->{debug_msg} = "Email, password, and domain are required";
        return;
    }
    
    # Validate email format
    unless ($email =~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account', 
            "Invalid email format: $email");
        $c->stash->{debug_msg} = "Invalid email format";
        return;
    }
    
    try {
        my $result = $c->model('Mail')->create_mail_account($c, $email, $password, $domain);
        
        if ($result) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_mail_account', 
                "Mail account created successfully for $email");
            $c->stash->{status_msg} = "Mail account created successfully";
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account', 
                "Failed to create mail account for $email");
            # debug_msg is already set in the model method
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_mail_account', 
            "Error creating mail account: $_");
        $c->stash->{debug_msg} = "Error creating mail account: $_";
    };
    
    # Redirect to appropriate page based on context
    if ($c->req->params->{redirect_url}) {
        $c->res->redirect($c->req->params->{redirect_url});
    } else {
        $c->res->redirect($c->uri_for('/mail'));
    }
}

sub mail_admin_dashboard :Local {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'mail_admin_dashboard', 
        "Accessing mail admin dashboard");
    
    # Check if user is admin
    my $roles = $c->session->{roles} || [];
    if (!ref $roles) {
        $roles = $roles ? [$roles] : [];
    }
    
    my $is_admin = grep { $_ eq 'admin' } @$roles;
    
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'mail_admin_dashboard', 
            "Non-admin user attempted to access mail admin dashboard");
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->res->redirect($c->uri_for('/mail'));
        return;
    }
    
    # Get mail server statistics and configuration
    my $mail_stats = {
        total_domains => 0,
        total_accounts => 0,
        active_servers => 0,
    };
    
    my @smtp_servers = ();
    
    try {
        my $schema = $c->model('DBEncy');
        
        # Count mail domains
        eval {
            $mail_stats->{total_domains} = $schema->resultset('MailDomain')->count;
        };
        
        # Load SMTP server configurations from SiteConfig with site names
        eval {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'mail_admin_dashboard',
                "Attempting to load SMTP configurations from site_config table");
            
            my $dbh = $schema->schema->storage->dbh;
            my $sth = $dbh->prepare("
                SELECT sc.site_id, sc.config_key, sc.config_value, s.name as site_name
                FROM site_config sc
                LEFT JOIN sites s ON sc.site_id = s.id
                WHERE sc.config_key LIKE 'smtp_%' 
                ORDER BY sc.site_id, sc.config_key
            ");
            $sth->execute();
            
            my %servers_by_site;
            my $row_count = 0;
            while (my $row = $sth->fetchrow_hashref()) {
                $row_count++;
                my $site_id = $row->{site_id};
                my $key = $row->{config_key};
                my $value = $row->{config_value};
                my $site_name = $row->{site_name} || "Unknown";
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'mail_admin_dashboard',
                    "Loaded SMTP config: site_id=$site_id ($site_name), key=$key");
                
                $servers_by_site{$site_id} ||= { 
                    site_id => $site_id,
                    site_name => $site_name
                };
                $servers_by_site{$site_id}{$key} = $value;
            }
            
            @smtp_servers = sort { $a->{site_id} <=> $b->{site_id} } values %servers_by_site;
            $mail_stats->{active_servers} = scalar @smtp_servers;

            # Auto-migrate legacy 'smtp_username' key → 'smtp_user' in DB
            eval {
                my $migrated = $dbh->do(
                    "UPDATE site_config SET config_key='smtp_user' WHERE config_key='smtp_username'"
                );
                if ($migrated && $migrated > 0) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'mail_admin_dashboard',
                        "Migrated $migrated row(s): smtp_username → smtp_user in site_config");
                }
            };
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'mail_admin_dashboard',
                "Loaded $row_count SMTP config rows, " . scalar(@smtp_servers) . " servers total");
        };
        
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'mail_admin_dashboard',
                "Could not load SMTP configs: $@");
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'mail_admin_dashboard', 
            "Error loading mail statistics: $_");
    };
    
    $c->stash(
        mail_stats => $mail_stats,
        smtp_servers => \@smtp_servers,
        template => 'mail/AdminDashboard.tt'
    );
    
    $c->forward($c->view('TT'));
}

sub send_test_email :Local {
    my ($self, $c) = @_;

    my $roles = $c->session->{roles} || [];
    $roles = ref $roles ? $roles : ($roles ? [$roles] : []);
    unless (grep { $_ eq 'admin' } @$roles) {
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->res->redirect($c->uri_for('/mail'));
        return;
    }

    my $site_id = $c->req->param('site_id') || $c->session->{site_id} || $c->stash->{site_id};

    # If still no site_id, resolve from SiteName in stash
    if (!$site_id && $c->stash->{SiteName}) {
        eval {
            my $site = $c->model('DBEncy')->resultset('Site')->find({ name => $c->stash->{SiteName} });
            $site_id = $site->id if $site;
        };
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_test_email',
            "Resolved site_id=" . ($site_id // 'undef') . " from SiteName=" . $c->stash->{SiteName});
    }

    my $to = $c->req->param('to') || '';

    unless ($to) {
        $c->flash->{error_msg} = 'Please provide a recipient email address.';
        $c->res->redirect($c->uri_for('/mail/mail_admin_dashboard'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_test_email',
        "Admin test-send requested: to=$to site_id=" . ($site_id // 'undef'));

    my $smtp_config = $c->model('Mail')->get_smtp_config($c, $site_id);
    my $via = $smtp_config
        ? ($smtp_config->{host} . ':' . $smtp_config->{port} . ' (' . ($smtp_config->{user} || 'no-auth') . ')')
        : 'fallback (no DB config)';

    my $body = "This is a test email from the Comserv Unified Mail System.\n\n"
             . "Sent via: $via\n"
             . "Site ID: " . ($site_id // 'none — used fallback') . "\n"
             . "Time: " . scalar(localtime()) . "\n\n"
             . "If you received this, the mail path is working correctly.";

    my $result = eval {
        $c->model('Mail')->send_email(
            $c, $to,
            'Comserv Mail System Test',
            $body,
            $site_id,
        );
    };
    my $err = $@;

    if ($err) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_test_email',
            "send_test_email threw exception: $err");
        $c->flash->{error_msg} = "Test email failed (exception): $err";
    } elsif ($result) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_test_email',
            "Test email sent successfully to $to");
        $c->flash->{success_msg} = "Test email sent to $to — check your inbox and the application log for SMTP transcript.";
    } else {
        my $debug = $c->stash->{debug_msg} || 'see application log for SMTP transcript';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_test_email',
            "Test email send returned failure for $to");
        $c->flash->{error_msg} = "Test email failed to $to — $debug";
    }

    $c->res->redirect($c->uri_for('/mail/mail_admin_dashboard'));
}


# ─────────────────────────────────────────────────────────────
#  MAILING LIST MANAGEMENT
# ─────────────────────────────────────────────────────────────

sub _get_site_id {
    my ($self, $c) = @_;
    my $site_id = $c->session->{site_id} || $c->stash->{site_id};
    if (!$site_id && $c->stash->{SiteName}) {
        eval {
            my $site = $c->model('DBEncy')->resultset('Site')->find({ name => $c->stash->{SiteName} });
            $site_id = $site->id if $site;
        };
    }
    return $site_id;
}

sub lists :Local :Args(0) {
    my ($self, $c) = @_;

    my $site_id = $self->_get_site_id($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'lists',
        "lists action called: site_id=" . ($site_id // 'undef') . " SiteName=" . ($c->stash->{SiteName} // 'undef'));

    # Auto-create and sync the three default list categories
    $self->_sync_default_lists($c, $site_id);

    my (@default_lists, @custom_lists);
    eval {
        my $rs = $c->model('DBEncy')->resultset('MailingList')->search(
            { site_id => $site_id, is_active => 1 },
            { order_by => 'name' }
        );
        while (my $list = $rs->next) {
            my @subs;
            eval {
                my $dbh = $c->model('DBEncy')->schema->storage->dbh;
                # Try full query with email-only columns; fall back to uid-only if columns missing
                my $sth;
                eval {
                    $sth = $dbh->prepare(
                        "SELECT s.id, s.user_id, s.email AS sub_email,
                                s.first_name AS sub_first, s.last_name AS sub_last,
                                u.username, u.first_name, u.last_name, u.email AS user_email
                         FROM mailing_list_subscriptions s
                         LEFT JOIN users u ON u.id = s.user_id
                         WHERE s.mailing_list_id = ? AND s.is_active = 1
                         ORDER BY COALESCE(u.username, s.email)"
                    );
                    $sth->execute($list->id);
                };
                if ($@) {
                    # Fallback: columns not yet added — uid-only query
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'lists',
                        "Falling back to uid-only subscription query (run ALTER migration): $@");
                    $sth = $dbh->prepare(
                        "SELECT s.id, s.user_id,
                                u.username, u.first_name, u.last_name, u.email AS user_email
                         FROM mailing_list_subscriptions s
                         LEFT JOIN users u ON u.id = s.user_id
                         WHERE s.mailing_list_id = ? AND s.is_active = 1
                         ORDER BY u.username"
                    );
                    $sth->execute($list->id);
                }
                while (my $row = $sth->fetchrow_hashref) {
                    if ($row->{user_email}) {
                        push @subs, {
                            user_id    => $row->{user_id},
                            username   => $row->{username}   || '',
                            first_name => $row->{first_name} || '',
                            last_name  => $row->{last_name}  || '',
                            email      => $row->{user_email},
                        };
                    } elsif ($row->{sub_email}) {
                        push @subs, {
                            user_id    => undef,
                            username   => '',
                            first_name => $row->{sub_first} || '',
                            last_name  => $row->{sub_last}  || '',
                            email      => $row->{sub_email},
                        };
                    }
                }
            };
            if ($@) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'lists',
                    "Subscription query failed for list " . $list->id . ": $@");
            }
            my $row = {
                id               => $list->id,
                name             => $list->name,
                description      => $list->description,
                list_email       => $list->list_email,
                is_software_only => $list->is_software_only,
                is_default       => ($list->description =~ /^\[auto\]/) ? 1 : 0,
                subscriber_count => scalar @subs,
                subscribers      => \@subs,
                created_at       => $list->created_at,
            };
            if ($row->{is_default}) {
                push @default_lists, $row;
            } else {
                push @custom_lists, $row;
            }
        }
    };
    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'lists', "DB error: $@") if $@;

    $c->stash(
        default_lists => \@default_lists,
        custom_lists  => \@custom_lists,
        mailing_lists => [@default_lists, @custom_lists],
        template => 'mail/mailing_lists.tt',
    );
    $c->forward($c->view('TT'));
}

sub lists_create :Path('/mail/lists/create') :Args(0) {
    my ($self, $c) = @_;

    my $roles = $c->session->{roles} || [];
    $roles = ref $roles ? $roles : ($roles ? [$roles] : []);
    unless (grep { $_ eq 'admin' } @$roles) {
        $c->flash->{error_msg} = 'Admin access required.';
        $c->res->redirect($c->uri_for('/mail/lists'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $site_id = $self->_get_site_id($c);
        my $name    = $c->req->param('name') || '';
        unless ($name) {
            $c->stash(debug_msg => 'List name is required.', template => 'mail/create_list.tt');
            $c->forward($c->view('TT'));
            return;
        }
        eval {
            $c->model('DBEncy')->resultset('MailingList')->create({
                site_id         => $site_id,
                name            => $name,
                description     => $c->req->param('description') || '',
                list_email      => $c->req->param('list_email')  || undef,
                is_software_only => $c->req->param('is_software_only') ? 1 : 0,
                is_active       => 1,
                created_by      => $c->session->{user_id} || 0,
            });
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'lists_create', "Create failed: $@");
            $c->stash(debug_msg => "Failed to create list: $@", template => 'mail/create_list.tt');
            $c->forward($c->view('TT'));
            return;
        }
        $c->flash->{success_msg} = "Mailing list '$name' created.";
        $c->res->redirect($c->uri_for('/mail/lists'));
        return;
    }

    $c->stash(template => 'mail/create_list.tt');
    $c->forward($c->view('TT'));
}

sub lists_delete :Path('/mail/lists') :Args(2) {
    my ($self, $c, $list_id, $action) = @_;
    return $self->lists_subscribers($c, $list_id) if $action eq 'subscribers';
    return $self->lists_edit($c, $list_id)        if $action eq 'edit';

    my $roles = $c->session->{roles} || [];
    $roles = ref $roles ? $roles : ($roles ? [$roles] : []);
    unless (grep { $_ eq 'admin' } @$roles) {
        $c->flash->{error_msg} = 'Admin access required.';
        $c->res->redirect($c->uri_for('/mail/lists'));
        return;
    }

    eval {
        my $list = $c->model('DBEncy')->resultset('MailingList')->find($list_id);
        $list->update({ is_active => 0 }) if $list;
    };
    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'lists_delete', "Error: $@") if $@;
    $c->flash->{success_msg} = 'Mailing list removed.';
    $c->res->redirect($c->uri_for('/mail/lists'));
}

sub lists_edit {
    my ($self, $c, $list_id) = @_;

    my $list = eval { $c->model('DBEncy')->resultset('MailingList')->find($list_id) };
    unless ($list) {
        $c->flash->{error_msg} = 'List not found.';
        $c->res->redirect($c->uri_for('/mail/lists'));
        return;
    }

    if ($c->req->method eq 'POST') {
        eval {
            $list->update({
                name            => $c->req->param('name')        || $list->name,
                description     => $c->req->param('description') // $list->description,
                list_email      => $c->req->param('list_email')  || undef,
                is_software_only => $c->req->param('is_software_only') ? 1 : 0,
            });
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'lists_edit', "Update failed: $@");
            $c->flash->{error_msg} = "Update failed: $@";
        } else {
            $c->flash->{success_msg} = 'List updated.';
        }
        $c->res->redirect($c->uri_for('/mail/lists'));
        return;
    }

    $c->stash(list => $list, template => 'mail/edit_list.tt');
    $c->forward($c->view('TT'));
}

sub lists_subscribers {
    my ($self, $c, $list_id) = @_;

    my @subscribers;
    my $list_name = '';
    eval {
        my $list = $c->model('DBEncy')->resultset('MailingList')->find($list_id);
        $list_name = $list->name if $list;
        my $rs = $c->model('DBEncy')->resultset('MailingListSubscription')->search(
            { mailing_list_id => $list_id, is_active => 1 },
            { prefetch => 'user', order_by => 'user.username' }
        );
        while (my $sub = $rs->next) {
            push @subscribers, {
                id     => $sub->id,
                source => $sub->subscription_source,
                user   => {
                    id       => $sub->user->id,
                    username => $sub->user->username,
                    email    => $sub->user->email,
                    first_name => $sub->user->first_name,
                    last_name  => $sub->user->last_name,
                },
            };
        }
    };
    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'lists_subscribers', "Error: $@") if $@;

    $c->stash(
        list_id     => $list_id,
        list_name   => $list_name,
        subscribers => \@subscribers,
        template    => 'mail/list_subscribers.tt',
    );
    $c->forward($c->view('TT'));
}

# ─────────────────────────────────────────────────────────────
#  SITE MAILOUT — send to users / paid members / custom list
# ─────────────────────────────────────────────────────────────

sub mass_email :Local :Args(0) {
    my ($self, $c) = @_;

    my $roles = $c->session->{roles} || [];
    $roles = ref $roles ? $roles : ($roles ? [$roles] : []);
    unless (grep { $_ eq 'admin' } @$roles) {
        $c->flash->{error_msg} = 'Admin access required.';
        $c->res->redirect($c->uri_for('/mail'));
        return;
    }

    my $site_id = $self->_get_site_id($c);

    my $all_count  = _count_site_users($c, $site_id, 'all');
    my $paid_count = _count_site_users($c, $site_id, 'paid');

    # Sync auto-generated lists (all members, role lists, workshop attendees) before displaying
    $self->_sync_default_lists($c, $site_id) if $site_id;

    my @lists;
    eval {
        my $rs = $c->model('DBEncy')->resultset('MailingList')->search(
            { site_id => $site_id, is_active => 1 }, { order_by => 'name' }
        );
        while (my $list = $rs->next) {
            my $sub_count = 0;
            eval {
                $sub_count = $c->model('DBEncy')->resultset('MailingListSubscription')->search(
                    { mailing_list_id => $list->id, is_active => 1 }
                )->count;
            };
            push @lists, { id => $list->id, name => $list->name, count => $sub_count };
        }
    };

    $c->stash(
        user_count   => $all_count,
        paid_count   => $paid_count,
        mailing_lists => \@lists,
        template     => 'mail/mailout_compose.tt',
    );
    $c->forward($c->view('TT'));
}

sub send_mass_email :Local :Args(0) {
    my ($self, $c) = @_;

    my $roles = $c->session->{roles} || [];
    $roles = ref $roles ? $roles : ($roles ? [$roles] : []);
    unless (grep { $_ eq 'admin' } @$roles) {
        $c->flash->{error_msg} = 'Admin access required.';
        $c->res->redirect($c->uri_for('/mail'));
        return;
    }

    my $site_id = $self->_get_site_id($c);
    my $subject   = $c->req->param('subject') || '';
    my $body_tmpl = $c->req->param('body')    || '';
    my $group     = $c->req->param('group')   || 'all';
    my $custom_addresses = $c->req->param('custom_addresses') || '';
    my @list_ids  = $c->req->param('list_ids');

    unless ($subject && $body_tmpl) {
        $c->flash->{error_msg} = 'Subject and message body are required.';
        $c->res->redirect($c->uri_for('/mail/mass_email'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_mass_email',
        "Mailout started: site_id=$site_id group=$group list_ids=[" . join(',', @list_ids) . "] subject='$subject'");

    # Build recipient list — track seen emails to avoid duplicates
    my @recipients;
    my %seen_email;

    my $_add_recip = sub {
        my ($rec) = @_;
        my $email = lc($rec->{email} // '');
        return unless $email && $email =~ /\@/;
        return if $seen_email{$email}++;
        push @recipients, $rec;
    };

    if ($group eq 'custom') {
        # Custom addresses only — look up names from DB
        for my $addr (split /[\s,;]+/, $custom_addresses) {
            $addr =~ s/^\s+|\s+$//g;
            next unless $addr =~ /\@/;
            my $rec = { email => $addr, first_name => '', last_name => '', username => '' };
            eval {
                my $u = $c->model('DBEncy')->resultset('User')->find({ email => $addr });
                if ($u) {
                    $rec->{first_name} = $u->first_name || '';
                    $rec->{last_name}  = $u->last_name  || '';
                    $rec->{username}   = $u->username   || '';
                } else {
                    # Try mailing_list_subscriptions for email-only entries
                    my $dbh = $c->model('DBEncy')->schema->storage->dbh;
                    my $sth = $dbh->prepare(
                        "SELECT first_name, last_name FROM mailing_list_subscriptions WHERE email=? AND is_active=1 LIMIT 1"
                    );
                    eval { $sth->execute($addr) };
                    unless ($@) {
                        my ($fn, $ln) = $sth->fetchrow_array;
                        $rec->{first_name} = $fn || '';
                        $rec->{last_name}  = $ln || '';
                    }
                }
            };
            $_add_recip->($rec);
        }
    } else {
        # DB users (all or paid members)
        my @users = _get_site_users($c, $site_id, $group);
        $_add_recip->($_) for @users;

        # Also add any custom addresses provided
        for my $addr (split /[\s,;]+/, $custom_addresses) {
            $addr =~ s/^\s+|\s+$//g;
            $_add_recip->({ email => $addr, first_name => '', last_name => '', username => $addr })
                if $addr =~ /\@/;
        }
    }

    # Add recipients from any checked named mailing lists (deduped via %seen_email)
    for my $list_id (@list_ids) {
        next unless $list_id && $list_id =~ /^\d+$/;
        $_add_recip->($_) for _get_list_recipients($c, $list_id);
    }

    unless (@recipients) {
        $c->flash->{error_msg} = 'No recipients found for the selected group.';
        $c->res->redirect($c->uri_for('/mail/mass_email'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_mass_email',
        "Sending to " . scalar(@recipients) . " recipients");

    my ($sent, $failed) = (0, 0);
    my @failures;

    for my $r (@recipients) {
        next unless $r->{email};

        # Personalise subject and body per recipient
        my $per_subject = $subject;
        $per_subject =~ s/\[FIRST_NAME\]/$r->{first_name} || ''/ge;
        $per_subject =~ s/\[LAST_NAME\]/$r->{last_name}   || ''/ge;
        $per_subject =~ s/\[EMAIL\]/$r->{email}/g;
        $per_subject =~ s/\[USERNAME\]/$r->{username}     || ''/ge;

        my $body = $body_tmpl;
        $body =~ s/\[FIRST_NAME\]/$r->{first_name} || ''/ge;
        $body =~ s/\[LAST_NAME\]/$r->{last_name}   || ''/ge;
        $body =~ s/\[EMAIL\]/$r->{email}/g;
        $body =~ s/\[USERNAME\]/$r->{username}     || ''/ge;

        my $result = eval {
            $c->model('Mail')->send_email($c, $r->{email}, $per_subject, $body, $site_id, { html => 1 });
        };
        if ($@ || !$result) {
            $failed++;
            my $reason = $@ || $c->stash->{debug_msg} || 'unknown error';
            push @failures, "$r->{email}: $reason";
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_mass_email',
                "Failed to send to $r->{email}: $reason");
        } else {
            $sent++;
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_mass_email',
        "Mailout complete: sent=$sent failed=$failed");

    if ($sent && !$failed) {
        $c->flash->{success_msg} = "Mailout complete — $sent email(s) sent successfully.";
    } elsif ($sent) {
        $c->flash->{success_msg} = "$sent sent. $failed failed — check the application log for details.";
    } else {
        $c->flash->{error_msg} = "All $failed sends failed. Check SMTP config and application log.";
    }

    $c->res->redirect($c->uri_for('/mail/mass_email'));
}

sub send_mailout_test :Local :Args(0) {
    my ($self, $c) = @_;

    my $roles = $c->session->{roles} || [];
    $roles = ref $roles ? $roles : ($roles ? [$roles] : []);
    unless (grep { $_ eq 'admin' } @$roles) {
        $c->res->body('Forbidden'); $c->res->status(403); return;
    }

    my $site_id   = $self->_get_site_id($c);
    my $subject   = $c->req->param('subject') || '(no subject)';
    my $body_tmpl = $c->req->param('body')    || '';

    unless ($body_tmpl) {
        $c->flash->{error_msg} = 'Message body is required for test send.';
        $c->res->redirect($c->uri_for('/mail/mass_email'));
        return;
    }

    # Get admin's own details to use as the sample recipient
    my $admin_email = $c->session->{email} || '';
    my $admin_first = $c->session->{first_name} || $c->session->{username} || 'Admin';
    my $admin_last  = $c->session->{last_name}  || '';
    my $admin_user  = $c->session->{username}   || '';

    # Try to load from DB if session is sparse
    unless ($admin_email) {
        eval {
            my $u = $c->model('DBEncy')->resultset('User')->find($c->session->{user_id});
            if ($u) {
                $admin_email = $u->email      || '';
                $admin_first = $u->first_name || $admin_first;
                $admin_last  = $u->last_name  || '';
                $admin_user  = $u->username   || $admin_user;
            }
        };
    }

    unless ($admin_email) {
        $c->flash->{error_msg} = 'Could not determine your email address for the test send.';
        $c->res->redirect($c->uri_for('/mail/mass_email'));
        return;
    }

    # Personalise with admin's own details so the preview is realistic
    my $body = $body_tmpl;
    $body =~ s/\[FIRST_NAME\]/$admin_first/g;
    $body =~ s/\[LAST_NAME\]/$admin_last/g;
    $body =~ s/\[EMAIL\]/$admin_email/g;
    $body =~ s/\[USERNAME\]/$admin_user/g;

    my $test_subject = "[TEST PREVIEW] $subject";

    my $result = eval {
        $c->model('Mail')->send_email($c, $admin_email, $test_subject, $body, $site_id, { html => 1 });
    };

    $c->res->content_type('application/json; charset=utf-8');
    if ($@ || !$result) {
        my $err = $@ || $c->stash->{debug_msg} || 'unknown error';
        $err =~ s/"/\\"/g;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_mailout_test',
            "Test send failed to $admin_email: $err");
        $c->res->body('{"ok":0,"msg":"Test send failed: ' . $err . '"}');
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_mailout_test',
            "Test preview sent to $admin_email");
        $c->res->body('{"ok":1,"msg":"Test preview sent to ' . $admin_email . ' — check your inbox."}');
    }
}

# ─── helpers ──────────────────────────────────────────────────

sub _count_site_users {
    my ($c, $site_id, $group) = @_;
    my $count = 0;
    eval {
        if ($group eq 'paid') {
            $count = $c->model('DBEncy')->resultset('UserMembership')->search({
                site_id => $site_id,
                status  => ['active', 'grace'],
            })->count;
        } else {
            $count = $c->model('DBEncy')->resultset('UserSiteRole')->search({
                site_id => $site_id,
            }, { group_by => 'user_id' })->count;
        }
    };
    return $count;
}

sub _get_site_users {
    my ($c, $site_id, $group) = @_;
    my @users;
    eval {
        if ($group eq 'paid') {
            my $rs = $c->model('DBEncy')->resultset('UserMembership')->search(
                { 'me.site_id' => $site_id, 'me.status' => ['active', 'grace'] },
                { prefetch => 'user', group_by => 'me.user_id' }
            );
            while (my $mem = $rs->next) {
                my $u = $mem->user;
                next unless $u && $u->email;
                push @users, {
                    email      => $u->email,
                    first_name => $u->first_name || '',
                    last_name  => $u->last_name  || '',
                    username   => $u->username   || '',
                };
            }
        } else {
            my $rs = $c->model('DBEncy')->resultset('UserSiteRole')->search(
                { 'me.site_id' => $site_id },
                { prefetch => 'user', group_by => 'me.user_id' }
            );
            while (my $row = $rs->next) {
                my $u = $row->user;
                next unless $u && $u->email;
                push @users, {
                    email      => $u->email,
                    first_name => $u->first_name || '',
                    last_name  => $u->last_name  || '',
                    username   => $u->username   || '',
                };
            }
        }
    };
    return @users;
}

sub _get_list_recipients {
    my ($c, $list_id) = @_;
    my @recipients;
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare(
            "SELECT s.user_id, s.email AS sub_email, s.first_name AS sub_first, s.last_name AS sub_last,
                    u.email AS user_email, u.first_name, u.last_name, u.username
             FROM mailing_list_subscriptions s
             LEFT JOIN users u ON u.id = s.user_id
             WHERE s.mailing_list_id = ? AND s.is_active = 1"
        );
        $sth->execute($list_id);
        while (my $row = $sth->fetchrow_hashref) {
            my $email = $row->{user_email} || $row->{sub_email};
            next unless $email;
            push @recipients, {
                email      => $email,
                first_name => $row->{first_name} || $row->{sub_first} || '',
                last_name  => $row->{last_name}  || $row->{sub_last}  || '',
                username   => $row->{username}   || '',
            };
        }
    };
    return @recipients;
}


# ─────────────────────────────────────────────────────────────
#  DEFAULT LIST AUTO-SYNC
#  Runs every time /mail/lists is loaded.
#  Lists are identified by description starting with "[auto]".
#  Subscriptions are fully resynced from live DB state.
# ─────────────────────────────────────────────────────────────

sub _sync_default_lists {
    my ($self, $c, $site_id) = @_;
    unless ($site_id) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_sync_default_lists',
            "No site_id — skipping default list sync");
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_default_lists',
        "Starting default list sync for site_id=$site_id");

    eval { $self->_sync_all_members_list($c, $site_id) };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_sync_default_lists',
        "All-members sync error: $@") if $@;

    eval { $self->_sync_role_lists($c, $site_id) };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_sync_default_lists',
        "Role-list sync error: $@") if $@;

    eval { $self->_sync_workshop_attendees_list($c, $site_id) };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_sync_default_lists',
        "Workshop-attendees sync error: $@") if $@;
}

sub _upsert_list_subscriptions {
    my ($self, $c, $list_id, $user_ids_ref, $source) = @_;
    my $dbh = $c->model('DBEncy')->schema->storage->dbh;

    # Mark all auto subscriptions for this list+source inactive
    eval {
        $dbh->do(
            "UPDATE mailing_list_subscriptions SET is_active=0 WHERE mailing_list_id=? AND subscription_source=?",
            undef, $list_id, $source
        );
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_upsert_list_subscriptions',
            "Mark-inactive failed for list $list_id: $@");
        return;
    }

    my $check_uid_sth = $dbh->prepare(
        "SELECT id FROM mailing_list_subscriptions WHERE mailing_list_id=? AND user_id=? AND subscription_source=?"
    );
    my $update_sth = $dbh->prepare(
        "UPDATE mailing_list_subscriptions SET is_active=1 WHERE id=?"
    );
    my $insert_uid_sth = $dbh->prepare(
        "INSERT INTO mailing_list_subscriptions (mailing_list_id, user_id, subscription_source, is_active) VALUES (?,?,?,1)"
    );

    # Lazily prepare email statements only if needed (columns may not exist yet pre-ALTER)
    my ($check_email_sth, $insert_email_sth, $email_stmts_ok);

    for my $entry (@$user_ids_ref) {
        if (ref $entry eq 'HASH') {
            my $email = $entry->{email};
            my $first = $entry->{first_name} || '';
            my $last  = $entry->{last_name}  || '';
            next unless $email;

            # Prepare email statements on first use
            unless (defined $email_stmts_ok) {
                eval {
                    $check_email_sth = $dbh->prepare(
                        "SELECT id FROM mailing_list_subscriptions WHERE mailing_list_id=? AND email=? AND subscription_source=?"
                    );
                    $insert_email_sth = $dbh->prepare(
                        "INSERT INTO mailing_list_subscriptions (mailing_list_id, email, first_name, last_name, subscription_source, is_active) VALUES (?,?,?,?,?,1)"
                    );
                    $email_stmts_ok = 1;
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_upsert_list_subscriptions',
                        "Email column not available yet (run ALTER migration): $@");
                    $email_stmts_ok = 0;
                }
            }
            next unless $email_stmts_ok;

            eval { $check_email_sth->execute($list_id, $email, $source) };
            next if $@;
            my $row = $check_email_sth->fetchrow_hashref;
            if ($row) {
                eval { $update_sth->execute($row->{id}) };
            } else {
                eval { $insert_email_sth->execute($list_id, $email, $first, $last, $source) };
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_upsert_list_subscriptions',
                    "email-only insert error for $email: $@") if $@;
            }
        } else {
            my $uid = $entry;
            eval { $check_uid_sth->execute($list_id, $uid, $source) };
            next if $@;
            my $row = $check_uid_sth->fetchrow_hashref;
            if ($row) {
                eval { $update_sth->execute($row->{id}) };
            } else {
                eval { $insert_uid_sth->execute($list_id, $uid, $source) };
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_upsert_list_subscriptions',
                    "user_id insert error for uid=$uid: $@") if $@;
            }
        }
    }
}

sub _find_or_create_list {
    my ($self, $c, $site_id, $name, $description) = @_;
    my $list_rs = $c->model('DBEncy')->resultset('MailingList');
    my $list = $list_rs->find({ site_id => $site_id, name => $name });
    unless ($list) {
        $list = $list_rs->create({
            site_id          => $site_id,
            name             => $name,
            description      => $description,
            is_software_only => 1,
            is_active        => 1,
            created_by       => 0,
        });
    } else {
        $list->update({ is_active => 1, description => $description });
    }
    return $list;
}

sub _sync_all_members_list {
    my ($self, $c, $site_id) = @_;

    my $list = $self->_find_or_create_list($c, $site_id,
        'All Site Members',
        '[auto] Everyone who has created an account on this site'
    );

    # All users with any role on this site
    my @user_ids = $c->model('DBEncy')->resultset('UserSiteRole')->search(
        { site_id => $site_id },
        { columns => ['user_id'], distinct => 1 }
    )->get_column('user_id')->all;

    $self->_upsert_list_subscriptions($c, $list->id, \@user_ids, 'auto-all');

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_all_members_list',
        "Synced All Site Members: " . scalar(@user_ids) . " users for site_id=$site_id");
}

sub _sync_role_lists {
    my ($self, $c, $site_id) = @_;

    # Get all distinct roles for this site
    my @roles = $c->model('DBEncy')->resultset('UserSiteRole')->search(
        { site_id => $site_id },
        { columns => ['role'], distinct => 1 }
    )->get_column('role')->all;

    for my $role (@roles) {
        next unless $role;
        my $list_name = "Role: $role";
        my $list = $self->_find_or_create_list($c, $site_id,
            $list_name,
            "[auto] All users with the '$role' role on this site"
        );

        my @user_ids = $c->model('DBEncy')->resultset('UserSiteRole')->search(
            { site_id => $site_id, role => $role },
            { columns => ['user_id'] }
        )->get_column('user_id')->all;

        $self->_upsert_list_subscriptions($c, $list->id, \@user_ids, 'auto-role');

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_role_lists',
            "Synced role list '$list_name': " . scalar(@user_ids) . " users for site_id=$site_id");
    }
}

sub _sync_workshop_attendees_list {
    my ($self, $c, $site_id) = @_;

    my $list = $self->_find_or_create_list($c, $site_id,
        'All Workshop Attendees',
        '[auto] All users registered for any active workshop on this site'
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_workshop_attendees_list',
        "Syncing workshop attendees for site_id=$site_id (active workshops only, excluding cancelled)");

    # Get all active workshop_ids for this site — BOTH from site_workshop join table AND workshop.site_id
    # Exclude only cancelled workshops; completed/in_progress/published are all valid
    my %seen_wid;
    my @workshop_ids;

    eval {
        my @via_link = $c->model('DBEncy')->resultset('SiteWorkshop')->search(
            { site_id => $site_id }
        )->get_column('workshop_id')->all;

        if (@via_link) {
            # Filter to non-cancelled workshops from the id list
            my @active = $c->model('DBEncy')->resultset('WorkShop')->search(
                { id => { -in => \@via_link }, status => { '!=' => 'cancelled' } }
            )->get_column('id')->all;
            for my $wid (@active) {
                unless ($seen_wid{$wid}++) { push @workshop_ids, $wid }
            }
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_workshop_attendees_list',
            "Workshops via site_workshop for site_id=$site_id: [" . join(',', @workshop_ids) . "]");
    };

    eval {
        my @via_direct = $c->model('DBEncy')->resultset('WorkShop')->search(
            { site_id => $site_id, status => { '!=' => 'cancelled' } }
        )->get_column('id')->all;
        for my $wid (@via_direct) {
            unless ($seen_wid{$wid}++) { push @workshop_ids, $wid }
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_workshop_attendees_list',
            "Workshops via WorkShop.site_id for site_id=$site_id: [" . join(',', @via_direct) . "]");
    };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_workshop_attendees_list',
        "Total unique workshops for site_id=$site_id: [" . join(',', @workshop_ids) . "]");

    my @entries;
    if (@workshop_ids) {
        # Log statuses for debugging
        my $status_rs = $c->model('DBEncy')->resultset('Participant')->search(
            { workshop_id => { -in => \@workshop_ids } },
            { columns => ['status'], distinct => 1 }
        );
        my @statuses = $status_rs->get_column('status')->all;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_workshop_attendees_list',
            "Participant statuses for workshops [" . join(',', @workshop_ids) . "]: " .
            (scalar @statuses ? join(', ', @statuses) : 'NONE'));

        # Include all non-cancelled participants
        my $part_rs = $c->model('DBEncy')->resultset('Participant')->search(
            {
                workshop_id => { -in  => \@workshop_ids },
                status      => { '!=' => 'cancelled' },
            },
            { columns => ['user_id', 'email', 'name', 'first_name', 'last_name'], distinct => 1 }
        );

        my %seen_email;
        while (my $p = $part_rs->next) {
            my $uid   = $p->user_id;
            my $email = $p->email || '';

            # Prefer explicit first/last; fall back to splitting the name field
            my $first = eval { $p->first_name } || '';
            my $last  = eval { $p->last_name  } || '';
            if (!$first && !$last) {
                my $name = $p->name || '';
                ($first, $last) = $name =~ /^(\S+)\s+(.+)$/ ? ($1, $2) : ($name, '');
            }

            if ($uid) {
                push @entries, $uid;
            } elsif ($email && !$seen_email{lc $email}++) {
                # Try to find user account by email
                my $user;
                eval {
                    $user = $c->model('DBEncy')->resultset('User')->find({ email => $email });
                };
                if ($user && $user->id) {
                    push @entries, $user->id;
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_workshop_attendees_list',
                        "Resolved participant email $email to user_id=" . $user->id);
                } else {
                    push @entries, { email => $email, first_name => $first, last_name => $last };
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_workshop_attendees_list',
                        "Email-only participant: $email ($first $last) — no system account");
                }
            }
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_workshop_attendees_list',
            "Total participant entries: " . scalar(@entries) . " for " . scalar(@workshop_ids) . " workshops");
    }

    $self->_upsert_list_subscriptions($c, $list->id, \@entries, 'auto-workshop');

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_workshop_attendees_list',
        "Synced Workshop Attendees: " . scalar(@entries) . " entries for site_id=$site_id (" .
        scalar(@workshop_ids) . " workshops)");
}

__PACKAGE__->meta->make_immutable;
1;

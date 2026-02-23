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
        ", smtp_username=" . ($params->{smtp_username} || 'undef'));
    
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
        for my $config_key (qw(smtp_host smtp_port smtp_username smtp_password smtp_from smtp_ssl)) {
            next unless defined $params->{$config_key};
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'add_mail_config', 
                "Saving $config_key for site_id $site_id");
            
            my $result = $site_config_rs->update_or_create({
                site_id => $site_id,
                config_key => $config_key,
                config_value => $params->{$config_key},
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
            for my $config_key (qw(smtp_host smtp_port smtp_username smtp_password smtp_from smtp_ssl)) {
                next unless defined $params->{$config_key};
                
                # Skip password if it's empty (user wants to keep existing password)
                if ($config_key eq 'smtp_password' && $params->{$config_key} eq '') {
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_smtp_config', 
                        "Skipping empty password field (keeping existing)");
                    next;
                }
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_smtp_config', 
                    "Updating $config_key for site_id $site_id");
                
                $site_config_rs->update_or_create({
                    site_id => $site_id,
                    config_key => $config_key,
                    config_value => $params->{$config_key},
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
        require Net::SMTP;
        
        my $smtp = Net::SMTP->new(
            $config{smtp_host},
            Port => $config{smtp_port},
            Timeout => 10,
            Debug => 0,
            SSL => $config{smtp_ssl} ? 1 : 0,
        );
        
        if ($smtp) {
            # Try to authenticate if credentials are provided
            if ($config{smtp_username} && $config{smtp_password}) {
                if ($smtp->auth($config{smtp_username}, $config{smtp_password})) {
                    $test_result->{success} = 1;
                    $test_result->{message} = "Successfully connected and authenticated to SMTP server";
                } else {
                    $test_result->{message} = "Connected but authentication failed: " . $smtp->message();
                }
            } else {
                $test_result->{success} = 1;
                $test_result->{message} = "Successfully connected to SMTP server (authentication not configured)";
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
                LEFT JOIN site s ON sc.site_id = s.id
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

__PACKAGE__->meta->make_immutable;
1;

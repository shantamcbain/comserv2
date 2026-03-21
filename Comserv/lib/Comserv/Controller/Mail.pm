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
    
    # Get statistics for admin users
    if ($c->check_user_roles('admin') || $c->check_user_roles('developer')) {
        my $site_id = $c->session->{site_id} || 1;
        
        try {
            my $schema = $c->model('DBEncy');
            
            # Get user count for current site
            my $user_count = $schema->resultset('User')->search({
                'user_sites.site_id' => $site_id
            }, {
                join => 'user_sites'
            })->count;
            
            # Get mailing list count
            my $mailing_list_count = $schema->resultset('MailingList')->search({
                site_id => $site_id
            })->count;
            
            $c->stash(
                user_count => $user_count,
                mailing_list_count => $mailing_list_count
            );
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', 
                "Error loading mail statistics: $_");
        };
    }
    
    # Set the template to the new mail dashboard
    $c->stash(template => 'mail/index.tt');
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
    
    $c->stash(template => 'mail/add_mail_config_form.tt');
}

sub add_mail_config :Local {
    my ($self, $c) = @_;
    
    my $params = $c->req->params;
    my $site_id = $params->{site_id};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config', 
        "Processing mail configuration for site_id $site_id");
    
    # Validate required fields
    unless ($params->{smtp_host} && $params->{smtp_port}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_mail_config', 
            "Incomplete SMTP config for site_id $site_id");
        $c->stash->{debug_msg} = "Please provide SMTP host and port";
        $c->stash(template => 'mail/add_mail_config_form.tt');
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy');
        my $site_config_rs = $schema->resultset('SiteConfig');
        
        # Create or update SMTP configuration
        for my $config_key (qw(smtp_host smtp_port smtp_username smtp_password smtp_from smtp_ssl)) {
            next unless defined $params->{$config_key};
            
            $site_config_rs->update_or_create({
                site_id => $site_id,
                config_key => $config_key,
                config_value => $params->{$config_key},
            });
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_mail_config', 
            "SMTP config saved for site_id $site_id");
        $c->stash->{status_msg} = "SMTP configuration saved successfully";
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_mail_config', 
            "Failed to save SMTP config: $_");
        $c->stash->{debug_msg} = "Failed to save configuration: $_";
    };
    
    $c->res->redirect($c->uri_for($self->action_for('add_mail_config_form')));
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

# Mass Email Functionality
sub mass_email_form :Path('mass_email') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin permissions
    unless ($c->check_user_roles('admin') || $c->check_user_roles('developer')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'mass_email_form', 
            "Unauthorized access attempt by user: " . ($c->user->username || 'unknown'));
        $c->stash->{error_msg} = "Access denied. Admin privileges required.";
        $c->res->redirect($c->uri_for('/'));
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'mass_email_form', 
        "Accessing mass email form");
    
    my $site_id = $c->session->{site_id} || 1;
    
    try {
        my $schema = $c->model('DBEncy');
        
        # Get user count for current site
        my $user_count = $schema->resultset('User')->search({
            'user_sites.site_id' => $site_id
        }, {
            join => 'user_sites'
        })->count;
        
        # Get available mailing lists for tracking
        my @mailing_lists = $schema->resultset('MailingList')->search(
            { site_id => $site_id, is_active => 1 },
            { order_by => 'name' }
        )->all;
        
        $c->stash(
            user_count => $user_count,
            mailing_lists => \@mailing_lists,
            template => 'mail/mass_email_form.tt'
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'mass_email_form', 
            "Error loading mass email form: $_");
        $c->stash->{debug_msg} = "Error loading form: $_";
    };
}

sub send_mass_email :Path('send_mass_email') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin permissions
    unless ($c->check_user_roles('admin') || $c->check_user_roles('developer')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_mass_email', 
            "Unauthorized mass email attempt by user: " . ($c->user->username || 'unknown'));
        $c->stash->{error_msg} = "Access denied. Admin privileges required.";
        $c->res->redirect($c->uri_for('/'));
        return;
    }
    
    if ($c->req->method eq 'POST') {
        my $params = $c->req->params;
        my $site_id = $c->session->{site_id} || 1;
        my $user_id = $c->session->{user_id} || 1;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_mass_email', 
            "Processing mass email request for site_id $site_id");
        
        # Validate required fields
        unless ($params->{subject} && $params->{body}) {
            $c->stash->{error_msg} = "Subject and message body are required";
            $c->res->redirect($c->uri_for($self->action_for('mass_email_form')));
            return;
        }
        
        try {
            my $schema = $c->model('DBEncy');
            
            # Get all users for the current site
            my @users = $schema->resultset('User')->search({
                'user_sites.site_id' => $site_id,
                'email' => { '!=' => undef },
                'email' => { '!=' => '' }
            }, {
                join => 'user_sites',
                columns => [qw/id email first_name last_name/]
            })->all;
            
            unless (@users) {
                $c->stash->{error_msg} = "No users found with email addresses for this site";
                $c->res->redirect($c->uri_for($self->action_for('mass_email_form')));
                return;
            }
            
            # Parse BCC addresses
            my @bcc_addresses;
            if ($params->{bcc_addresses}) {
                @bcc_addresses = split(/[,;\s]+/, $params->{bcc_addresses});
                @bcc_addresses = grep { $_ && $_ =~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/ } @bcc_addresses;
            }
            
            # Create campaign record for tracking (if table exists)
            my $campaign;
            eval {
                $campaign = $schema->resultset('MailingListCampaign')->create({
                    site_id => $site_id,
                    name => "Mass Email: " . $params->{subject},
                    subject => $params->{subject},
                    body => $params->{body},
                    created_by => $user_id,
                    sent_at => \'NOW()',
                    recipient_count => scalar(@users) + scalar(@bcc_addresses),
                    status => 'sending'
                });
            };
            
            my $success_count = 0;
            my $error_count = 0;
            my @errors;
            
            # Send to all users
            foreach my $user (@users) {
                my $personalized_body = $params->{body};
                $personalized_body =~ s/\[FIRST_NAME\]/$user->first_name || 'User'/g;
                $personalized_body =~ s/\[LAST_NAME\]/$user->last_name || ''/g;
                $personalized_body =~ s/\[EMAIL\]/$user->email/g;
                
                if ($c->model('Mail')->send_email($c, $user->email, $params->{subject}, $personalized_body, $site_id)) {
                    $success_count++;
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_mass_email', 
                        "Email sent successfully to " . $user->email);
                } else {
                    $error_count++;
                    push @errors, "Failed to send to " . $user->email;
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_mass_email', 
                        "Failed to send email to " . $user->email);
                }
            }
            
            # Send to BCC addresses
            foreach my $bcc_email (@bcc_addresses) {
                if ($c->model('Mail')->send_email($c, $bcc_email, $params->{subject}, $params->{body}, $site_id)) {
                    $success_count++;
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_mass_email', 
                        "Email sent successfully to BCC: $bcc_email");
                } else {
                    $error_count++;
                    push @errors, "Failed to send to BCC: $bcc_email";
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_mass_email', 
                        "Failed to send email to BCC: $bcc_email");
                }
            }
            
            # Update campaign status
            if ($campaign) {
                $campaign->update({
                    status => $error_count > 0 ? 'completed_with_errors' : 'completed',
                    success_count => $success_count,
                    error_count => $error_count
                });
            }
            
            # Set status messages
            if ($success_count > 0) {
                $c->stash->{status_msg} = "Mass email sent successfully to $success_count recipients";
            }
            if ($error_count > 0) {
                $c->stash->{error_msg} = "Failed to send to $error_count recipients";
                if ($c->session->{debug_mode}) {
                    $c->stash->{debug_msg} = \@errors;
                }
            }
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_mass_email', 
                "Mass email completed: $success_count successful, $error_count failed");
            
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_mass_email', 
                "Error processing mass email: $_");
            $c->stash->{error_msg} = "Error sending mass email: $_";
        };
    }
    
    $c->res->redirect($c->uri_for($self->action_for('mass_email_form')));
}

# Mailing List Management Actions

sub mailing_lists :Path('lists') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin permissions
    unless ($c->check_user_roles('admin') || $c->check_user_roles('developer')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'mailing_lists', 
            "Unauthorized access attempt by user: " . ($c->user->username || 'unknown'));
        $c->stash->{error_msg} = "Access denied. Admin privileges required.";
        $c->res->redirect($c->uri_for('/mail'));
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'mailing_lists', 
        "Accessing mailing lists management");
    
    # Get site_id from session or default
    my $site_id = $c->session->{site_id} || 1;
    
    try {
        my $schema = $c->model('DBEncy');
        my @lists = $schema->resultset('MailingList')->search(
            { site_id => $site_id },
            { order_by => 'name' }
        )->all;
        
        $c->stash(
            mailing_lists => \@lists,
            template => 'mail/mailing_lists.tt'
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'mailing_lists', 
            "Error fetching mailing lists: $_");
        $c->stash->{debug_msg} = "Error loading mailing lists: $_";
    };
}

sub create_list :Path('lists/create') :Args(0) {
    my ($self, $c) = @_;
    
    if ($c->req->method eq 'POST') {
        my $params = $c->req->params;
        my $site_id = $c->session->{site_id} || 1;
        my $user_id = $c->session->{user_id} || 1;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_list', 
            "Creating mailing list: " . $params->{name});
        
        try {
            my $schema = $c->model('DBEncy');
            my $new_list = $schema->resultset('MailingList')->create({
                site_id => $site_id,
                name => $params->{name},
                description => $params->{description},
                list_email => $params->{list_email},
                is_software_only => $params->{is_software_only} || 1,
                is_active => 1,
                created_by => $user_id,
            });
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_list', 
                "Mailing list created successfully: " . $new_list->id);
            $c->stash->{status_msg} = "Mailing list created successfully";
            
            $c->res->redirect($c->uri_for($self->action_for('mailing_lists')));
            return;
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_list', 
                "Error creating mailing list: $_");
            $c->stash->{debug_msg} = "Error creating mailing list: $_";
        };
    }
    
    $c->stash(template => 'mail/create_list.tt');
}



sub get_available_lists :Private {
    my ($self, $c, $site_id) = @_;
    
    try {
        my $schema = $c->model('DBEncy');
        my @lists = $schema->resultset('MailingList')->search(
            { 
                site_id => $site_id,
                is_active => 1 
            },
            { order_by => 'name' }
        )->all;
        
        return \@lists;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_available_lists', 
            "Error fetching available lists: $_");
        return [];
    };
}

# Enhanced Newsletter Signup with Duplicate Prevention
sub newsletter_signup :Local {
    my ($self, $c) = @_;
    
    if ($c->req->method eq 'POST') {
        my $email = $c->req->params->{email};
        my $site_id = $c->session->{site_id} || 1;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'newsletter_signup', 
            "Newsletter signup attempt for email: $email");
        
        # Validate email format
        unless ($email && $email =~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/) {
            $c->stash->{error_msg} = "Please enter a valid email address";
            $c->res->redirect($c->req->referer || '/');
            return;
        }
        
        try {
            my $schema = $c->model('DBEncy');
            
            # Find or create newsletter list
            my $newsletter_list = $schema->resultset('MailingList')->find_or_create({
                site_id => $site_id,
                name => 'Newsletter',
                description => 'Site newsletter subscription',
                is_software_only => 1,
                is_active => 1,
                created_by => 1, # System created
            });
            
            # Check if user exists
            my $user = $schema->resultset('User')->find({ email => $email });
            
            if ($user) {
                # Check for existing subscription
                my $existing_subscription = $schema->resultset('MailingListSubscription')->find({
                    mailing_list_id => $newsletter_list->id,
                    user_id => $user->id,
                });
                
                if ($existing_subscription) {
                    if ($existing_subscription->is_active) {
                        $c->stash->{status_msg} = "You are already subscribed to our newsletter!";
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'newsletter_signup', 
                            "Duplicate subscription attempt for existing active user: $email");
                    } else {
                        # Reactivate inactive subscription
                        $existing_subscription->update({ is_active => 1 });
                        $c->stash->{status_msg} = "Welcome back! Your newsletter subscription has been reactivated.";
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'newsletter_signup', 
                            "Reactivated subscription for user: $email");
                    }
                } else {
                    # Create new subscription for existing user
                    $schema->resultset('MailingListSubscription')->create({
                        mailing_list_id => $newsletter_list->id,
                        user_id => $user->id,
                        subscription_source => 'manual',
                        is_active => 1,
                    });
                    $c->stash->{status_msg} = "You have been subscribed to our newsletter!";
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'newsletter_signup', 
                        "New subscription created for existing user: $email");
                }
            } else {
                # Check if email is already stored for future registration
                if ($c->session->{newsletter_email} && $c->session->{newsletter_email} eq $email) {
                    $c->stash->{status_msg} = "We already have your email! Please register to complete your newsletter subscription.";
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'newsletter_signup', 
                        "Duplicate email storage attempt: $email");
                } else {
                    # Store email for future user creation
                    $c->session->{newsletter_email} = $email;
                    $c->stash->{status_msg} = "Thank you! Please register to complete your newsletter subscription.";
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'newsletter_signup', 
                        "Email stored for future registration: $email");
                }
            }
            
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'newsletter_signup', 
                "Error processing newsletter signup: $_");
            $c->stash->{error_msg} = "Error processing signup. Please try again.";
        };
    }
    
    $c->res->redirect($c->req->referer || '/');
}



sub init_default_lists :Path('init_defaults') :Args(0) {
    my ($self, $c) = @_;
    
    # Only allow admin users to initialize defaults
    unless ($c->session->{roles} && grep { $_ eq 'admin' || $_ eq 'developer' } @{$c->session->{roles}}) {
        $c->response->status(403);
        $c->response->body('Access denied');
        return;
    }
    
    my $site_id = $c->session->{site_id} || 1;
    my $user_id = $c->session->{user_id} || 1;
    
    eval {
        my $schema = $c->model('DBEncy');
        
        # Check if lists already exist
        my $existing_count = $schema->resultset('MailingList')->search({
            site_id => $site_id
        })->count;
        
        if ($existing_count == 0) {
            # Create default mailing lists
            my @default_lists = (
                {
                    name => 'Newsletter',
                    description => 'General newsletter with updates and announcements',
                    is_software_only => 1,
                },
                {
                    name => 'Workshop Notifications',
                    description => 'Notifications about upcoming workshops and events',
                    is_software_only => 1,
                },
                {
                    name => 'System Updates',
                    description => 'Important system updates and maintenance notifications',
                    is_software_only => 1,
                }
            );
            
            foreach my $list_data (@default_lists) {
                $schema->resultset('MailingList')->create({
                    site_id => $site_id,
                    name => $list_data->{name},
                    description => $list_data->{description},
                    is_software_only => $list_data->{is_software_only},
                    is_active => 1,
                    created_by => $user_id,
                });
            }
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'init_default_lists',
                "Created " . scalar(@default_lists) . " default mailing lists for site $site_id");
            
            $c->response->body("Created " . scalar(@default_lists) . " default mailing lists");
        } else {
            $c->response->body("Mailing lists already exist ($existing_count found)");
        }
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'init_default_lists',
            "Error creating default mailing lists: $@");
        $c->response->status(500);
        $c->response->body("Error: $@");
    }
}

__PACKAGE__->meta->make_immutable;
1;

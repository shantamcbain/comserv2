package Comserv::Controller::HelpDesk;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use JSON;
use POSIX qw(strftime);
use Try::Tiny;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace for this controller
__PACKAGE__->config(namespace => 'HelpDesk');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

=head1 NAME

Comserv::Controller::HelpDesk - HelpDesk Controller for Comserv

=head1 DESCRIPTION

Controller for the HelpDesk functionality using the chained dispatch system.

=head1 METHODS

=cut

=head2 auto

Common setup for all HelpDesk actions

=cut

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
        "HelpDesk controller auto method called");
    
    # Initialize debug_msg array if it doesn't exist
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Add the debug message to the array
    push @{$c->stash->{debug_msg}}, "HelpDesk controller loaded successfully";
    
    return 1; # Allow the request to proceed
}

=head2 base

Base method for chained actions

=cut

sub base :Chained('/') :PathPart('HelpDesk') :CaptureArgs(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Starting HelpDesk base action");
    
    # Common setup for all HelpDesk pages
    $c->stash(section => 'helpdesk');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Completed HelpDesk base action");
}

=head2 index

Main HelpDesk page - endpoint of the chain

=cut

sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Starting HelpDesk index action");
    
    # Set the template
    $c->stash(template => 'CSC/HelpDesk.tt');
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "HelpDesk index action executed";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Completed HelpDesk index action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 ticket_base

Base for all ticket-related actions

=cut

sub ticket_base :Chained('base') :PathPart('ticket') :CaptureArgs(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_base', 
        "Starting ticket_base action");
    
    # Common setup for all ticket pages
    $c->stash(subsection => 'ticket');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_base', 
        "Completed ticket_base action");
}

=head2 ticket_new

Create new ticket page

=cut

sub ticket_new :Chained('ticket_base') :PathPart('new') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_new', 
        "Starting ticket_new action");
    
    $c->stash(
        template => 'CSC/HelpDesk/new_ticket.tt',
        title => 'Create New Support Ticket'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "New ticket form loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_new', 
        "Completed ticket_new action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 ticket_status

View ticket status page

=cut

sub ticket_status :Chained('ticket_base') :PathPart('status') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_status', 
        "Starting ticket_status action");
    
    $c->stash(
        template => 'CSC/HelpDesk/ticket_status.tt',
        title => 'View Ticket Status'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Ticket status page loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_status', 
        "Completed ticket_status action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 kb

Knowledge Base page

=cut

sub kb :Chained('base') :PathPart('kb') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'kb', 
        "Starting kb action");
    
    $c->stash(
        template => 'CSC/HelpDesk/kb.tt',
        title => 'Knowledge Base'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Knowledge Base loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'kb', 
        "Completed kb action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 linux_commands

Linux Commands Reference page

=cut

sub linux_commands :Chained('base') :PathPart('kb/linux_commands') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'linux_commands', 
        "Starting linux_commands action");
    
    # Include CSS and JavaScript enhancements
    $c->stash(
        template => 'CSC/HelpDesk/linux_commands.tt',
        title => 'Linux Commands Reference',
        additional_css => ['/static/css/linux_commands.css'],
        additional_js => ['/static/js/linux_commands.js']
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Linux Commands Reference loaded with enhancements";
    push @{$c->stash->{success_msg}}, "Command reference enhanced with copy-to-clipboard functionality";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'linux_commands', 
        "Completed linux_commands action with CSS and JS enhancements");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 contact

Contact Support page

=cut

sub contact :Chained('base') :PathPart('contact') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'contact', 
        "Starting contact action");
    
    $c->stash(
        template => 'CSC/HelpDesk/contact.tt',
        title => 'Contact Support'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Contact Support page loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'contact', 
        "Completed contact action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 admin

Admin page for HelpDesk management

=cut

sub admin :Chained('base') :PathPart('admin') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin', 
        "Starting admin action");
    
    # Check if user has admin role
    my $has_admin_role = 0;
    if ($c->session->{roles}) {
        my $roles = $c->session->{roles};
        if (ref($roles) eq 'ARRAY') {
            $has_admin_role = grep { $_ eq 'admin' } @$roles;
        } elsif (!ref($roles)) {
            $has_admin_role = $roles =~ /\badmin\b/i;
        }
    }
    
    unless ($has_admin_role) {
        my $root_controller = $c->controller('Root');
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin', 
            "Unauthorized access attempt to HelpDesk admin by user: " . ($root_controller->user_exists($c) ? ($c->session->{username} || 'Guest') : 'Guest'));
        
        # Redirect to main HelpDesk page with error message
        $c->stash->{error_msg} = "You don't have permission to access the HelpDesk admin area.";
        $c->detach('index');
        return;
    }
    
    $c->stash(
        template => 'CSC/HelpDesk/admin.tt',
        title => 'HelpDesk Administration'
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "HelpDesk admin page loaded";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin', 
        "Completed admin action");
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

=head2 submit_ticket

Process ticket form submission and save to database

=cut

sub submit_ticket :Chained('ticket_base') :PathPart('submit') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'submit_ticket',
        "Processing ticket submission");

    my $subject     = $c->req->params->{subject}     || '';
    my $description = $c->req->params->{description} || '';
    my $category    = $c->req->params->{category}    || 'other';
    my $priority    = $c->req->params->{priority}    || 'medium';
    my $email       = $c->req->params->{email}       || $c->session->{email} || '';

    unless ($subject && $description) {
        $c->stash(
            template  => 'CSC/HelpDesk/new_ticket.tt',
            error_msg => 'Subject and description are required.',
            title     => 'Create New Support Ticket',
        );
        $c->forward($c->view('TT'));
        return;
    }

    my $user_id   = $c->session->{user_id} || undef;
    my $username  = $c->session->{username} || 'guest';
    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';

    my $ticket_number = uc($site_name) . '-' . strftime('%Y%m%d', localtime) . '-' . sprintf('%04d', int(rand(9999)) + 1);

    try {
        my $schema = $c->model('DBEncy')->schema;
        my $ticket = $schema->resultset('SupportTicket')->create({
            ticket_number => $ticket_number,
            site_name     => $site_name,
            user_id       => $user_id,
            username      => $username,
            email         => $email,
            subject       => $subject,
            description   => $description,
            category      => $category,
            priority      => $priority,
            status        => 'open',
            created_at    => strftime('%Y-%m-%d %H:%M:%S', localtime),
        });

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'submit_ticket',
            "Ticket created: " . $ticket->ticket_number . " (id=" . $ticket->id . ")");

        $c->stash(
            template      => 'CSC/HelpDesk/ticket_submitted.tt',
            ticket        => $ticket,
            ticket_number => $ticket->ticket_number,
            title         => 'Ticket Submitted',
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'submit_ticket',
            "Error creating ticket: $_");
        $c->stash(
            template  => 'CSC/HelpDesk/new_ticket.tt',
            error_msg => 'There was an error submitting your ticket. Please try again.',
            title     => 'Create New Support Ticket',
        );
    };

    $c->forward($c->view('TT'));
}

=head2 view_ticket

View a single ticket by its ticket_number

=cut

sub view_ticket :Chained('ticket_base') :PathPart('view') :Args(1) {
    my ($self, $c, $ticket_number) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_ticket',
        "Viewing ticket: $ticket_number");

    try {
        my $schema = $c->model('DBEncy')->schema;
        my $ticket = $schema->resultset('SupportTicket')->find({ ticket_number => $ticket_number });

        unless ($ticket) {
            $c->stash(
                template  => 'CSC/HelpDesk/ticket_status.tt',
                error_msg => "Ticket '$ticket_number' not found.",
                tickets   => [],
            );
            $c->forward($c->view('TT'));
            return;
        }

        my $user_id  = $c->session->{user_id} || 0;
        my $is_admin = 0;
        if ($c->session->{roles}) {
            my $roles = $c->session->{roles};
            $is_admin = ref($roles) eq 'ARRAY' ? grep { $_ eq 'admin' } @$roles
                                                 : ($roles =~ /\badmin\b/i ? 1 : 0);
        }

        unless ($is_admin || ($ticket->user_id && $ticket->user_id == $user_id)) {
            $c->stash(
                template  => 'CSC/HelpDesk/ticket_status.tt',
                error_msg => 'You do not have permission to view this ticket.',
                tickets   => [],
            );
            $c->forward($c->view('TT'));
            return;
        }

        $c->stash(
            template => 'CSC/HelpDesk/ticket_status.tt',
            ticket   => $ticket,
            tickets  => [$ticket],
            title    => 'Ticket: ' . $ticket_number,
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_ticket',
            "Error viewing ticket: $_");
        $c->stash(
            template  => 'CSC/HelpDesk/ticket_status.tt',
            error_msg => 'Error retrieving ticket.',
            tickets   => [],
        );
    };

    $c->forward($c->view('TT'));
}

=head2 ticket_list

Show the authenticated user's tickets (or all tickets for admin)

=cut

sub ticket_list :Chained('ticket_base') :PathPart('list') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ticket_list',
        "Loading ticket list");

    my $user_id   = $c->session->{user_id} || 0;
    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
    my $is_admin  = 0;
    if ($c->session->{roles}) {
        my $roles = $c->session->{roles};
        $is_admin = ref($roles) eq 'ARRAY' ? grep { $_ eq 'admin' } @$roles
                                             : ($roles =~ /\badmin\b/i ? 1 : 0);
    }

    try {
        my $schema = $c->model('DBEncy')->schema;
        my %search = $is_admin
            ? ( site_name => $site_name )
            : ( user_id   => $user_id, site_name => $site_name );

        my @tickets = $schema->resultset('SupportTicket')->search(
            \%search,
            { order_by => { -desc => 'created_at' }, rows => 50 }
        )->all;

        $c->stash(
            template => 'CSC/HelpDesk/ticket_status.tt',
            tickets  => \@tickets,
            title    => 'My Support Tickets',
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'ticket_list',
            "Error loading tickets: $_");
        $c->stash(
            template  => 'CSC/HelpDesk/ticket_status.tt',
            tickets   => [],
            error_msg => 'Error loading tickets.',
        );
    };

    $c->forward($c->view('TT'));
}

=head2 register_project

Admin-only: Register the HelpDesk improvement project in the ProjectPlanning system.
Idempotent - skips creation if a project named 'HelpDesk Multi-Site Support System' already exists.
Access: GET /HelpDesk/admin/register_project

=cut

sub register_project :Chained('base') :PathPart('admin/register_project') :Args(0) {
    my ($self, $c) = @_;

    my $is_admin = 0;
    if ($c->session->{roles}) {
        my $roles = $c->session->{roles};
        $is_admin = ref($roles) eq 'ARRAY' ? grep { $_ eq 'admin' } @$roles
                                             : ($roles =~ /\badmin\b/i ? 1 : 0);
    }

    unless ($is_admin) {
        $c->stash(error_msg => 'Admin access required.', template => 'CSC/HelpDesk.tt');
        $c->forward($c->view('TT'));
        return;
    }

    my $result_msg;
    try {
        my $schema    = $c->model('DBEncy')->schema;
        my $proj_rs   = $schema->resultset('Project');
        my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
        my $username  = $c->session->{username} || 'admin';

        my $existing = $proj_rs->search({ name => 'HelpDesk Multi-Site Support System' })->first;
        if ($existing) {
            $result_msg = "Project already exists (id=" . $existing->id . "). No changes made.";
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'register_project',
                $result_msg);
        } else {
            my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
            my $parent = $proj_rs->create({
                name                => 'HelpDesk Multi-Site Support System',
                description         => 'Improve the HelpDesk system to be fully functional, multi-site aware, and tightly integrated with the AI chat widget. The system should allow any SiteName to use HelpDesk for support, with AI assisting users by referencing KB articles, creating support tickets, and escalating to live agents.',
                start_date          => strftime('%Y-%m-%d', localtime),
                status              => '2',
                project_code        => 'HELPDESK-MULTISITE',
                developer_name      => $username,
                client_name         => $site_name,
                sitename            => $site_name,
                username_of_poster  => $username,
                group_of_poster     => 'admin',
                date_time_posted    => $now,
                record_id           => 0,
            });

            my @sub_projects = (
                {
                    code => 'HELPDESK-SCHEMA',
                    name => 'SupportTicket Database Schema',
                    desc => 'Create support_tickets table and Perl schema result class for tracking tickets.',
                },
                {
                    code => 'HELPDESK-MULTISITE',
                    name => 'Multi-Site HelpDesk Templates',
                    desc => 'Update HelpDesk.tt and related templates to use SiteName for site-aware branding.',
                },
                {
                    code => 'HELPDESK-TICKETS',
                    name => 'Ticket Submission and Tracking',
                    desc => 'Add submit_ticket, view_ticket, ticket_list controller actions backed by the DB.',
                },
                {
                    code => 'HELPDESK-AI',
                    name => 'AI Chat HelpDesk Integration',
                    desc => 'When agent_type=helpdesk, inject a HelpDesk system prompt that enables KB lookup, ticket creation guidance, and live agent escalation.',
                },
            );

            for my $sp (@sub_projects) {
                $proj_rs->create({
                    name               => $sp->{name},
                    description        => $sp->{desc},
                    start_date         => strftime('%Y-%m-%d', localtime),
                    status             => '2',
                    project_code       => $sp->{code},
                    developer_name     => $username,
                    client_name        => $site_name,
                    sitename           => $site_name,
                    username_of_poster => $username,
                    group_of_poster    => 'admin',
                    date_time_posted   => $now,
                    parent_id          => $parent->id,
                    record_id          => 0,
                });
            }

            $result_msg = "Project created successfully (id=" . $parent->id . ") with " . scalar(@sub_projects) . " sub-projects.";
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'register_project',
                $result_msg);
        }
    } catch {
        $result_msg = "Error registering project: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'register_project',
            $result_msg);
    };

    $c->stash(
        template    => 'CSC/HelpDesk/admin.tt',
        title       => 'HelpDesk Administration',
        success_msg => $result_msg,
    );
    push @{$c->stash->{debug_msg}}, $result_msg;
    $c->forward($c->view('TT'));
}

=head2 default

Fallback for HelpDesk URLs that don't match any actions

=cut

sub default :Chained('base') :PathPart('') :Args {
    my ($self, $c) = @_;
    
    my $path = join('/', @{$c->req->args});
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'default', 
        "Invalid HelpDesk path: $path");
    
    # Forward to the index action
    $c->stash(
        template => 'CSC/HelpDesk.tt',
        error_msg => "The requested HelpDesk page was not found: $path"
    );
    
    # Push debug message to stash
    push @{$c->stash->{debug_msg}}, "Invalid HelpDesk path: $path, forwarded to index";
    
    # Explicitly forward to the TT view
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;
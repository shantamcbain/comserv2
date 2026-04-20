package Comserv::Controller::HelpDesk;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
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
    
    $c->stash(
        section       => 'helpdesk',
        site_favicon  => '/favicon/helpdesk',
    );
    
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

sub _is_staff {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles};
    return 0 unless $roles;
    return ref($roles) eq 'ARRAY'
        ? (grep { $_ eq 'admin' || $_ eq 'helpdesk' } @$roles) ? 1 : 0
        : ($roles =~ /\b(?:admin|helpdesk)\b/i ? 1 : 0);
}

sub _require_admin {
    my ($self, $c) = @_;
    my $is_staff = $self->_is_staff($c);
    unless ($is_staff) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_require_admin',
            "Unauthorized HelpDesk admin access by: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "You don't have permission to access the HelpDesk admin area.";
        $c->detach('index');
    }
    return $is_staff;
}

sub admin :Chained('base') :PathPart('admin') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin', "Starting admin action");
    $self->_require_admin($c);
    $c->stash(
        template => 'CSC/HelpDesk/admin.tt',
        title    => 'HelpDesk Administration',
    );
    push @{$c->stash->{debug_msg}}, "HelpDesk admin page loaded";
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin', "Completed admin action");
    $c->forward($c->view('TT'));
}

sub admin_tickets :Chained('base') :PathPart('admin/tickets') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_admin($c);
    $self->_load_admin_tickets($c, undef, 'All Tickets');
}

sub admin_tickets_open :Chained('base') :PathPart('admin/tickets/open') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_admin($c);
    $self->_load_admin_tickets($c, 'open', 'Open Tickets');
}

sub admin_tickets_closed :Chained('base') :PathPart('admin/tickets/closed') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_admin($c);
    $self->_load_admin_tickets($c, 'closed', 'Closed Tickets');
}

sub admin_tickets_resolved :Chained('base') :PathPart('admin/tickets/resolved') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_admin($c);
    $self->_load_admin_tickets($c, 'resolved', 'Resolved Tickets');
}

sub _load_admin_tickets {
    my ($self, $c, $status_filter, $title) = @_;

    my $site_name  = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
    my $is_csc     = (lc($site_name) eq 'csc');

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_load_admin_tickets',
        "Loading admin tickets: filter=" . ($status_filter || 'all')
        . " site=$site_name csc_admin=" . ($is_csc ? 'yes' : 'no'));

    try {
        my $schema = $c->model('DBEncy')->schema;
        my %search;
        $search{site_name} = $site_name unless $is_csc;
        $search{status}    = $status_filter if $status_filter;

        my @tickets = $schema->resultset('SupportTicket')->search(
            \%search,
            { order_by => { -desc => 'created_at' }, rows => 100 }
        )->all;

        $c->stash(
            template      => 'CSC/HelpDesk/admin_tickets.tt',
            tickets       => \@tickets,
            title         => $title,
            is_admin_view => 1,
            status_filter => $status_filter || 'all',
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_load_admin_tickets',
            "Error loading admin tickets: $_");
        $c->stash(
            template  => 'CSC/HelpDesk/admin_tickets.tt',
            tickets   => [],
            title     => $title,
            error_msg => 'Error loading tickets.',
        );
    };

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
        my $is_admin = $self->_is_staff($c);

        unless ($is_admin || ($ticket->user_id && $ticket->user_id == $user_id)) {
            $c->stash(
                template  => 'CSC/HelpDesk/ticket_status.tt',
                error_msg => 'You do not have permission to view this ticket.',
                tickets   => [],
            );
            $c->forward($c->view('TT'));
            return;
        }

        my @messages = eval { $ticket->messages->all } // ();

        $c->stash(
            template  => 'CSC/HelpDesk/ticket_view.tt',
            ticket    => $ticket,
            messages  => \@messages,
            is_staff  => $is_admin,
            title     => 'Ticket: ' . $ticket_number,
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

=head2 ticket_reply

Add a reply message to a ticket and email the other party

=cut

sub ticket_reply :Chained('ticket_base') :PathPart('reply') :Args(1) {
    my ($self, $c, $ticket_number) = @_;

    unless ($c->req->method eq 'POST') {
        $c->res->redirect($c->uri_for('/HelpDesk/ticket/view/' . $ticket_number));
        return;
    }

    my $body_text = $c->req->params->{reply_body} || '';
    unless ($body_text) {
        $c->res->redirect($c->uri_for('/HelpDesk/ticket/view/' . $ticket_number));
        return;
    }

    my $is_staff     = $self->_is_staff($c);
    my $sender_name  = ($c->session->{firstname} || '') . ' ' . ($c->session->{lastname} || '');
    $sender_name     = $c->session->{username} || 'Anonymous' unless $sender_name =~ /\S/;
    my $sender_email = $c->session->{email} || '';
    my $sender_type  = $is_staff ? 'staff' : 'user';
    my $site_name    = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';

    try {
        my $schema = $c->model('DBEncy')->schema;
        my $ticket = $schema->resultset('SupportTicket')->find({ ticket_number => $ticket_number });

        unless ($ticket) {
            $c->stash(error_msg => "Ticket not found.", template => 'CSC/HelpDesk/ticket_status.tt', tickets => []);
            $c->forward($c->view('TT'));
            return;
        }

        my $user_id = $c->session->{user_id} || 0;
        unless ($is_staff || ($ticket->user_id && $ticket->user_id == $user_id)) {
            $c->stash(error_msg => 'Permission denied.', template => 'CSC/HelpDesk/ticket_status.tt', tickets => []);
            $c->forward($c->view('TT'));
            return;
        }

        $schema->resultset('TicketMessage')->create({
            ticket_id    => $ticket->id,
            sender_type  => $sender_type,
            sender_name  => $sender_name,
            sender_email => $sender_email,
            body         => $body_text,
        });

        if ($sender_type eq 'staff' && $ticket->email) {
            my $subject = "Re: [Ticket " . $ticket->ticket_number . "] " . $ticket->subject;
            my $body    = "Hello,\n\n"
                . "A staff member has replied to your support ticket.\n\n"
                . "--- Reply from $sender_name ---\n$body_text\n\n"
                . "View your ticket: " . $c->uri_for('/HelpDesk/ticket/view/' . $ticket_number) . "\n\n"
                . "Regards,\n$site_name Support Team";
            eval { $c->model('Mail')->send_email($c, $ticket->email, $subject, $body) };
            $self->logging->log_with_details($c, $@ ? 'error' : 'info', __FILE__, __LINE__, 'ticket_reply',
                $@ ? "Email to submitter failed: $@" : "Reply email sent to " . $ticket->email);
        } elsif ($sender_type eq 'user') {
            my $from_email = $c->model('Mail')->can('get_smtp_config')
                ? eval { $c->model('Mail')->get_smtp_config($c, undef)->{from} } || ''
                : '';
            my $staff_subject = "[HelpDesk] Customer reply on Ticket " . $ticket->ticket_number;
            my $staff_body    = "A customer has replied to ticket " . $ticket->ticket_number . ".\n\n"
                . "Subject: " . $ticket->subject . "\n"
                . "From: $sender_name ($sender_email)\n\n"
                . "--- Reply ---\n$body_text\n\n"
                . "View ticket: " . $c->uri_for('/HelpDesk/admin/tickets/open') . "\n\n"
                . "Regards,\n$site_name HelpDesk";
            if ($from_email) {
                eval { $c->model('Mail')->send_email($c, $from_email, $staff_subject, $staff_body) };
            }
        }

    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'ticket_reply',
            "Error posting reply: $_");
    };

    $c->res->redirect($c->uri_for('/HelpDesk/ticket/view/' . $ticket_number));
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
    my $is_admin  = $self->_is_staff($c);

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

=head2 default

Fallback for HelpDesk URLs that don't match any actions

=cut

sub tickets_alert :Chained('base') :PathPart('admin/tickets_alert') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    unless ($self->_is_staff($c)) {
        $c->response->body('{"open_count":0}');
        return;
    }
    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
    my $is_csc    = (lc($site_name) eq 'csc');
    my $count = 0;
    eval {
        my $schema = $c->model('DBEncy')->schema;
        my %search = (status => 'open');
        $search{site_name} = $site_name unless $is_csc;
        $count = $schema->resultset('SupportTicket')->search(\%search)->count;
    };
    $c->response->headers->header('Cache-Control' => 'no-store');
    $c->response->body('{"open_count":' . ($count + 0) . '}');
}

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
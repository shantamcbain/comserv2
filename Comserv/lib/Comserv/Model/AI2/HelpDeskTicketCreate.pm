package Comserv::Model::AI2::HelpDeskTicketCreate;
# ONE brain for creating HelpDesk support tickets from Chat-with-AI / AI Editor.
# Same intercept pattern as AI2::TodoCreate / InvoiceCreate: natural language is
# handled on the server BEFORE the LLM so free models cannot invent a fake form
# or get diverted into create_todo / "which project".
#
# Callers (must run BEFORE TodoCreate):
#   * Controller::AI2  /ai2/chat short-circuit
#   * Model::AI2::Chat process + chat_contract
#   * AI2::Actions     create_helpdesk_ticket (write path stays there)
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON;
use DateTime;
use Comserv::Util::Logging;
use Comserv::Util::HelpDeskWebhook;
use Comserv::Model::AI2::ChatIntent qw(
    looks_like_todo_create
    looks_like_helpdesk_ticket_create
);

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

sub sitename {
    my ($self, $c) = @_;
    for my $cand (
        $c->stash->{SiteName},
        $c->session->{SiteName},
        $c->session->{site_name},
        $c->stash->{site_name},
    ) {
        next unless defined $cand && $cand =~ /\S/;
        $cand =~ s/^\s+|\s+$//g;
        return $cand if length $cand;
    }
    return 'CSC';
}

sub _is_guest {
    my ($self, $c) = @_;
    my $u = $c->session->{username} || '';
    return 1 if !$u || lc($u) eq 'guest';
    return 0;
}

sub _schema {
    my ($self, $c) = @_;
    return eval { $c->model('DBEncy')->schema };
}

# ---------------------------------------------------------------------------
# Intent: "create a helpdesk ticket …" — do NOT rely on [ACTION:].
# Yield to TodoCreate when the primary ask is clearly create-a-todo.
# ---------------------------------------------------------------------------
sub detect_create_intent {
    my ($self, $prompt) = @_;
    return unless looks_like_helpdesk_ticket_create($prompt);
    # "add a todo to fix helpdesk ticket create" stays with TodoCreate.
    return if looks_like_todo_create($prompt);

    my $p = $prompt;
    $p =~ s/^\s+|\s+$//g;

    my $rest = $p;
    $rest =~ s/^(please\s+)//i;
    $rest =~ s/^(can you|could you|would you|will you)\s+(please\s+)?//i;
    $rest =~ s/^(create|file|open|submit|raise|lodge|report)\s+(me\s+)?(a\s+|an\s+|new\s+|the\s+)*(help\s*desk\s+|helpdesk\s+|support\s+)*tickets?\s*//i;
    $rest =~ s/^(about|regarding|for|titled|titled:|subject:?|:|-)\s*//i;
    $rest =~ s/\s+/ /g;
    $rest =~ s/^\s+|\s+$//g;

    my $subject = $rest;
    $subject = $p if length($subject) < 3;
    # Cap subject; long detail stays in description.
    if (length($subject) > 200) {
        $subject = substr($subject, 0, 197) . '...';
    }

    my $category = 'General';
    if ($p =~ /\b(bug|error|crash|broken|fail(?:ed|ure)?)\b/i) {
        $category = 'Bug';
    }
    elsif ($p =~ /\b(feature|enhancement|request)\b/i) {
        $category = 'Feature Request';
    }

    my $priority = 'normal';
    if ($p =~ /\b(urgent|critical|asap|p\s*1)\b/i) {
        $priority = 'high';
    }

    return {
        subject     => $subject,
        description => $prompt,
        category    => $category,
        priority    => $priority,
    };
}

sub try_chat_create {
    my ($self, $c, %args) = @_;
    my $intent = $self->detect_create_intent($args{prompt} // '') or return;
    if ($self->_is_guest($c)) {
        return {
            handled       => 1,
            success       => 1,
            response      => 'Log in to create a HelpDesk ticket from chat.',
            model         => '(helpdesk-ticket-create)',
            provider      => 'ai2-helpdesk',
            ticket_action => { success => JSON::false, error => 'Login required' },
        };
    }
    $intent->{page_url} = $args{page_path} if $args{page_path};
    my $created = eval { $self->create_from_params($c, $intent) };
    if ($@ || !$created) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'try_chat_create', "create_from_params threw: $@");
        $created = { success => JSON::false, error => 'Ticket create failed' };
    }
    my $msg = $created->{message} || $created->{error} || 'Ticket request processed.';
    $msg .= ' ' . $created->{ticket_url} if $created->{success} && $created->{ticket_url};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'try_chat_create',
        'Chat helpdesk-ticket intent: ' . ($created->{success}
            ? "created $created->{ticket_number}"
            : ($created->{error} || 'no-create')));
    return {
        handled       => 1,
        success       => 1,
        response      => $msg,
        model         => '(helpdesk-ticket-create)',
        provider      => 'ai2-helpdesk',
        ticket_action => $created,
    };
}

sub chat_contract {
    my ($self, $c) = @_;
    return '' if $self->_is_guest($c);
    my $sitename = $self->sitename($c);
    return <<"END";
HELPDESK SUPPORT TICKETS (SiteName=$sitename):
When the user asks to create, file, open, or submit a HelpDesk / support ticket:
1. Extract a SHORT subject (required), optional description (put long detail / conversation context here), optional category (General|Bug|Feature Request), priority (low|normal|high).
2. Emit exactly one ACTION on its own line:
[ACTION: {"action":"create_helpdesk_ticket","params":{"subject":"...","description":"...","category":"General","priority":"normal","page_url":"/current/page"}}]
3. Do NOT emit create_todo / ask which project for a support ticket. Tickets are not project todos.
4. Do not emit create_helpdesk_ticket unless the user asked to create/file/open/submit a ticket.
END
}

sub create_from_params {
    my ($self, $c, $params) = @_;
    $params ||= {};
    my $subject = $params->{subject} // '';
    $subject =~ s/^\s+|\s+$//g;
    unless (length $subject >= 3) {
        return {
            success      => JSON::false,
            need_clarify => JSON::true,
            field        => 'subject',
            draft        => $params,
            message      => 'I can create the HelpDesk ticket, but I need a short subject. What should it be called?',
        };
    }
    if (length $subject > 255) {
        $subject = substr($subject, 0, 252) . '...';
    }

    my $description = $params->{description} || '';
    my $page_url    = $params->{page_url} || '';
    if ($page_url && $description !~ /\Q$page_url\E/) {
        $description = length($description)
            ? "$description\n\nPage: $page_url"
            : "Page: $page_url";
    }

    my $category  = $params->{category}  || 'General';
    my $priority  = $params->{priority}  || 'normal';
    my $email     = $params->{email}     || $c->session->{email} || '';
    my $site_name = $self->sitename($c);
    my $user_id   = $c->session->{user_id} || undef;
    my $username  = $c->session->{username} || 'ai';

    require Comserv::Controller::HelpDesk;
    if (Comserv::Controller::HelpDesk->_looks_like_spam_content($subject, $description)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'create_from_params',
            'AI helpdesk ticket blocked as spam: subject=' . substr($subject, 0, 80));
        return { success => JSON::false, error => 'Your request was blocked by our spam filter.' };
    }

    my $schema = $self->_schema($c)
        or return { success => JSON::false, error => 'Database not available' };

    my $ticket_number = uc($site_name) . '-' . DateTime->now->strftime('%Y%m%d') . '-'
        . sprintf('%04d', int(rand(9999)) + 1);
    my $now_str = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');

    my $new_ticket;
    eval {
        $new_ticket = $schema->resultset('SupportTicket')->create({
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
            created_at    => $now_str,
        });
    };
    if ($@ || !$new_ticket) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'create_from_params', "SupportTicket create failed: $@");
        return { success => JSON::false, error => 'Ticket creation failed' };
    }

    my $ticket_id  = $new_ticket->id // '?';
    my $ticket_num = $new_ticket->ticket_number // $ticket_number;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'create_from_params',
        "AI helpdesk ticket: id=$ticket_id num=$ticket_num sitename=$site_name by=$username subject='$subject'");
    eval {
        Comserv::Util::HelpDeskWebhook->notify_ticket_change($c,
            event  => 'ticket.created',
            change => 'created',
            ticket => $new_ticket,
        );
    };

    return {
        success       => JSON::true,
        message       => "Support ticket $ticket_num created: \"$subject\". An admin will be notified.",
        ticket_id     => $ticket_id + 0,
        ticket_number => $ticket_num,
        ticket_url    => "/HelpDesk/ticket/$ticket_num",
    };
}

__PACKAGE__->meta->make_immutable;
1;

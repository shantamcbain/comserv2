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

# Pull a contact email from the prompt when present (guests need one for follow-up).
sub _extract_email {
    my ($self, $text) = @_;
    return '' unless defined $text && $text =~ /\S/;
    if ($text =~ /\b([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})\b/i) {
        return $1;
    }
    return '';
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

    my $email = $self->_extract_email($prompt);
    return {
        subject     => $subject,
        description => $prompt,
        category    => $category,
        priority    => $priority,
        (length $email ? (email => $email) : ()),
    };
}

sub try_chat_create {
    my ($self, $c, %args) = @_;
    # Reply / status / close first so "close ticket X" never creates a ticket (#2491).
    if (my $upd = $self->try_chat_update($c, %args)) {
        return $upd;
    }
    my $intent = $self->detect_create_intent($args{prompt} // '') or return;
    # Guests may create tickets (public HelpDesk parity). Prefer email from
    # prompt/session; otherwise ask once — never a hard login wall.
    if ($self->_is_guest($c)) {
        my $email = $intent->{email} || $c->session->{email} || '';
        unless ($email =~ /\S+@\S+\.\S+/) {
            return {
                handled       => 1,
                success       => 1,
                response      => 'I can create that HelpDesk ticket as a guest. What email should we use for updates on this ticket?',
                model         => '(helpdesk-ticket-create)',
                provider      => 'ai2-helpdesk',
                ticket_action => {
                    success      => JSON::false,
                    need_clarify => JSON::true,
                    field        => 'email',
                    draft        => $intent,
                    error        => 'Email required for guest ticket',
                },
            };
        }
        $intent->{email} = $email;
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
    my $sitename = $self->sitename($c);
    my $text = <<"END";
HELPDESK SUPPORT TICKETS (SiteName=$sitename):
When the user asks to create, file, open, or submit a HelpDesk / support ticket:
1. Extract a SHORT subject (required), optional description (put long detail / conversation context here), optional category (General|Bug|Feature Request), priority (low|normal|high).
2. Emit exactly one ACTION on its own line:
[ACTION: {"action":"create_helpdesk_ticket","params":{"subject":"...","description":"...","category":"General","priority":"normal","page_url":"/current/page"}}]
3. Do NOT emit create_todo / ask which project for a support ticket. Tickets are not project todos.
4. Do not emit create_helpdesk_ticket unless the user asked to create/file/open/submit a ticket.
END
    return $text if $self->_is_guest($c);
    $text .= <<'END';
To reply to an existing ticket (logged-in ticket owner or HelpDesk staff only):
[ACTION: {"action":"reply_helpdesk_ticket","params":{"ticket_number":"CSC-YYYYMMDD-NNNN","body":"..."}}]
Do not notify the customer from chat.
END
    if ($self->_is_staff($c)) {
        $text .= <<'END';
HelpDesk staff may close or change status (do not notify the customer from chat; #2494):
[ACTION: {"action":"close_helpdesk_ticket","params":{"ticket_number":"CSC-YYYYMMDD-NNNN"}}]
[ACTION: {"action":"set_helpdesk_ticket_status","params":{"ticket_number":"CSC-YYYYMMDD-NNNN","status":"resolved"}}]
Allowed status values: open, resolved, closed.
END
    }
    return $text;
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
    $email = $self->_extract_email($email) if $email;
    my $site_name = $self->sitename($c);
    my $user_id   = $c->session->{user_id} || undef;
    my $username  = $c->session->{username} || '';
    if (!$username || lc($username) eq 'guest') {
        $username = 'guest';
        $user_id  = undef;
        unless ($email =~ /\S+@\S+\.\S+/) {
            return {
                success      => JSON::false,
                need_clarify => JSON::true,
                field        => 'email',
                draft        => $params,
                message      => 'I can create that HelpDesk ticket as a guest. What email should we use for updates on this ticket?',
            };
        }
    }
    $username = 'ai' if !$username;

    # Shared spam guard (CSC-20261012-0420 / todo #2490): same honeypot +
    # session/IP rate limits as the public forms (fail closed, no ticket),
    # then content scoring (spam is quarantined, never deleted).
    require Comserv::Util::SpamGuard;
    $subject = Comserv::Util::SpamGuard->clean_header($subject, 255);
    $email   = Comserv::Util::SpamGuard->clean_header($email, 254) if $email;
    if (my $guard_err = Comserv::Util::SpamGuard->submit_guard_error($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'create_from_params', "AI helpdesk ticket blocked by shared submit guard: $guard_err");
        return { success => JSON::false, error => $guard_err };
    }
    # Guests cannot force high/critical via "urgent" wording (public-form parity).
    if ($username eq 'guest' && $priority =~ /^(high|critical|urgent)$/i) {
        $priority = 'normal';
    }
    my $sg = Comserv::Util::SpamGuard->verdict(subject => $subject, body => $description,
        email => $email, guest => ($username eq 'guest' ? 1 : 0));
    $sg->{quarantine} = 1 if Comserv::Util::SpamGuard->looks_like_spam($subject, $description);
    if ($sg->{quarantine}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'create_from_params',
            "AI helpdesk ticket quarantined score=$sg->{score} (" . join(',', @{ $sg->{reasons} })
            . ') subject=' . substr($subject, 0, 80));
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
            status        => $sg->{quarantine} ? 'quarantine' : 'open',
            created_at    => $now_str,
        });
    };
    if ($@ || !$new_ticket) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'create_from_params', "SupportTicket create failed: $@");
        return { success => JSON::false, error => 'Ticket creation failed' };
    }
    eval { Comserv::Util::SpamGuard->record_submit($c) };

    my $ticket_id  = $new_ticket->id // '?';
    my $ticket_num = $new_ticket->ticket_number // $ticket_number;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'create_from_params',
        "AI helpdesk ticket: id=$ticket_id num=$ticket_num sitename=$site_name by=$username subject='$subject'");
    eval {
        die "quarantined\n" if $sg->{quarantine};   # no webhook for quarantined spam
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


# ---------------------------------------------------------------------------
# Reply / status / close on an existing ticket (#2491).
# Logged-in owner or HelpDesk staff may reply; only staff may set status or
# close. Guests cannot. No HelpDeskWebhook / email (#2494).
# ---------------------------------------------------------------------------

sub _is_staff {
    my ($self, $c) = @_;
    return 0 unless $c;
    return 1 if (eval { $c->stash->{is_admin} } || eval { $c->session->{is_admin} });
    my $roles = (eval { $c->stash->{user_roles} } ) || (eval { $c->session->{roles} }) || [];
    $roles = [$roles] unless ref $roles eq 'ARRAY';
    return 1 if grep {
        defined && lc($_) =~ /^(?:admin|administrator|helpdesksupport|helpdesk|staff)$/
    } @$roles;
    return 0;
}

sub _is_ticket_owner {
    my ($self, $c, $ticket) = @_;
    return 0 unless $c && $ticket;
    return 0 if $self->_is_guest($c);
    my $uid = eval { $c->session->{user_id} };
    my $un  = lc(eval { $c->session->{username} } || '');
    my $em  = lc(eval { $c->session->{email} } || eval { $c->stash->{email} } || '');
    my $t_uid = eval { $ticket->user_id };
    return 1 if $uid && defined $t_uid && $t_uid ne '' && $uid == $t_uid;
    my $t_un = lc(eval { $ticket->username } || '');
    return 1 if $un && $t_un && $un eq $t_un;
    my $t_em = lc(eval { $ticket->email } || '');
    return 1 if $em && $t_em && $em eq $t_em;
    return 0;
}

sub _can_reply_ticket {
    my ($self, $c, $ticket) = @_;
    return 0 if $self->_is_guest($c);
    return 1 if $self->_is_staff($c);
    return $self->_is_ticket_owner($c, $ticket);
}

sub _ticket_key_from_prompt {
    my ($self, $prompt) = @_;
    return unless defined $prompt;
    if ($prompt =~ /\b((?:[A-Z][A-Z0-9]+)-\d{8}-\d{3,})\b/i) {
        return uc $1;
    }
    if ($prompt =~ /\bticket\s*(?:number|#|id)?\s*[:#]?\s*(\d{1,7})\b/i) {
        return $1;
    }
    if ($prompt =~ /\b#(\d{1,7})\b/) {
        return $1;
    }
    return;
}

sub detect_update_intent {
    my ($self, $prompt) = @_;
    return unless defined $prompt && $prompt =~ /\S/;
    my $p = $prompt;
    $p =~ s/^\s+|\s+$//g;
    return if $p =~ /^(how\s+(do\s+i|to)|what\s+is|explain|where\s+(is|do))\b/i;
    # Do not steal create/file/open/submit a ticket unless the prompt is clearly
    # a reply or status change ("open a ticket" is create, "reopen ticket" is not).
    return if looks_like_helpdesk_ticket_create($p)
        && $p !~ /\b(?:reply|comment|respond|close|closed|resolve|resolved|reopen)\b/i;

    my $key = $self->_ticket_key_from_prompt($p);

    my $status;
    if ($p =~ /\breopen\b/i && $p =~ /\btickets?\b/i) {
        $status = 'open';
    }
    elsif ($p =~ /\bresolv(?:e|ed|ing)\b/i && $p =~ /\btickets?\b/i) {
        $status = 'resolved';
    }
    elsif ($p =~ /\b(?:close|closed|closing)\b/i && $p =~ /\btickets?\b/i) {
        $status = 'closed';
    }
    elsif ($p =~ /\bset\b.{0,40}\bstatus\b.{0,20}\b(open|closed|resolved)\b/i) {
        $status = lc $1;
    }
    elsif ($p =~ /\b(?:mark|set|change)\b.{0,40}\btickets?\b.{0,20}\b(open|closed|resolved)\b/i) {
        $status = lc $1;
    }
    if ($status) {
        return { action => 'status', ticket_key => $key, status => $status };
    }

    if ($p =~ /\b(?:reply|comment|respond)\b.{0,80}\btickets?\b/i
        || $p =~ /\btickets?\b.{0,80}\b(?:reply|comment|respond)\b/i
        || $p =~ /\badd\s+(?:a\s+)?(?:reply|comment)\b/i) {
        my $body = $p;
        $body =~ s/^.*?(?:reply(?:ing)?|comment|respond(?:ing)?)\s*(?:to|on|about)?\s*(?:(?:the|this|a)\s+)?(?:help\s*desk\s+|helpdesk\s+|support\s+)?tickets?\s*(?:#\s*)?(?:[A-Z0-9-]+|\d+)?\s*[:\-–,]?\s*//is;
        $body =~ s/^\s+|\s+$//g;
        $body = $p if length($body) < 2;
        return { action => 'reply', ticket_key => $key, body => $body };
    }
    return;
}

sub _find_ticket {
    my ($self, $c, $key) = @_;
    return unless defined $key && length $key;
    my $schema = $self->_schema($c) or return;
    if ($key =~ /^[A-Z][A-Z0-9]+-\d{8}-\d{3,}$/i) {
        return $schema->resultset('SupportTicket')->find({ ticket_number => uc $key });
    }
    if ($key =~ /^\d+$/) {
        my $by_id = $schema->resultset('SupportTicket')->find($key);
        return $by_id if $by_id;
        return $schema->resultset('SupportTicket')->find({ ticket_number => $key });
    }
    return;
}

sub _now_str {
    return DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
}

sub reply_from_params {
    my ($self, $c, $params) = @_;
    $params ||= {};
    return { success => JSON::false, error => 'Guests cannot reply to tickets' }
        if $self->_is_guest($c);
    my $key  = $params->{ticket_number} || $params->{ticket_id} || $params->{ticket_key} || '';
    my $body = $params->{body} // $params->{message} // $params->{reply} // '';
    $body =~ s/^\s+|\s+$//g;
    return { success => JSON::false, error => 'Reply body is required' } unless length $body;
    my $ticket = $self->_find_ticket($c, $key)
        or return { success => JSON::false, error => 'Ticket not found' };
    return { success => JSON::false, error => 'You can only reply to your own tickets' }
        unless $self->_can_reply_ticket($c, $ticket);

    # Intentionally no HelpDeskWebhook / email (#2494: no notify until ACCEPT).
    my $username = eval { $c->session->{username} } || '';
    my $email    = eval { $c->session->{email} }    || '';
    my $schema   = $self->_schema($c)
        or return { success => JSON::false, error => 'Database not available' };
    my $msg;
    eval {
        $msg = $schema->resultset('TicketMessage')->create({
            ticket_id    => $ticket->id,
            sender_type  => $self->_is_staff($c) ? 'staff' : 'user',
            sender_name  => $username,
            sender_email => $email,
            body         => $body,
            created_at   => $self->_now_str,
        });
    };
    if ($@ || !$msg) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'reply_from_params', "TicketMessage create failed: $@");
        return { success => JSON::false, error => 'Reply failed' };
    }
    my $num = $ticket->ticket_number;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'reply_from_params', "AI helpdesk reply (no notify): ticket=$num by=$username");
    return {
        success       => JSON::true,
        message       => "Reply added to ticket $num.",
        ticket_id     => ($ticket->id // 0) + 0,
        ticket_number => $num,
        ticket_url    => "/HelpDesk/ticket/$num",
        message_id    => $msg->id,
        notified      => JSON::false,
    };
}

sub set_status_from_params {
    my ($self, $c, $params) = @_;
    $params ||= {};
    return { success => JSON::false, error => 'Guests cannot change ticket status' }
        if $self->_is_guest($c);
    return { success => JSON::false, error => 'Only HelpDesk staff can change ticket status' }
        unless $self->_is_staff($c);
    my $key    = $params->{ticket_number} || $params->{ticket_id} || $params->{ticket_key} || '';
    my $status = lc($params->{status} || '');
    $status = 'closed' if !$status && ($params->{close} || $params->{action} && $params->{action} eq 'close');
    return { success => JSON::false, error => 'Status must be open, resolved, or closed' }
        unless $status =~ /^(?:open|resolved|closed)$/;
    my $ticket = $self->_find_ticket($c, $key)
        or return { success => JSON::false, error => 'Ticket not found' };
    eval {
        $ticket->status($status);
        if ($ticket->can('closed_at')) {
            if ($status =~ /^(?:closed|resolved)$/) {
                $ticket->closed_at($self->_now_str);
            }
            else {
                $ticket->closed_at(undef);
            }
        }
        $ticket->update;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'set_status_from_params', "status update failed: $@");
        return { success => JSON::false, error => 'Status update failed' };
    }
    my $num = $ticket->ticket_number;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'set_status_from_params', "AI helpdesk status (no notify): ticket=$num status=$status");
    return {
        success       => JSON::true,
        message       => "Ticket $num is now $status.",
        ticket_id     => ($ticket->id // 0) + 0,
        ticket_number => $num,
        ticket_url    => "/HelpDesk/ticket/$num",
        status        => $status,
        notified      => JSON::false,
    };
}

sub try_chat_update {
    my ($self, $c, %args) = @_;
    my $intent = $self->detect_update_intent($args{prompt} // '') or return;
    if (!$intent->{ticket_key}) {
        return {
            handled       => 1,
            success       => 1,
            response      => 'Which ticket should I update? Please include the ticket number (for example CSC-20261122-0001).',
            model         => '(helpdesk-ticket-update)',
            provider      => 'ai2-helpdesk',
            ticket_action => {
                success      => JSON::false,
                need_clarify => JSON::true,
                field        => 'ticket_number',
                draft        => $intent,
            },
        };
    }
    if ($self->_is_guest($c)) {
        return {
            handled       => 1,
            success       => 1,
            response      => 'Please log in to reply to or update a HelpDesk ticket.',
            model         => '(helpdesk-ticket-update)',
            provider      => 'ai2-helpdesk',
            ticket_action => { success => JSON::false, error => 'Login required' },
        };
    }
    my $result;
    if (($intent->{action} || '') eq 'reply') {
        $result = eval {
            $self->reply_from_params($c, {
                ticket_key    => $intent->{ticket_key},
                ticket_number => $intent->{ticket_key},
                body          => $intent->{body},
            });
        };
    }
    else {
        $result = eval {
            $self->set_status_from_params($c, {
                ticket_key    => $intent->{ticket_key},
                ticket_number => $intent->{ticket_key},
                status        => $intent->{status},
            });
        };
    }
    if ($@ || !$result) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'try_chat_update', "update threw: $@");
        $result = { success => JSON::false, error => 'Ticket update failed' };
    }
    my $msg = $result->{message} || $result->{error} || 'Ticket request processed.';
    $msg .= ' ' . $result->{ticket_url} if $result->{success} && $result->{ticket_url};
    return {
        handled       => 1,
        success       => 1,
        response      => $msg,
        model         => '(helpdesk-ticket-update)',
        provider      => 'ai2-helpdesk',
        ticket_action => $result,
    };
}

__PACKAGE__->meta->make_immutable;
1;

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    use_ok('Comserv::Model::AI2::ChatIntent');
    use_ok('Comserv::Model::AI2::HelpDeskTicketCreate');
    use_ok('Comserv::Model::AI2::TodoCreate');
}

ok(Comserv::Model::AI2::ChatIntent::is_editor_agent('programming'), 'programming is editor');
ok(Comserv::Model::AI2::ChatIntent::is_editor_agent('documentation'), 'documentation is editor');
ok(!Comserv::Model::AI2::ChatIntent::is_editor_agent('helpdesk'), 'helpdesk is not editor');
ok(!Comserv::Model::AI2::ChatIntent::is_editor_agent('general'), 'general is not editor');

ok(Comserv::Model::AI2::ChatIntent::looks_like_helpdesk_ticket_create(
    'Create a HelpDesk ticket: Chat-with-AI todo-create asked which 3d project'),
    'ticket+todo subject looks like ticket create');
ok(Comserv::Model::AI2::ChatIntent::looks_like_todo_create(
    'add a todo to fix helpdesk ticket create'),
    'add-a-todo looks like todo create');
ok(!Comserv::Model::AI2::ChatIntent::looks_like_todo_create(
    'Create a HelpDesk ticket: Chat-with-AI todo-create asked which 3d project'),
    'ticket subject with todo-create wording is not todo-primary');

my $hd = Comserv::Model::AI2::HelpDeskTicketCreate->new;
ok($hd, 'HelpDeskTicketCreate instantiates');

my $intent = $hd->detect_create_intent(
    'Create a HelpDesk ticket: Chat-with-AI todo-create asked which 3d project'
);
ok($intent, 'detects helpdesk ticket create with todo wording in subject');
like($intent->{subject}, qr/todo-create|3d project|Chat-with-AI/i, 'subject keeps bug description');

ok($hd->detect_create_intent('Please create a helpdesk ticket for this issue'),
    'detects plain helpdesk ticket create');
ok($hd->detect_create_intent('file a ticket: AI Editor create-todo hijack'),
    'detects file-a-ticket');
ok($hd->detect_create_intent('open a support ticket titled TodoCreate false positive'),
    'detects open support ticket');
ok(!$hd->detect_create_intent('how do I create a helpdesk ticket'),
    'ignores how-to');
ok(!$hd->detect_create_intent('add a todo to fix helpdesk ticket create'),
    'does not steal explicit todo create');
ok(!$hd->detect_create_intent('create a todo for the helpdesk ticket create bug'),
    'does not steal create-todo for ticket bug');

# Routing priority: ticket brain wins when both words appear; todo brain yields.
my $todo = Comserv::Model::AI2::TodoCreate->new;
my $mixed = 'Create a HelpDesk ticket: Chat-with-AI todo-create asked which 3d project';
ok($hd->detect_create_intent($mixed), 'ticket brain claims mixed prompt');
ok(!$todo->detect_create_intent($mixed), 'todo brain yields mixed prompt');

{
    package local::FakeC;
    sub new { bless { session => { username => 'cscdeveloper' } }, shift }
    sub session { shift->{session} }
    sub stash { return {} }
}
my $c = local::FakeC->new;
my $ct = $hd->chat_contract($c);
like($ct, qr/create_helpdesk_ticket/, 'chat contract documents create_helpdesk_ticket');
like($ct, qr/Do NOT emit create_todo/i, 'chat contract forbids create_todo for tickets');


# Guest path: extract email; no hard login wall in detect; contract available to guests.
ok($hd->detect_create_intent(
    'Create a helpdesk ticket to fix the display of unsubscribed features in the menu bar'),
    'guest menu-bar ticket ask detects');
my $with_email = $hd->detect_create_intent(
    'Create a helpdesk ticket about the menu bar. My email is guest@example.com');
ok($with_email && $with_email->{email} && $with_email->{email} eq 'guest@example.com',
    'detect extracts guest email from prompt');

{
    package local::FakeGuestC;
    sub new { bless { session => { username => 'guest' } }, shift }
    sub session { shift->{session} }
    sub stash { return {} }
}
my $gc = local::FakeGuestC->new;
my $gct = $hd->chat_contract($gc);
like($gct, qr/create_helpdesk_ticket/, 'guest still gets helpdesk chat contract');

my $guest_block = $hd->try_chat_create($gc,
    prompt => 'Create a helpdesk ticket to fix the display of unsubscribed features in the menu bar');
ok($guest_block && $guest_block->{handled}, 'guest ticket intent handled');
unlike($guest_block->{response} // '', qr/Log in to create/i, 'no login wall for guests');
ok($guest_block->{ticket_action}{need_clarify}, 'guest without email is asked to clarify email');

my $guest_ready = $hd->try_chat_create($gc,
    prompt => 'Create a helpdesk ticket about menu bar unsubscribed features. Contact me at guest@example.com');
# Without DB this may fail create; assert we did NOT return Login required.
ok($guest_ready && $guest_ready->{handled}, 'guest with email handled');
unlike($guest_ready->{response} // '', qr/Log in to create/i, 'guest with email not login-walled');
is(($guest_ready->{ticket_action}{error} // ''), '', 'no Login required error when email present')
    if $guest_ready->{ticket_action} && ($guest_ready->{ticket_action}{error} // '') eq 'Login required';
# Soft assert: either created, clarify, or DB error — never Login required.
ok((($guest_ready->{ticket_action}{error} // '') ne 'Login required'),
    'guest+email never Login required');



# todo #2490: AI ticket create fail-closes on the shared honeypot / rate guards.
{
    package local::FakeReq2;
    sub new { my ($c, %p) = @_; bless { params => { %p }, address => '127.0.0.1' }, $c }
    sub params  { $_[0]{params} }
    sub address { $_[0]{address} }
    sub header  { undef }
    package local::FakeGuestC2;
    sub new {
        my ($c, %a) = @_;
        bless {
            session => { username => 'guest', email => '', hd_public_submits => $a{stamps} || [] },
            req     => $a{req} || local::FakeReq2->new(website => ''),
            stash   => {},
        }, $c;
    }
    sub session { $_[0]{session} }
    sub stash   { $_[0]{stash} }
    sub req     { $_[0]{req} }
}
my $hp_create = $hd->create_from_params(
    local::FakeGuestC2->new(req => local::FakeReq2->new(website => 'http://bot.example')),
    { subject => 'Need help with billing', description => 'Please call me', email => 'guest@example.com' },
);
ok($hp_create && !$hp_create->{success}, 'honeypot does not create a ticket');
like($hp_create->{error} // '', qr/Submission failed/i, 'honeypot fail-closed message');

my $now = time();
my $rate_create = $hd->create_from_params(
    local::FakeGuestC2->new(stamps => [ $now - 5, $now - 10, $now - 15 ]),
    { subject => 'Need help with billing', description => 'Please call me', email => 'guest@example.com' },
);
ok($rate_create && !$rate_create->{success}, 'session rate does not create a ticket');
like($rate_create->{error} // '', qr/Too many submissions/i, 'rate fail-closed message');


# ── Reply / status / close (#2491), no notify (#2494) ───────────────────────
ok(!$hd->detect_update_intent('Create a HelpDesk ticket: login is broken'),
    'create prompt is not an update intent');
ok(!$hd->detect_update_intent('how do I close a ticket'),
    'how-to is not an update intent');

my $close_i = $hd->detect_update_intent('Please close ticket CSC-20261122-0001');
ok($close_i && $close_i->{action} eq 'status' && $close_i->{status} eq 'closed',
    'detects close ticket');
is($close_i->{ticket_key}, 'CSC-20261122-0001', 'close extracts ticket number');

my $resolve_i = $hd->detect_update_intent('resolve ticket #84');
ok($resolve_i && $resolve_i->{action} eq 'status' && $resolve_i->{status} eq 'resolved',
    'detects resolve ticket #id');

my $reopen_i = $hd->detect_update_intent('reopen ticket CSC-20261122-0001');
ok($reopen_i && $reopen_i->{status} eq 'open', 'reopen maps to open');

my $reply_i = $hd->detect_update_intent('Reply to ticket CSC-20261122-0001: still happening on /planning/daily');
ok($reply_i && $reply_i->{action} eq 'reply', 'detects reply to ticket');
like($reply_i->{body}, qr/still happening/i, 'reply body keeps the message');
is($reply_i->{ticket_key}, 'CSC-20261122-0001', 'reply extracts ticket number');

{
    package t::FakeTicket;
    sub new { my ($class, %h) = @_; bless { %h }, $class }
    sub id { $_[0]{id} }
    sub ticket_number { $_[0]{ticket_number} }
    sub user_id { $_[0]{user_id} }
    sub username { $_[0]{username} }
    sub email { $_[0]{email} }
    sub status {
        my ($self, $v) = @_;
        $self->{status} = $v if @_ > 1;
        return $self->{status};
    }
    sub closed_at {
        my ($self, $v) = @_;
        $self->{closed_at} = $v if @_ > 1;
        return $self->{closed_at};
    }
    sub can { return 1 if $_[1] eq 'closed_at'; return $_[0]->SUPER::can($_[1]); }
    sub update { $_[0]{updated} = 1; 1 }
}

{
    package t::FakeMsg;
    sub new { my ($class, $row) = @_; bless { %$row, id => 99 }, $class }
    sub id { $_[0]{id} }
}

{
    package t::FakeMsgRS;
    sub new { my ($class) = @_; bless { created => [] }, $class }
    sub create {
        my ($self, $row) = @_;
        my $msg = t::FakeMsg->new($row);
        push @{ $self->{created} }, $msg;
        return $msg;
    }
}

{
    package t::FakeSchema;
    sub new { my ($class, %h) = @_; bless { %h }, $class }
    sub resultset {
        my ($self, $name) = @_;
        return $self->{msg_rs} if $name eq 'TicketMessage';
        return $self;
    }
    sub find { $_[0]{ticket} }
}

{
    package t::FakeC;
    sub new { my ($class, %h) = @_; bless { %h }, $class }
    sub session { $_[0]{session} ||= {} }
    sub stash   { $_[0]{stash}   ||= {} }
}

{
    package t::QuietLog;
    sub instance { bless {}, shift }
    sub log_message { 1 }
    sub log_with_details { 1 }
}

my $ticket = t::FakeTicket->new(
    id => 84, ticket_number => 'CSC-20261122-0001',
    user_id => 7, username => 'pat', email => 'pat@example.com',
    status => 'open',
);
my $msg_rs = t::FakeMsgRS->new;
my $schema = t::FakeSchema->new(ticket => $ticket, msg_rs => $msg_rs);
$hd->{logging} = t::QuietLog->instance if eval { $hd->can('logging') };
# The accessor is usually a Moose attr; force via logging() if needed later.

{
    no warnings 'redefine';
    local *Comserv::Model::AI2::HelpDeskTicketCreate::_schema = sub { $schema };
    local *Comserv::Model::AI2::HelpDeskTicketCreate::_find_ticket = sub { $ticket };
    my $webhook_calls = 0;
    local *Comserv::Util::HelpDeskWebhook::notify_ticket_change = sub { $webhook_calls++; die 'webhook should not fire' };

    my $guest = t::FakeC->new(session => { username => 'guest' }, stash => { user_roles => ['guest'] });
    my $g_reply = $hd->reply_from_params($guest, {
        ticket_number => 'CSC-20261122-0001', body => 'hi',
    });
    ok(!$g_reply->{success}, 'guest cannot reply');
    my $g_status = $hd->set_status_from_params($guest, {
        ticket_number => 'CSC-20261122-0001', status => 'closed',
    });
    ok(!$g_status->{success}, 'guest cannot close');

    my $g_hit = $hd->try_chat_update($guest, prompt => 'close ticket CSC-20261122-0001');
    ok($g_hit && $g_hit->{handled}, 'guest update is handled');
    ok(!$g_hit->{ticket_action}{success}, 'guest update is denied');
    like($g_hit->{response}, qr/log in/i, 'guest is asked to log in');

    my $owner = t::FakeC->new(
        session => { username => 'pat', user_id => 7, email => 'pat@example.com' },
        stash   => { user_roles => ['member'] },
    );
    my $o_reply = $hd->reply_from_params($owner, {
        ticket_number => 'CSC-20261122-0001',
        body          => 'still happening on /planning/daily',
    });
    ok($o_reply->{success}, 'owner can reply');
    is($o_reply->{notified}, JSON::false, 'owner reply is not notified');
    is(scalar @{ $msg_rs->{created} }, 1, 'TicketMessage row created for owner reply');
    is($msg_rs->{created}[0]{sender_type}, 'user', 'owner reply sender_type is user');
    my $o_close = $hd->set_status_from_params($owner, {
        ticket_number => 'CSC-20261122-0001', status => 'closed',
    });
    ok(!$o_close->{success}, 'owner cannot close');

    my $other = t::FakeC->new(
        session => { username => 'sam', user_id => 8, email => 'sam@example.com' },
        stash   => { user_roles => ['member'] },
    );
    my $x_reply = $hd->reply_from_params($other, {
        ticket_number => 'CSC-20261122-0001', body => 'not mine',
    });
    ok(!$x_reply->{success}, 'non-owner member cannot reply');

    my $staff = t::FakeC->new(
        session => { username => 'helpdesksupport', user_id => 2 },
        stash   => { user_roles => ['helpdesksupport'] },
    );
    my $s_reply = $hd->reply_from_params($staff, {
        ticket_number => 'CSC-20261122-0001', body => 'we are looking at it',
    });
    ok($s_reply->{success}, 'staff can reply');
    is($s_reply->{notified}, JSON::false, 'staff reply is not notified');
    is($msg_rs->{created}[-1]{sender_type}, 'staff', 'staff reply sender_type is staff');
    my $s_close = $hd->set_status_from_params($staff, {
        ticket_number => 'CSC-20261122-0001', status => 'closed',
    });
    ok($s_close->{success}, 'staff can close');
    is($s_close->{status}, 'closed', 'staff close sets closed');
    is($s_close->{notified}, JSON::false, 'staff close is not notified');
    is($ticket->{status}, 'closed', 'ticket status updated');
    ok($ticket->{updated}, 'ticket->update called');
    is($webhook_calls, 0, 'no HelpDeskWebhook notify on reply or status');

    # Editor skip is at the Chat/AI2 caller (#2495); the brain still works if
    # invoked, and Chat already gates try_chat_create with is_editor_agent.
}

# chat_contract: guests do not get reply/status actions; staff do.
my $guest_c = t::FakeC->new(session => { username => 'guest' }, stash => {});
my $g_contract = $hd->chat_contract($guest_c);
unlike($g_contract, qr/reply_helpdesk_ticket/, 'guest contract has no reply action');
unlike($g_contract, qr/close_helpdesk_ticket/, 'guest contract has no close action');

my $staff_c = t::FakeC->new(
    session => { username => 'helpdesksupport' },
    stash   => { user_roles => ['helpdesksupport'] },
);
my $s_contract = $hd->chat_contract($staff_c);
like($s_contract, qr/reply_helpdesk_ticket/, 'staff contract includes reply action');
like($s_contract, qr/close_helpdesk_ticket/, 'staff contract includes close action');

my $mem_c = t::FakeC->new(
    session => { username => 'pat' },
    stash   => { user_roles => ['member'] },
);
my $m_contract = $hd->chat_contract($mem_c);
like($m_contract, qr/reply_helpdesk_ticket/, 'member contract includes reply action');
unlike($m_contract, qr/close_helpdesk_ticket/, 'member contract has no close action');


done_testing();


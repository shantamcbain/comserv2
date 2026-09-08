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

done_testing();

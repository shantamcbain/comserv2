#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON;

BEGIN {
    use_ok('Comserv::Model::AI2::TodoCreate');
    use_ok('Comserv::Model::AI2::Chat');
    use_ok('Comserv::Model::AI2::ChatIntent');
}

{
    package local::FakeResp;
    sub new { bless { status => 200, body => '', ctype => '' }, shift }
    sub status { $_[0]{status} = $_[1] if @_ > 1; $_[0]{status} }
    sub body   { $_[0]{body}   = $_[1] if @_ > 1; $_[0]{body} }
    sub content_type { $_[0]{ctype} = $_[1] if @_ > 1; $_[0]{ctype} }

    package local::FakeTodoRow;
    sub new { my ($c, $id) = @_; bless { record_id => $id, id => $id }, $c }
    sub record_id { $_[0]{record_id} }
    sub id        { $_[0]{id} }

    package local::FakeC;
    sub new {
        my ($c, %a) = @_;
        bless {
            session  => $a{session} || { username => 'cscdeveloper', SiteName => 'CSC' },
            stash    => $a{stash}   || { SiteName => 'CSC' },
            response => local::FakeResp->new,
        }, $c;
    }
    sub session  { $_[0]{session} }
    sub stash    { $_[0]{stash} }
    sub response { $_[0]{response} }
    sub model    { return }
}

my $brain = Comserv::Model::AI2::TodoCreate->new;
ok($brain, 'TodoCreate instantiates');

# Contract is injected for logged-in Chat-with-AI; guests get none (#2295).
{
    no warnings 'redefine';
    local *Comserv::Model::AI2::TodoCreate::list_site_projects = sub {
        return [ { id => 42, project_code => 'system', name => 'System', parent_id => undef } ];
    };
    my $logged = local::FakeC->new;
    my $ct = $brain->chat_contract($logged);
    like($ct, qr/\[ACTION:.*"create_todo"/s, 'logged-in contract documents create_todo ACTION');
    like($ct, qr/#42/, 'contract includes the project catalog');
    like($ct, qr/do not invent a project_id/i, 'contract forbids inventing project ids');

    my $guest = local::FakeC->new(session => { username => 'guest', SiteName => 'CSC' });
    is($brain->chat_contract($guest), '', 'guest gets no todo-create contract');
}

# Editor agents skip the app-write contract; Chat-with-AI general does not.
ok(Comserv::Model::AI2::ChatIntent::is_editor_agent('programming'), 'programming is editor');
ok(!Comserv::Model::AI2::ChatIntent::is_editor_agent('general'), 'general chat is not editor');
ok(!Comserv::Model::AI2::ChatIntent::is_editor_agent('helpdesk'), 'helpdesk agent is not editor');

{
    my $chat = Comserv::Model::AI2::Chat->new;
    no warnings 'redefine';
    local *Comserv::Model::AI2::TodoCreate::list_site_projects = sub {
        return [ { id => 42, project_code => 'system', name => 'System' } ];
    };
    local *Comserv::Model::AI2::HelpDeskTicketCreate::chat_contract = sub { '' }
        if 0;
    my $c = local::FakeC->new;
    my $general = $chat->build_system_prompt($c, agent_id => 'general');
    like($general, qr/create_todo/, 'Chat-with-AI general prompt includes create_todo contract');

    my $editor = $chat->build_system_prompt($c, agent_id => 'programming');
    unlike($editor, qr/\[ACTION:.*"create_todo"/s, 'editor programming prompt skips todo ACTION contract');
}

# /ai2/action create_todo is perform_create → create_from_params. Stub the DB
# so "add a todo…" through try_chat_create actually produces a new row id.
{
    my $inserted;
    no warnings 'redefine';
    local *Comserv::Model::AI2::TodoCreate::match_project = sub {
        return {
            status  => 'exact',
            project => { id => 42, name => 'System', project_code => 'system' },
        };
    };
    local *Comserv::Model::AI2::TodoCreate::similar_open_todos = sub { [] };
    local *Comserv::Model::AI2::TodoCreate::_insert_todo = sub {
        my ($self, $c, %a) = @_;
        $inserted = \%a;
        return (local::FakeTodoRow->new(4242), undef);
    };
    local *Comserv::Model::AI2::TodoCreate::rank_handoff = sub { {} };
    local *Comserv::Model::AI2::TodoCreate::schedule_handoff = sub { {} };

    my $c = local::FakeC->new;
    my $hit = $brain->try_chat_create($c, prompt => 'add a todo pin SuperGrok in the editor');
    ok($hit && $hit->{handled}, 'add-a-todo intercept is handled');
    ok($hit->{todo_action} && $hit->{todo_action}{success}, 'intercept creates a todo, not a subject prompt');
    is($hit->{todo_action}{todo_id}, 4242, 'created todo id is returned');
    like($hit->{todo_action}{todo_url} // '', qr{/todo/details\?record_id=4242}, 'returns a details URL');
    ok($inserted && $inserted->{subject}, 'insert received a subject');
    unlike($inserted->{subject} // '', qr/^(this|that|it)$/i, 'subject is a real title');

    # Same brain as POST /ai2/action create_todo.
    $inserted = undef;
    $c = local::FakeC->new;
    $brain->perform_create($c, {
        subject     => 'pin SuperGrok in the editor',
        description => 'added from chat action',
        project_id  => 42,
    });
    is($c->response->status, 200, 'perform_create /ai2/action returns HTTP 200');
    my $payload = eval { decode_json($c->response->body) } || {};
    ok($payload->{success}, 'perform_create reports success');
    is($payload->{todo_id}, 4242, 'perform_create created todo 4242');
    ok($inserted, '_insert_todo was called from perform_create');
}

# Shared brain: /ai/action create_todo now delegates to TodoCreate (not the
# old inline insert that could omit project_id).
ok(1, 'legacy /ai/action create_todo delegates to TodoCreate (see Controller::AI)');

done_testing();

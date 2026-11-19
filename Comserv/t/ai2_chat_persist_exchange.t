#!/usr/bin/env perl
# Each /ai2/chat exchange must record the typed prompt and the returned reply.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Comserv::Model::AI2::Chat;

my $editor = join "\n",
    '[AI Editor agent=programming phase=plan]',
    'Contract:',
    'B) plan — short plan only.',
    '',
    'Please fix the problem with saving the chat.',
    '',
    '---',
    'These files were loaded live from this app via GET /ai2/load_file.',
    '',
    '[FILE:root/admin/git/index.tt]',
    '```',
    'file body',
    '```';

my $rec = Comserv::Model::AI2::Chat::user_prompt_record($editor);
is($rec->{ask}, 'Please fix the problem with saving the chat.', 'typed ask is the saved prompt');
is($rec->{title}, 'Please fix the problem with saving the chat.', 'title is the ask, not the contract');
is($rec->{files}[0], 'root/admin/git/index.tt', 'attached file path is recorded');
like($rec->{full}, qr/\[FILE:root\/admin\/git\/index\.tt\]/, 'full prompt is kept');

my $plain = Comserv::Model::AI2::Chat::user_prompt_record("Why was north chosen?\n");
is($plain->{ask}, 'Why was north chosen?', 'plain chat prompt is unchanged');

require Comserv::Model::RemoteDB;
my $rdb = Comserv::Model::RemoteDB->new;
$rdb->_load_config();
my $conn = $rdb->config->{db_production_mysql};
if (!$conn || !$conn->{database}) {
    diag('DBEncy connection unavailable; extractor tests only');
    done_testing;
    exit 0;
}

require Comserv::Model::Schema::Ency;
my $dsn = "dbi:mysql:database=$conn->{database};host=$conn->{host};port=" . ($conn->{port} || 3306);
my $schema = Comserv::Model::Schema::Ency->connect(
    $dsn, $conn->{username}, $conn->{password},
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
);
my ($uid) = $schema->storage->dbh->selectrow_array(
    q{SELECT id FROM users WHERE username = 'Shanta' LIMIT 1}
);
$uid ||= $schema->storage->dbh->selectrow_array(q{SELECT id FROM users ORDER BY id LIMIT 1});
ok($uid, 'have a user_id for the exchange row') or do { done_testing; exit 0 };

package FakeLog {
    sub new { bless {}, shift }
    sub log_with_details { 1 }
}
package FakeModel {
    sub new { my ($c, $schema) = @_; bless { schema => $schema }, $c }
    sub schema { $_[0]->{schema} }
}
package FakeC {
    sub new { bless { session => $_[1], model => $_[2] }, $_[0] }
    sub session { $_[0]->{session} }
    sub model { $_[0]->{model} }
}

my $c = FakeC->new(
    { username => 'Shanta', user_id => $uid, SiteName => 'CSC' },
    FakeModel->new($schema),
);
my $chat = Comserv::Model::AI2::Chat->new(logging => FakeLog->new);
my $saved = $chat->persist_exchange($c,
    prompt   => $editor,
    response => 'Saved both sides of the exchange.',
    model    => 'router-gitfix (cohere/north-mini-code:free + decision)',
    agent_id => 'programming',
    phase    => 'plan',
    page_path => 'root/admin/git/index.tt',
    provider => 'ai2-gitfix',
);
ok($saved->{conversation_id}, 'first exchange created a conversation');

my $cid = $saved->{conversation_id};
my @rows = $schema->resultset('AiMessage')->search(
    { conversation_id => $cid },
    { order_by => 'id' },
)->all;
is(scalar @rows, 2, 'one user row and one assistant row');
is($rows[0]->role, 'user', 'first row is the prompt');
is($rows[0]->content, 'Please fix the problem with saving the chat.', 'user content is the typed prompt');
like($rows[0]->metadata, qr/prompt_sent/, 'full posted prompt is in metadata');
is($rows[1]->role, 'assistant', 'second row is the return');
is($rows[1]->content, 'Saved both sides of the exchange.', 'assistant content is the return');

my $again = $chat->persist_exchange($c,
    prompt          => 'Follow-up: why was north chosen?',
    response        => 'Because the plan phase was pinned to north-mini.',
    model           => 'grok-4.7',
    agent_id        => 'programming',
    conversation_id => $cid,
);
is($again->{conversation_id}, $cid, 'second exchange stays on the same conversation');
my $n = $schema->resultset('AiMessage')->search({ conversation_id => $cid })->count;
is($n, 4, 'second exchange added the prompt and the return');

$schema->resultset('AiMessage')->search({ conversation_id => $cid })->delete;
$schema->resultset('AiConversation')->find($cid)->delete;

done_testing;

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN { use_ok('Comserv::Model::AI2::CodeRead'); }

my $m = Comserv::Model::AI2::CodeRead->new;
ok($m, 'CodeRead instantiates');

is($m->sanitize_rel_path('lib/Comserv/Controller/AI2.pm'),
   'lib/Comserv/Controller/AI2.pm', 'plain rel path');
is($m->sanitize_rel_path('Comserv/lib/Comserv/Controller/AI2.pm'),
   'lib/Comserv/Controller/AI2.pm', 'strips Comserv/ prefix');
is($m->sanitize_rel_path('../etc/passwd'), '', 'rejects ..');
is($m->sanitize_rel_path('/etc/passwd'), '', 'rejects absolute');
is($m->sanitize_rel_path("lib/foo\0.pm"), '', 'rejects null');

ok($m->path_allowed('lib/Comserv/Model/AI2/Chat.pm'), 'lib/ allowed');
ok($m->path_allowed('root/static/js/ai2editor/chat.js'), 'root/ allowed');
ok(!$m->path_allowed('etc/passwd'), 'etc/ refused');
ok(!$m->path_allowed('config/secrets.json'), 'config/ refused');

ok($m->is_secret('.env'), '.env is secret');
ok($m->is_secret('root/.env.production'), 'nested .env is secret');
ok($m->is_secret('lib/foo.pem'), 'pem is secret');
ok(!$m->is_secret('lib/Comserv/Controller/AI2.pm'), 'source is not secret');

my $tags = $m->extract_read_requests(
    "Need [READ_FILE: lib/Comserv/Controller/AI2.pm] and [READ_FILE: root/ai2/editor/editing_widget_popup.tt:10-20]"
);
is(scalar @$tags, 2, 'two READ_FILE tags');
is($tags->[0]{path}, 'lib/Comserv/Controller/AI2.pm', 'first path');
is($tags->[1]{start}, 10, 'slice start');
is($tags->[1]{end}, 20, 'slice end');

my $mentions = $m->extract_path_mentions(
    'Please look at lib/Comserv/Model/AI2/Chat.pm and also /etc/passwd and config/foo.json'
);
is(scalar @$mentions, 1, 'only allowlisted mention');
is($mentions->[0]{path}, 'lib/Comserv/Model/AI2/Chat.pm', 'mentioned Chat.pm');

my $block = $m->format_file_block('lib/Foo.pm', "package Foo;\n1;\n", source => 'open-editor');
like($block, qr/\[FILE: lib\/Foo\.pm\] \(open-editor\)/, 'open-editor marker');
like($block, qr/package Foo/, 'content included');

my ($sliced) = $m->_slice_lines("a\nb\nc\nd\n", 2, 3);
is($sliced, "b\nc\n", 'line slice 2-3');

ok($m->editor_contract =~ /READ_FILE/, 'contract mentions READ_FILE');

ok($m->detect_capability_prompt('What files on disk are you able read'),
    'capability: what files on disk are you able read');
ok($m->detect_capability_prompt('which files can you read'), 'capability: which files');
ok($m->detect_capability_prompt('Can you read the files?'), 'capability: punctuated');
ok($m->detect_capability_prompt('read the application code'), 'capability: read the application code');
ok($m->detect_capability_prompt('do you have filesystem access'), 'capability: filesystem access');
ok(!$m->detect_capability_prompt('please fix the login bug'), 'not capability: fix request');
ok(!$m->detect_capability_prompt('how do I add a todo'), 'not capability: how-to');

ok($m->detect_inspect_prompt('Please look at the code and tell me what you can see'),
    'inspect: look at the code / what you can see');
ok($m->detect_inspect_prompt('I want the code to be read and evaluated'),
    'inspect: read and evaluated');
my @defs = $m->default_app_paths;
is(scalar @defs, 4, 'default app paths for evaluate');
ok(!$m->detect_inspect_prompt('please fix the login bug'), 'not inspect: fix request');

is($m->first_lines("a\nb\nc\nd\n", 2), "a\nb\n... (truncated)", 'first_lines truncates');

done_testing();

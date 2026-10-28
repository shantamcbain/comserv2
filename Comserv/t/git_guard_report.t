#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use Comserv::Util::GitGuardReport;

my $out = join("\n",
    '  BLOCKED: Comserv/lib/Comserv/Util/Foo.pm:42 — gitleaks rule generic-api-key',
    '  BLOCKED: Comserv/.env — file name matches a secret/key pattern',
    '  ALLOWED (allow-listed, see .secret-guard-allow): Comserv/README.md — gitleaks rule x',
);

my $hits = Comserv::Util::GitGuardReport->enrich($out);
is(scalar @$hits, 2, 'two blocked hits, allow-listed line ignored');
is($hits->[0]{file}, 'Comserv/lib/Comserv/Util/Foo.pm', 'source file');
is($hits->[0]{line}, 42, 'line from BLOCKED loc');
ok(!$hits->[0]{key_file}, 'source is not a key file');
like($hits->[0]{editor_url}, qr{^/ai2/editing_widget_popup\?file=lib%2FComserv%2FUtil%2FFoo\.pm},
    'editor link strips Comserv/ and does not open a secret');
like($hits->[0]{editor_url}, qr{prompt=}, 'editor link carries a prompt');
unlike($hits->[0]{prompt}, qr/BEGIN |PRIVATE KEY|sk-/, 'prompt has no secret material');
like($hits->[0]{prompt}, qr/only ONE encryption key/, 'prompt states the one-key rule');

ok($hits->[1]{key_file}, '.env is a key file');
like($hits->[1]{editor_url}, qr{EnvFileManager\.pm}, 'key file opens env-file code, not the secret');
like($hits->[1]{editor_note}, qr/not opened/, 'key file explains why');

my $text = Comserv::Util::GitGuardReport->text_for($hits);
like($text, qr/Foo\.pm:42/, 'plain-text route names the location');
unlike($text, qr/\.env\?/, 'plain text does not turn the env path into a query');

done_testing;

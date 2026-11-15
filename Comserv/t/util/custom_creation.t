#!/usr/bin/env perl
# Guards for generated OpenSCAD. No app boot, no network: the render path is
# proved separately against the live service.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use_ok('Comserv::Util::CustomCreation');
my $cc = Comserv::Util::CustomCreation->new;

sub clean { my ($s, $e) = $cc->sanitize_scad(shift); return $e ? "ERR:$e" : $s }

like(clean("cube([10,10,10]);\n"), qr/^cube/, 'plain solid passes');

my $fenced = "```openscad\ncylinder(h=20, d=10);\n```";
like(clean($fenced), qr/^cylinder/, 'a code fence is stripped, the solid kept');

like(clean("ERROR: no size was given"), qr/^ERR:.*no size/, 'a model ERROR line is a refusal, not source');

like(clean("import(\"x.stl\");\ncube(10);"), qr/^ERR:.*read a file/, 'import is rejected');
like(clean("include <threads.scad>\ncube(10);"), qr/^ERR:/, 'include is rejected');
like(clean("use <x.scad>\ncube(10);"), qr/^ERR:/, 'use is rejected');

like(clean("// sorry, cannot build that"), qr/^ERR:.*cannot build/, 'a comment-only reply is a refusal');
like(clean("just some prose, no geometry"), qr/^ERR:.*no solid/, 'prose with no solid is refused');
like(clean('   '), qr/^ERR:.*nothing/, 'empty reply is refused');

# The file-word inside an identifier or a comment must not trip the guard.
like(clean("imported_size = 12;\ncube([imported_size, 5, 5]);"), qr/^imported_size/,
    'an identifier containing "import" is not a file read');

my $prompt = $cc->scad_system_prompt;
like($prompt, qr/ONLY the OpenSCAD source/, 'prompt demands source only');
like($prompt, qr/circumference \/ PI/, 'prompt converts circumference, never treats it as a diameter');
like($prompt, qr/Never use import/, 'prompt forbids file access');
like($prompt, qr/400 mm/, 'prompt states the size bound');

done_testing();

#!/usr/bin/env perl
# Proves the custom-creation path against the LIVE app: two different
# descriptions must each come back as STL bytes, and no template file may be
# added. Reads only. Run from the app dir:
#   perl -I local/lib/perl5 -I lib script/custom_creation_prove.pl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN { $ENV{CATALYST_HOME} = "$FindBin::Bin/.." unless $ENV{CATALYST_HOME} }

use Comserv;
use Comserv::Util::CustomCreation;

my $c = Comserv->new;
$c->setup_log unless $c->log;
my $cc = Comserv::Util::CustomCreation->new;

my @cases = (
    [ 'vacuum collar',
      'A collar to strengthen a vacuum cleaner tube that is 42 cm long, '
      . '29 cm circumference on the small end and 33 cm circumference on the large end. '
      . 'The collar goes on the large end, slipped on from the small end, same taper as the tube, '
      . '4 cm long, wall 2.4 mm, tight so it will not slip. Print the collar only, not the tube.' ],
    [ 'plain box',
      'A rectangular box, 60 mm long, 40 mm wide and 25 mm tall, with a wall thickness of 2 mm '
      . 'and an open top.' ],
);

my $fail = 0;
for my $case (@cases) {
    my ($name, $desc) = @$case;
    print "== $name ==\n";
    my $r = $cc->generate($c, description => $desc);
    if ($r->{error}) {
        print "FAIL: $r->{error}\n";
        $fail++;
        next;
    }
    my $n = length($r->{bytes});
    my $tri = unpack('V', substr($r->{bytes}, 80, 4));
    printf "OK  %d bytes, %d triangles, model %s\n", $n, $tri, $r->{model} // '?';
    $fail++ unless $n > 84 && $tri > 0;
}

my $templates = "$FindBin::Bin/../../services/openscad/templates";
my @tpl = glob("$templates/*.scad");
print "templates: @tpl\n";
$fail++ if @tpl != 1 || $tpl[0] !~ /herb_sign_v1\.scad$/;

print $fail ? "PROVE_FAIL=$fail\n" : "PROVE_OK\n";
exit($fail ? 1 : 0);

#!/usr/bin/env perl
# Diagnostic: what does the AI catalog actually return for the collar prompt?
# Prints routing + response shape only (no STL). Run:
#   perl -I local/lib/perl5 -I lib script/custom_creation_diag.pl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
BEGIN { $ENV{CATALYST_HOME} = "$FindBin::Bin/.." unless $ENV{CATALYST_HOME} }

use Time::HiRes qw(time);
use Comserv;
use Comserv::Util::CustomCreation;

my $c = Comserv->new;
$c->setup_log unless $c->log;
my $cc = Comserv::Util::CustomCreation->new;

my $desc = 'A collar to strengthen a vacuum cleaner tube that is 42 cm long, '
         . '29 cm circumference on the small end and 33 cm circumference on the large end. '
         . 'The collar goes on the large end, slipped on from the small end, same taper as the tube, '
         . '4 cm long, wall 2.4 mm, tight so it will not slip. Print the collar only, not the tube.';

my @msgs = (
    { role => 'system', content => $cc->scad_system_prompt },
    { role => 'user',   content => "Build this part:\n\n$desc" },
);

require Comserv::Model::AI2::Router;
my $router = Comserv::Model::AI2::Router->new;

my @tries = (
    [ 'bogus chain token (what the code did)', 'chain:chain_coding', {} ],
    [ 'explicit free coding model',            'cohere/north-mini-code:free', {} ],
    [ 'router auto, coding/implement',         undef, { agent_id => 'coding', phase => 'implement' } ],
);

for my $t (@tries) {
    my ($label, $model, $extra) = @$t;
    print "== $label ==\n";
    my $t0 = time;
    my $r = eval { $router->dispatch_chat($c, $model, [ @msgs ], max_tokens => 2500, %$extra) };
    my $dt = sprintf('%.1fs', time - $t0);
    if ($@) { print "  DIED after $dt: $@\n"; next; }
    if (ref $r ne 'HASH') { print "  non-hash reply after $dt\n"; next; }
    my $content = $r->{content} // '';
    my $len = length $content;
    my $blank = ($content =~ /\S/) ? 'no' : 'YES';
    print "  ${dt} success=", ($r->{success} // 'undef'),
          " provider=", ($r->{provider} // '?'),
          " model=",    ($r->{model} // '?'),
          " finish=",   ($r->{finish_reason} // '?'),
          " chars=$len blank=$blank\n";
    print "  error: $r->{error}\n" if $r->{error};
    print "  usage: ", join(',', map { "$_=" . ($r->{usage}{$_} // '?') } sort keys %{ $r->{usage} || {} }), "\n";
    if ($len) {
        my ($clean, $why) = $cc->sanitize_scad($content);
        print "  sanitize: ", ($why ? "REFUSED ($why)" : 'ok, ' . length($clean) . ' chars of source'), "\n";
        print "  head: ", substr($content, 0, 120) =~ s/\n/ /gr, "\n";
    }
    print "\n";
}

#!/usr/bin/env perl
# Ollama health for Today's Focus (AISYSTEM item 8): API up, llama-server
# binary present (Sep 30: "llama-server binary not found" after the 0.35.0
# upgrade), decision models pulled, recent load errors in the journal.
#   perl script/ollama_health.pl [--probe] [--json]
# --probe runs one tiny generate on tev1:0.8b (~4 s cold) to prove a model loads.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use JSON ();
use Comserv::Util::AI::HealthChecks;
my ($probe, $json) = (0, 0);
GetOptions(probe => \$probe, json => \$json) or die "usage: $0 [--probe] [--json]\n";
my $h = Comserv::Util::AI::HealthChecks::ollama_health(journal => 1);
if ($probe && $h->{up}) {
    require HTTP::Tiny;
    my $t0 = time;
    my $r = HTTP::Tiny->new(timeout => 120)->post("$Comserv::Util::AI::HealthChecks::OLLAMA_URL/api/generate", {
        headers => { 'Content-Type' => 'application/json' },
        content => JSON->new->encode({ model => 'tev1:0.8b', prompt => 'Reply with OK.', stream => JSON::false, options => { num_predict => 4 } }) });
    my $d = $r->{success} ? eval { JSON->new->decode($r->{content}) } : undef;
    $h->{probe} = { ok => ($d && defined $d->{response} ? 1 : 0), seconds => time - $t0,
                    error => ($r->{success} ? undef : "$r->{status} " . substr($r->{content} // '', 0, 200)) };
    push @{ $h->{problems} }, "probe tev1:0.8b failed: $h->{probe}{error}" unless $h->{probe}{ok};
    $h->{ok} = @{ $h->{problems} } ? 0 : 1;
}
if ($json) { print JSON->new->canonical->pretty->encode($h); exit($h->{ok} ? 0 : 2) }
printf "%s  Ollama %s  llama-server %s  focus models: %s%s\n", ($h->{ok} ? 'OK     ' : 'PROBLEM'),
    ($h->{up} ? "v$h->{version}" : 'DOWN'), ($h->{llama_server_ok} ? 'present' : 'MISSING'),
    join(', ', @{ $h->{focus_models} }), (@{ $h->{missing_models} || [] } ? ' (missing: ' . join(', ', @{ $h->{missing_models} }) . ')' : '');
print "  problem: $_\n" for @{ $h->{problems} };
print "  journal (24 h): ", scalar @{ $h->{recent_errors} || [] }, " load error line(s)", ($h->{errors_resolved} ? ' - all "binary not found" from the Sep 30 incident, binary present now (resolved)' : ''), "\n";
print "  probe tev1:0.8b: ", ($h->{probe}{ok} ? "OK in $h->{probe}{seconds}s" : "FAILED"), "\n" if $h->{probe};
exit($h->{ok} ? 0 : 2);

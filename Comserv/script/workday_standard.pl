#!/usr/bin/env perl
# Workday standard runner.
#   script/workday_standard.pl --check
#   script/workday_standard.pl --end-of-day
# --check is read-only. --end-of-day stops every branch server except :4006
# and signals Hermes dashboard/gateway processes. It does not close todo logs.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP ();
use Comserv::Util::WorkdayStandard;

my $end = grep { $_ eq '--end-of-day' } @ARGV;
my $json = JSON::PP->new->canonical->pretty;
my $base = $ENV{WORKDAY_API} || 'http://127.0.0.1:3001';

sub _get {
    my ($url) = @_;
    my $pid = open(my $fh, '-|', 'curl', '-sS', '-m', '8', $url) // return undef;
    local $/;
    my $body = <$fh> // '';
    close $fh;
    return eval { JSON::PP::decode_json($body) };
}

my $ws = _get("$base/api/todo/work_status");
my $rows = ($ws && ref $ws->{active} eq 'ARRAY') ? $ws->{active} : [];
my $todo_note = $ws ? '' : "todo work_status unreachable at $base";

my $report;
if ($end) {
    $report = Comserv::Util::WorkdayStandard->end_of_day(confirm => 1, work_rows => $rows);
} else {
    $report = Comserv::Util::WorkdayStandard->check(work_rows => $rows);
}
$report->{todo_note} = $todo_note if $todo_note;
print $json->encode($report);
exit($report->{ok} || $end ? 0 : 2);

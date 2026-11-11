#!/usr/bin/env perl
# Workday standard runner.
#   script/workday_standard.pl --check
#   script/workday_standard.pl --freshness           # stale docs/projects/todos only
#   script/workday_standard.pl --raise-audit-todos   # one audit todo per finding group
#   script/workday_standard.pl --end-of-day
# --check and --freshness are read-only. --end-of-day stops every branch server
# except :4006 and signals Hermes dashboard/gateway processes. It does not close
# todo logs.
#
# The freshness report is produced by GET /api/workday/check, because that is the
# only process that holds the DB handle; this script renders and files it.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP ();
use Time::Local ();
use Comserv::Util::WorkdayStandard;

my $end   = grep { $_ eq '--end-of-day' } @ARGV;
my $fresh = grep { $_ eq '--freshness' } @ARGV;
my $raise = grep { $_ eq '--raise-audit-todos' } @ARGV;
my $json  = JSON::PP->new->canonical->pretty->utf8;  # doc paths carry UTF-8
my $base  = $ENV{WORKDAY_API} || 'http://127.0.0.1:3001';

sub _get {
    my ($url) = @_;
    my $pid = open(my $fh, '-|', 'curl', '-sS', '-m', '45', $url) // return undef;
    local $/;
    my $body = <$fh> // '';
    close $fh;
    return eval { JSON::PP::decode_json($body) };
}

sub _post {
    my ($path, $payload) = @_;
    my $body = JSON::PP->new->canonical->utf8->encode($payload);
    my $pid = open(my $fh, '-|', 'curl', '-sS', '-m', '20', '-X', 'POST',
                   "$base$path", '-H', 'Content-Type: application/json', '-d', $body) // return undef;
    local $/;
    my $out = <$fh> // '';
    close $fh;
    return eval { JSON::PP::decode_json($out) };
}

sub _today { my @lt = localtime; sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]) }
sub _plus_days {
    my ($ymd, $n) = @_;
    my ($y, $m, $d) = $ymd =~ /^(\d{4})-(\d{2})-(\d{2})/ or return $ymd;
    my $e = eval { Time::Local::timegm(0, 0, 12, $d, $m - 1, $y) } or return $ymd;
    my @g = gmtime($e + $n * 86400);
    return sprintf('%04d-%02d-%02d', $g[5] + 1900, $g[4] + 1, $g[3]);
}

# --- freshness: report, or file it as one todo per group ----------------------
if ($fresh || $raise) {
    my $check = _get("$base/api/workday/check");
    my $f = $check && $check->{freshness};
    unless ($f && $f->{success}) {
        print $json->encode({ success => 0, error => ($f && $f->{error}) || 'freshness unavailable' });
        exit 2;
    }
    if ($fresh) {
        print $json->encode($f);
        exit(($f->{totals}{findings} // 0) ? 2 : 0);
    }

    require Comserv::Util::FreshnessAudit;
    # One todo per (owning branch, group). The trunk keeps only what no branch owns,
    # which is what an integration branch is for.
    my $plan = Comserv::Util::FreshnessAudit->route_findings(
        $f,
        owner_map => ($f->{owners} || {}),
        fallback  => ($f->{fallback} || {}),
    );
    my $list = _get("$base/api/todos?limit=5000");
    my %open_subject;
    for my $t (@{ ($list && $list->{todos}) ? $list->{todos} : [] }) {
        my $st = defined $t->{status} ? "$t->{status}" : '';
        next if $st =~ /^(3|4)$/;
        $open_subject{ $t->{subject} } = $t->{record_id};
    }
    my $today = _today();
    my $due   = _plus_days($today, 7);

    my (@created, @updated, @failed);
    for my $p (@$plan) {
        my $existing = $open_subject{ $p->{subject} };
        if ($existing) {
            my $r = _post('/api/todo/update', {
                record_id => $existing, actor => 'hermes-agent',
                append_comments => "[$today] re-checked, still open\n" . $p->{description},
            });
            if ($r && $r->{success}) { push @updated, { record_id => $existing, subject => $p->{subject} } }
            else { push @failed, { record_id => $existing, subject => $p->{subject},
                                   error => ($r && $r->{error}) || 'update failed' } }
            next;
        }
        my $r = _post('/api/todo/create', {
            subject => $p->{subject}, description => $p->{description},
            start_date => $today, due_date => $due, priority => 3, status => 1,
            # The API resolves developer to a real user row; the audit is filed to
            # the site owner, who is the one who acts on it.
            developer => ($ENV{WORKDAY_AUDIT_OWNER} || 'Shanta'),
            (defined $p->{project_id} ? (project_id => $p->{project_id}) : ()),
            actor => 'hermes-agent',
        });
        if ($r && $r->{success}) {
            push @created, { record_id => ($r->{todo_id} // $r->{record_id}),
                             project_id => $p->{project_id}, branch => $p->{branch},
                             subject => $p->{subject} };
        } else {
            push @failed, { subject => $p->{subject}, project_id => $p->{project_id},
                            error => ($r && $r->{error}) || 'create failed' };
        }
    }
    print $json->encode({ success => @failed ? 0 : 1, branch => $f->{branch},
                          created => \@created, updated => \@updated, failed => \@failed });
    exit(@failed ? 1 : 0);
}

my $ws = _get("$base/api/todo/work_status");
my $rows = ($ws && ref $ws->{active} eq 'ARRAY') ? $ws->{active} : [];
my $todo_note = $ws ? '' : "todo work_status unreachable at $base";

my $report;
if ($end) {
    $report = Comserv::Util::WorkdayStandard->end_of_day(confirm => 1, work_rows => $rows);
} else {
    $report = Comserv::Util::WorkdayStandard->check(work_rows => $rows);
    # The cron runs --check, so the freshness totals have to reach this report or
    # nobody sees them between sessions. One extra call; the API caches the scan.
    my $check = _get("$base/api/workday/check");
    my $f = $check && $check->{freshness};
    if ($f && $f->{success}) {
        $report->{freshness} = { branch => $f->{branch}, counts => $f->{counts},
                                 totals => $f->{totals} };
        $report->{counts}{freshness} = $f->{totals}{findings} // 0;
        $report->{ok} = 0 if ($f->{totals}{findings} // 0) > 0;
    } else {
        $report->{freshness} = { error => ($f && $f->{error}) || 'unavailable' };
    }
}
$report->{todo_note} = $todo_note if $todo_note;
print $json->encode($report);
exit($report->{ok} || $end ? 0 : 2);

#!/usr/bin/env perl
# Super Grok use-it-up pacing summary + burn alerts (Oct 8 2026). Reads the
# app's own numbers from GET /ai/usage_live (org.health.supergrok_pacing; LAN
# operator access) so there is one calculation
# (Model::AI2::UsageMonitor::supergrok_pacing / Util::AI::SuperGrokPacing).
#   perl script/supergrok_pacing.pl                 # print summary
#   perl script/supergrok_pacing.pl --inbox         # also write data/ai_eval_inbox/<date>-supergrok-pacing.json
#   perl script/supergrok_pacing.pl --alert         # cron: notify on new burn alerts / stale meter
#        [--no-notify] [--json-file F] [--data-dir D] [--base http://127.0.0.1:4006]
# --alert: each alert kind notifies once per PT day, again if it grows by
# >= renotify_pts (10). Notify = notify-send (DISPLAY :0 + user D-Bus when cron
# has none) else log only; always data/supergrok_alerts.log, the notice file
# data/supergrok_alert_notice.txt, and one ALERT line in today's eval inbox file.
# Never switches models. Thresholds: data/supergrok_pacing.json {"alerts":{...}}.
use strict;
use warnings;
use FindBin;
use Getopt::Long;
use HTTP::Tiny;
use JSON::PP;
use POSIX qw(strftime);

my ($inbox, $alert, $no_notify, $json_file, $data_dir, $base) = (0, 0, 0, undef, "$FindBin::Bin/../data", 'http://127.0.0.1:4006');
GetOptions('inbox' => \$inbox, 'alert' => \$alert, 'no-notify' => \$no_notify, 'json-file=s' => \$json_file,
           'data-dir=s' => \$data_dir, 'base=s' => \$base)
    or die "usage: $0 [--inbox] [--alert] [--no-notify] [--json-file F] [--data-dir D] [--base URL]\n";
$ENV{TZ} = 'America/Vancouver';
POSIX::tzset();

my $content;
if ($json_file) { open my $fh, '<', $json_file or die "$json_file: $!"; local $/; $content = <$fh>; close $fh }
else {
    my $r = HTTP::Tiny->new(timeout => 90)->get("$base/ai/usage_live");
    die "GET $base/ai/usage_live: $r->{status} $r->{reason}\n" unless $r->{success};
    $content = $r->{content};
}
my $d  = decode_json($content);
my $sp = $d->{org}{health}{supergrok_pacing} or die "no org.health.supergrok_pacing in response (operator access?)\n";
my @alerts = @{ $sp->{alerts} || [] };
my @lines = (
    map({ "ALERT: $_->{message}" } @alerts),
    sprintf('Super Grok %s%% used, %s%% left; cycle %s -> reset %s (%s days left)', @$sp{qw(used_pct left_pct cycle_start_pt reset_pt days_left)}),
    sprintf('Today: +%s points since %s', $sp->{day_rise_pct} // '?', $sp->{day_from_pt} // '?'),
    sprintf('Pace: %s (%s points vs %s%% expected). Daily target %s%%/day (~%s M tokens, ~%s grok-4.7 calls)',
        map { $_ // '?' } @$sp{qw(pace pace_delta expected_pct daily_target_pct daily_target_mtok daily_target_calls)}),
    sprintf('Calibration %s %%/M Hermes xai tokens; base %s%% at %s', $sp->{rate_pct_per_mtok}, $sp->{base_reading}{value}, $sp->{base_reading}{at_pt}),
    map({ "WARN: $_" } @{ $sp->{warnings} || [] }),
    map({ sprintf('JOB %d: %s (%s)', $_->{rank}, $_->{title}, $_->{why}) } @{ $sp->{jobs} || [] }),
);
print "$_\n" for @lines;

my $date = strftime('%Y-%m-%d', localtime);
my $now_pt = strftime('%a %b %d %H:%M PT', localtime);

sub write_inbox {
    my $report = {
        report_date => $date,
        source      => 'Super Grok pacing',
        created_by  => 'script/supergrok_pacing.pl',
        summary     => join(' ', @lines[0 .. (@alerts ? 1 : 2)]),
        metrics     => { supergrok_pacing => { map { ($_ => $sp->{$_}) } qw(used_pct left_pct expected_pct pace pace_delta daily_target_pct
                             daily_target_mtok daily_target_calls days_left rate_pct_per_mtok reset_pt endgame midweek_warning auto_queue
                             day_rise_pct used_day_start_pct) },
                         alerts => \@alerts, meter => $sp->{meter} },
        markdown    => "# Super Grok pacing $date\n\n" . join("\n", map { "- $_" } @lines) . "\n"
                     . ($sp->{meter}{stale} ? "\n**Meter reading needed:** $sp->{meter}{prompt} Form: /ai/usage#usage-estimator\n" : ''),
    };
    my $f = "$data_dir/ai_eval_inbox/$date-supergrok-pacing.json";
    mkdir "$data_dir/ai_eval_inbox" unless -d "$data_dir/ai_eval_inbox";
    open my $fh, '>', $f or die "write $f: $!";
    print $fh JSON::PP->new->canonical->pretty->encode($report);
    close $fh;
    print "wrote $f\n";
}

write_inbox() if $inbox && !$alert;
exit 0 unless $alert;

# ---- alert mode ----
my $cfg = do { my $t = ''; if (open my $fh, '<', "$data_dir/supergrok_pacing.json") { local $/; $t = <$fh> // ''; close $fh } (eval { decode_json($t) }) || {} };
my $renotify = ($cfg->{alerts} || {})->{renotify_pts} // 10;
my $state_f = "$data_dir/supergrok_alert_state.json";
my $st = do { my $t = ''; if (open my $fh, '<', $state_f) { local $/; $t = <$fh> // ''; close $fh } (eval { decode_json($t) }) || {} };
delete $st->{$_} for grep { $_ lt strftime('%Y-%m-%d', localtime(time - 7 * 86400)) } keys %$st;
my $today = $st->{$date} ||= {};

my @fire;
for my $a (@alerts) {
    my $prev = $today->{ $a->{kind} };
    next if $prev && ($a->{value} // 0) < ($prev->{value} // 0) + $renotify;
    push @fire, $a;
    $today->{ $a->{kind} } = { at => time, value => 0 + ($a->{value} // 0) };
}
if ($sp->{meter}{stale} && !$today->{meter_stale}) {
    push @fire, { kind => 'meter_stale', level => 'normal', message => $sp->{meter}{prompt} . ' Form: http://localhost:4006/ai/usage#usage-estimator' };
    $today->{meter_stale} = { at => time };
}

# Notice file always reflects the current alerts (empty file = none).
if (open my $nf, '>', "$data_dir/supergrok_alert_notice.txt") {
    print $nf @alerts ? join("\n", "$now_pt", map({ $_->{message} } @alerts), 'See http://localhost:4006/ai/usage#supergrok-pacing') . "\n" : '';
    close $nf;
}
unless (@fire) { print "alerts: nothing new\n"; exit 0 }

open my $lf, '>>', "$data_dir/supergrok_alerts.log";
for my $a (@fire) {
    my $how = 'log';
    unless ($no_notify) {
        my %env = %ENV;
        $env{DISPLAY} ||= ':0';
        my $bus = "/run/user/$</bus";
        $env{DBUS_SESSION_BUS_ADDRESS} ||= "unix:path=$bus" if -S $bus || -e $bus;
        my $urg = $a->{level} eq 'critical' ? 'critical' : 'normal';
        my $title = $a->{kind} eq 'meter_stale' ? 'Super Grok: meter reading needed' : 'Super Grok burn warning';
        my $rc = do { local %ENV = %env; system('notify-send', '--app-name', 'Super Grok pacing', '--urgency', $urg, $title,
                                                "$a->{message}\nhttp://localhost:4006/ai/usage#supergrok-pacing") };
        $how = $rc == 0 ? 'notify-send' : 'log (notify-send failed rc=' . ($rc >> 8) . ')';
    }
    my $line = "$now_pt [$a->{kind}] $a->{message} -> $how";
    print "$line\n";
    print $lf "$line\n" if $lf;
}
close $lf if $lf;
write_inbox() if grep { $_->{kind} ne 'meter_stale' } @fire or $inbox;
open my $sf, '>', "$state_f.tmp" or die "$state_f: $!";
print $sf JSON::PP->new->canonical->pretty->encode($st);
close $sf;
rename "$state_f.tmp", $state_f;

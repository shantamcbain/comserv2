#!/usr/bin/env perl
use strict;
use warnings;

# ─────────────────────────────────────────────────────────────────────────────
# hardware_monitor.pl — THIN TRIGGER (monitoring re-architecture, 2026-08-12)
#
# This script no longer connects to the database or collects metrics. The APP
# owns all of that (see Comserv::Controller::Admin::HardwareMonitor, `run`
# endpoint): it knows which DB is current, collects local hardware metrics,
# verifies DB liveness, runs a self test, records a heartbeat, and — on failure —
# writes a CRITICAL system_log entry via log_with_details so the error audit
# creates a [Error] todo + daily-priorities entry + admin email.
#
# This script only CURls the `run` endpoint on each candidate node. The first
# node that answers 200 wins. If NO node answers, that itself means the
# containers are down / the world can't see the app — and the only signal we can
# emit is this script's OWN stderr → root's cron mail (design A). We never
# touch the DB directly, so we can't write a system_log row when the app is dark.
# ─────────────────────────────────────────────────────────────────────────────

use POSIX qw(strftime);

sub _ts { strftime('%Y-%m-%d %H:%M:%S', localtime) }

# Candidate nodes, in priority order. Override via env (comma-separated URLs).
# IMPORTANT: these are REACHABLE node addresses, NOT localhost. The script runs
# on a separate host (proxmox720) and curls the app containers directly — the app
# has no concept of "localhost" on this host. The deploy pipeline writes the
# correct HW_MONITOR_NODES for each server; these fallbacks are only used if the
# env is unset. production1 -> 192.168.1.126:5000, workstation -> 192.168.1.199:5000.
# (No 127.0.0.1 — it would target this script host's own loopback, which is wrong.)
my @NODES = split /,/, ($ENV{HW_MONITOR_NODES}
    || 'http://192.168.1.126:5000/admin/hardware_monitor/run,'
    .  'http://192.168.1.199:5000/admin/hardware_monitor/run,'
    .  'http://192.168.1.198:5000/admin/hardware_monitor/run');

# The shared token. Every cron host and every container MUST use the IDENTICAL
# key, otherwise healthy nodes are falsely reported down. deploy.sh provisions it
# once on the NFS share (.../comserv_secrets/hw_ingest_token) — the same export
# every host mounts (workstation:/data/nfs, proxmox720:/mnt/nfs_data, etc.) plus
# a host-local copy. We scan candidate paths; if none yield a key we do NOT fall
# back to a guess — we exit 2 so the failure surfaces (cron mail + the script's
# own error reporting) instead of silently using a wrong key that would 403.
my @TOKEN_CANDIDATES = (
    $ENV{HW_INGEST_TOKEN} // '',
    '/usr/local/etc/comserv/hw_ingest_token',
    '/data/nfs/comserv_secrets/hw_ingest_token',
    '/mnt/nfs_data/comserv_secrets/hw_ingest_token',
);
my $token = '';
for my $c (@TOKEN_CANDIDATES) {
    next unless defined $c && length $c;
    my $t = $c;
    if (-f $c) {
        chomp($t = `cat '$c' 2>/dev/null`);
    }
    $t =~ s/^\s+|\s+$//g;
    if (length $t && $t ne 'changeme') { $token = $t; last; }
}

my $curl = `which curl 2>/dev/null`; chomp $curl;
unless ($curl && -x $curl) {
    print STDERR _ts() . " [hardware_monitor] FATAL: curl not found; cannot trigger app monitoring\n";
    exit 2;
}

unless (length $token && $token ne 'changeme') {
    print STDERR _ts() . " [hardware_monitor] FATAL: no shared monitoring token (looked in /usr/local/etc/comserv/hw_ingest_token, /data/nfs/comserv_secrets/hw_ingest_token, /mnt/nfs_data/comserv_secrets/hw_ingest_token, or \$HW_INGEST_TOKEN). Deploy must run once to provision it. Cannot authenticate to app nodes.\n";
    exit 2;
}

my ($ok_node, $http);
for my $url (@NODES) {
    $url =~ s/^\s+|\s+$//g;
    next unless $url;
    # Single-line command: the original split the args across multiple lines via
    # string concatenation, which under /bin/sh (dash, what cron uses) turns each
    # line into a separate shell command and fails with "Illegal option -H".
    my $cmd = "$curl -s -o /dev/null -w '%{http_code}' -X POST"
            . " -H 'Content-Type: application/json'"
            . " -H 'X-Ingest-Token: $token'"
            . " --connect-timeout 10 --max-time 45 '$url' 2>/dev/null";
    my $out = `$cmd`;
    chomp $out;
    if ($out eq '200') {
        $ok_node = $url;
        $http    = $out;
        last;
    }
    $http = $out;   # last attempted code, for diagnostics
}

if ($ok_node) {
    print _ts() . " [hardware_monitor] monitoring triggered via $ok_node (HTTP $http)\n";

    # Also trigger the logging-coverage audit on the same node (mirrors run): the
    # app scan (system_log grouping + code grep for silent error swallowing) writes
    # findings to the logging_audit table. Reuses the same token + node that just
    # answered, so it only fires when the app is actually up.
    (my $audit_url = $ok_node) =~ s{/admin/hardware_monitor/run\z}{/admin/logging_audit/run};
    if ($audit_url ne $ok_node) {
        my $acmd = "$curl -s -o /dev/null -w '%{http_code}' -X POST"
                 . " -H 'Content-Type: application/json'"
                 . " -H 'X-Ingest-Token: $token'"
                 . " --connect-timeout 10 --max-time 45 '$audit_url' 2>/dev/null";
        my $acode = `$acmd`; chomp $acode;
        print _ts() . " [hardware_monitor] logging audit triggered via $audit_url (HTTP $acode)\n";
    }
    exit 0;
}

# No node answered → containers down / app unreachable. This is the OUTAGE signal.
# Per design A: the ONLY channel available when the app is dark is this script's
# stderr → root@proxmox720 cron mail. The app cannot record it (no DB/auth).
print STDERR _ts() . " [hardware_monitor] CRITICAL: no application node reachable — app/monitoring DOWN. "
                   . "Tried: " . join(', ', @NODES) . " (last HTTP: " . ($http // 'none') . ")\n";
exit 1;

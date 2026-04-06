#!/usr/bin/env perl
use strict;
use warnings;
use LWP::UserAgent;
use HTML::LinkExtor;
use HTTP::Cookies;
use URI;
use URI::Escape;
use JSON;
use Getopt::Long;
use POSIX qw(strftime);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use FindBin qw($Bin);

# ============================================================
# Comserv Security Crawl Script
# Tests the site as an unauthenticated visitor to find:
#   - Links/URLs accessible without login that should be protected
#   - Data-modification endpoints reachable without auth
#   - Error responses that leak internal path/stack info
#   - Links visible in public pages pointing to private areas
# ============================================================

my $base_url    = 'http://localhost:3000';
my $sitename    = 'none';
my $verbose     = 0;
my $max_pages   = 200;
my $output_file = '';
my $archive_dir = '';
my $auth_cookie = '';   # when set, both UAs send this Cookie header (authenticated scan)

GetOptions(
    'url=s'         => \$base_url,
    'site=s'        => \$sitename,
    'verbose'       => \$verbose,
    'max=i'         => \$max_pages,
    'output=s'      => \$output_file,
    'archive-dir=s' => \$archive_dir,
    'auth-cookie=s' => \$auth_cookie,
) or die "Usage: $0 --url http://host:port [--site sitename] [--verbose] [--max N] [--output file.json] [--archive-dir dir] [--auth-cookie 'Cookie: ...']\n";

# Default archive dir next to the script: ../logs/security_scans/
$archive_dir ||= "$Bin/../logs/security_scans";
make_path($archive_dir) unless -d $archive_dir;

# Default live output file (overwritten each run for the poll endpoint)
$output_file ||= '/tmp/comserv_security_scan.json';

$base_url =~ s|/$||;

my $auth_mode = $auth_cookie ? 'AUTHENTICATED' : 'UNAUTHENTICATED';

print "=" x 60 . "\n";
print "Comserv Security Crawl\n";
print "Target: $base_url  Site: $sitename  Mode: $auth_mode\n";
print "=" x 60 . "\n\n";

# Two separate cookie jars / agents.
# When --auth-cookie is supplied both UAs run as the logged-in user so we can
# see what that role can access.  Without it both are fully unauthenticated.
# The crawl UA optionally sends X-Sitename; the probe UA does not (simulates
# a real browser hitting the route via Host header only).
my $crawl_jar = HTTP::Cookies->new;
my $probe_jar = HTTP::Cookies->new;

my $ua = LWP::UserAgent->new(
    cookie_jar   => $crawl_jar,
    max_redirect => 5,
    timeout      => 15,
    agent        => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36',
);

my $probe_ua = LWP::UserAgent->new(
    cookie_jar   => $probe_jar,
    max_redirect => 5,
    timeout      => 15,
    agent        => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36',
);

# Inject session cookie into both UAs when running in authenticated mode
if ($auth_cookie) {
    $ua->default_header('Cookie'       => $auth_cookie);
    $probe_ua->default_header('Cookie' => $auth_cookie);
    print "  [AUTH] Running as authenticated user (session cookie injected)\n\n";
}

# Site header: only sent by crawl UA, and only when --site is a real site name
my @site_hdr = ($sitename && $sitename ne 'none') ? ('X-Sitename' => $sitename) : ();

# Known sensitive path patterns — any 200 response here is a finding
my @SENSITIVE_PATTERNS = (
    qr|/admin|i,
    qr|/setup|i,
    qr|/debug|i,
    qr|/log/|i,
    qr|/project/addproject|i,
    qr|/project/create|i,
    qr|/project/edit|i,
    qr|/project/update|i,
    qr|/project/project|i,
    qr|/project/details|i,
    qr|/ENCY/add|i,
    qr|/ENCY/edit|i,
    qr|/site/add|i,
    qr|/site/delete|i,
    qr|/site/modify|i,
    qr|/Documentation/Setup|i,
    qr|/Documentation/Forager|i,
    qr|/proxmox|i,
    qr|/proxmox_servers|i,
    qr|/remotedb|i,
    qr|/file/admin|i,
    qr|/file/edit|i,
    qr|/file/rename|i,
    qr|/workshop/edit|i,
    qr|/workshop/delete|i,
    qr|/workshop/publish|i,
    qr|/ai/admin|i,
    qr|/ApiCredentials|,
    qr|/navigation/manage|i,
    qr|/docker|i,
    qr|/user/admin|i,
);

# POST endpoints that should reject unauthenticated requests
my @SENSITIVE_POST_ENDPOINTS = (
    '/project/create_project',
    '/project/update_project',
    '/ENCY/add_herb',
    '/ENCY/edit_herb',
    '/site/add_site',
    '/site/add_domain',
    '/site/delete',
    '/site/modify',
    '/log/update',
    '/log/details',
    '/admin/docker-restart/web-prod',
    '/admin/docker-stop/web-prod',
    '/admin/docker-list',
    '/admin/docker-save-image',
    '/admin/docker-deploy-to-production',
    '/setup',
    '/remotedb/add',
    '/remotedb/remove/test',
    '/remotedb/query/test',
    # /workshop/addworkshop is intentionally public (workshop leaders submit proposals)
);

my %visited;
my @queue     = ({ url => $base_url . '/', from_url => '' });
my @findings  = ();
my $page_count = 0;

# ---- helper ----
sub classify_response {
    my ($url, $resp) = @_;
    my $code    = $resp->code;
    my $body    = $resp->decoded_content // '';
    my $final   = $resp->request->uri->as_string;

    my %finding = (url => $url, status => $code, final_url => $final);

    # Redirected to login = protected (good)
    if ($final =~ m{/user/login|/login} && $code == 200) {
        $finding{result} = 'PROTECTED';
        return \%finding;
    }

    # 404 = not found (neutral)
    if ($code == 404) {
        $finding{result} = 'NOT_FOUND';
        return \%finding;
    }

    # 403 = forbidden (good)
    if ($code == 403) {
        $finding{result} = 'FORBIDDEN';
        return \%finding;
    }

    # Connection failure (LWP-generated 5xx, not a real server response)
    if ($code >= 500) {
        my $message = $resp->message // '';
        if ($message =~ /Can't connect|connect.*(?:failed|refused|timeout)|Bad hostname|Name or service not known|resolution failed/i
            || !$resp->header('content-type'))
        {
            $finding{result} = 'CONNECT_FAIL';
            $finding{detail} = $message;
            return \%finding;
        }
    }

    # 500 with stack trace = information disclosure
    if ($code == 500) {
        if ($body =~ /at \/opt\/comserv|Comserv::Controller|DBIx::Class|stack trace/i) {
            $finding{result}  = 'LEAK_STACK_TRACE';
            $finding{snippet} = substr($body, 0, 300);
        } else {
            $finding{result} = 'SERVER_ERROR';
        }
        return \%finding;
    }

    # 200 on a sensitive URL = potential exposure
    if ($code == 200) {
        for my $pat (@SENSITIVE_PATTERNS) {
            if ($url =~ $pat) {
                $finding{result} = 'EXPOSED_SENSITIVE';
                return \%finding;
            }
        }
        $finding{result} = 'OK_PUBLIC';
        return \%finding;
    }

    $finding{result} = "HTTP_$code";
    return \%finding;
}

sub extract_links {
    my ($base, $html) = @_;
    my @links;
    my $p = HTML::LinkExtor->new(sub {
        my ($tag, %attr) = @_;
        return unless $tag =~ /^(a|form)$/i;
        my $href = $attr{href} || $attr{action} || '';
        return unless $href;
        return if $href =~ /^(mailto:|javascript:|#)/i;
        my $abs = URI->new_abs($href, $base)->as_string;
        push @links, $abs if $abs =~ /^\Q$base_url\E/;
    });
    $p->parse($html);
    return @links;
}

# ============================================================
# Phase 1: Crawl as unauthenticated visitor
# ============================================================
print "[Phase 1] Crawling as unauthenticated visitor...\n";

while (@queue && $page_count < $max_pages) {
    my $item     = shift @queue;
    my $url      = $item->{url};
    my $from_url = $item->{from_url} // '';
    next if $visited{$url}++;
    $page_count++;

    my $resp = $ua->get($url, @site_hdr);
    my $finding = classify_response($url, $resp);

    push @findings, { phase => 'crawl', from_url => $from_url, %$finding };

    my $icon = $finding->{result} =~ /EXPOSED|LEAK/ ? '!!' :
               $finding->{result} eq 'PROTECTED'    ? 'ok' :
               $finding->{result} eq 'NOT_FOUND'    ? '  ' : '--';
    printf "  %s [%s] %-60s => %s\n", $icon, $resp->code, $url, $finding->{result};

    # Only extract links from pages that were NOT redirected elsewhere.
    # If the final URL differs from requested URL the page redirected (e.g. to login).
    # Following links from the login page would just re-queue login/home links.
    my $final_url = $resp->request->uri->as_string;
    my $redirected = ($final_url ne $url && $final_url ne "$url/");
    if ($resp->code == 200 && $resp->content_type =~ /html/ && !$redirected) {
        my @links = extract_links($url, $resp->decoded_content // '');
        my $new_count = 0;
        for my $link (@links) {
            unless ($visited{$link}) {
                push @queue, { url => $link, from_url => $url };
                $new_count++;
            }
        }
        printf "       -> queued %d new links (queue depth: %d)\n", $new_count, scalar @queue
            if $new_count > 0;
    }
}

print "  Crawled $page_count pages, found " . scalar(grep { $_->{result} =~ /EXPOSED|LEAK/ } @findings) . " issues.\n";
print "\n" . "=" x 60 . "\n";

# ============================================================
# Phase 2: Directly probe sensitive GET endpoints
# (uses probe_ua — fresh empty cookie jar = truly unauthenticated.
#  X-Sitename sent so Root.pm can route correctly; authentication
#  state is determined solely by the cookie jar, not the site header.)
# ============================================================
print "[Phase 2] Probing known sensitive GET endpoints (unauthenticated — fresh session)...\n";

my @SENSITIVE_GET = (
    '/admin',
    '/admin/users',
    '/admin/docker-list',
    '/admin/settings',
    '/admin/logs',
    '/admin/backup',
    '/admin/planning',
    '/log/',
    '/log/details',
    '/debug',
    '/setup',
    '/proxmox',
    '/proxmox_servers',
    '/remotedb',
    '/remotedb/add',
    '/project/project',
    '/project/details',
    '/project/addproject',
    '/project/editproject',
    '/ENCY/edit_herb',
    '/ENCY/add_herb',
    '/site/add_site',
    '/site/add_site_form',
    '/site/modify',
    '/file/admin_browser',
    '/file/edit/1',
    '/Documentation/Setup',
    '/Documentation/SetupController',
    '/ai/admin/models',
    '/ApiCredentials',
    '/navigation/manage',
);

for my $path (@SENSITIVE_GET) {
    my $url = $base_url . $path;
    next if $visited{$url};
    my $resp = $probe_ua->get($url, @site_hdr);
    my $finding = classify_response($url, $resp);
    $finding->{phase} = 'probe_get';

    my $icon = $finding->{result} =~ /EXPOSED|LEAK/ ? '!!' :
               $finding->{result} eq 'PROTECTED'    ? 'ok' : '--';
    printf "  %s [%s] %-50s => %s\n", $icon, $resp->code, $path, $finding->{result};

    push @findings, $finding;
}

print "\n" . "=" x 60 . "\n";

# ============================================================
# Phase 3: Probe sensitive POST endpoints with dummy data
# (probe_ua — fresh empty cookie jar = unauthenticated)
# ============================================================
print "[Phase 3] Probing sensitive POST endpoints (unauthenticated — fresh session)...\n";

for my $path (@SENSITIVE_POST_ENDPOINTS) {
    my $url = $base_url . $path;
    my $resp = $probe_ua->post($url,
        @site_hdr,
        Content => [name => 'test', client_name => 'test', project_id => '1', record_id => '1'],
    );
    my $code  = $resp->code;
    my $final = $resp->request->uri->as_string;
    my $result;

    if ($final =~ m{/user/login|/login}) {
        $result = 'PROTECTED';
    } elsif ($code == 403) {
        $result = 'FORBIDDEN';
    } elsif ($code == 500) {
        $result = 'SERVER_ERROR';
    } elsif ($code =~ /^2/) {
        $result = 'EXPOSED_POST_ACCEPTED';
    } else {
        $result = "HTTP_$code";
    }

    my $icon = $result =~ /EXPOSED/ ? '!!' :
               $result eq 'PROTECTED' ? 'ok' : '--';
    printf "  %s [%s] %-50s => %s\n", $icon, $code, $path, $result;

    push @findings, { phase => 'probe_post', url => $url, status => $code, result => $result, final_url => $final }
        unless $result eq 'NOT_FOUND';
}

print "\n" . "=" x 60 . "\n";

# ============================================================
# Phase 4: Check public pages for links to private areas
# (probe_ua — fresh empty cookie jar = unauthenticated public view)
# ============================================================
print "[Phase 4] Checking public pages for leaking private links (unauthenticated)...\n";

my @PUBLIC_PAGES = ('/', '/ENCY', '/ENCY/BeePastureView', '/ENCY/BotanicalNameView',
                    '/workshop', '/HelpDesk', '/WeaverBeck', '/MCoop', '/3d', '/CSC');

for my $path (@PUBLIC_PAGES) {
    my $url  = $base_url . $path;
    my $resp = $probe_ua->get($url, @site_hdr);
    next unless $resp->code == 200 && $resp->content_type =~ /html/;

    my @links   = extract_links($url, $resp->decoded_content // '');
    my @exposed = grep { my $l = $_; grep { $l =~ $_ } @SENSITIVE_PATTERNS } @links;

    if (@exposed) {
        printf "  !! Public page %s leaks %d private link(s):\n", $path, scalar @exposed;
        for my $l (@exposed) {
            print "       $l\n";
            push @findings, { phase => 'link_leak', url => $url, leaked_link => $l, result => 'LINK_LEAK' };
        }
    } else {
        print "  ok $path — no private links visible\n" if $verbose;
    }
}

print "\n" . "=" x 60 . "\n";

# ============================================================
# Summary
# ============================================================
my @critical  = grep { $_->{result} =~ /EXPOSED|LEAK/i } @findings;
my @protected = grep { $_->{result} eq 'PROTECTED' } @findings;
my @errors    = grep { $_->{result} eq 'SERVER_ERROR' } @findings;
my @conn_fail = grep { $_->{result} eq 'CONNECT_FAIL' } @findings;

print "=" x 60 . "\n";
print "SUMMARY\n";
print "=" x 60 . "\n";
printf "  Total URLs tested : %d\n", scalar @findings;
printf "  PROTECTED (good)  : %d\n", scalar @protected;
printf "  EXPOSED/LEAK (BAD): %d\n", scalar @critical;
printf "  Server errors     : %d\n", scalar @errors;
printf "  Connect failures  : %d\n", scalar @conn_fail if @conn_fail;
if (@conn_fail) {
    print "\n  NOTE: Connect failures mean the target host is unreachable (bad hostname or not running).\n";
    print "  Use a hostname from /etc/hosts or check the server is up.\n";
}

if (@critical) {
    print "\nCRITICAL FINDINGS:\n";
    for my $f (@critical) {
        printf "  [%s] %s\n", $f->{result}, $f->{url} // $f->{leaked_link};
    }
}

# Build the report payload
my $ts_iso  = strftime('%Y-%m-%dT%H:%M:%S', localtime);
my $ts_file = strftime('%Y-%m-%d_%H-%M-%S', localtime);
my $host    = $base_url; $host =~ s|https?://||; $host =~ s|[:/]|_|g;

my %report = (
    scan_time => $ts_iso,
    base_url  => $base_url,
    sitename  => $sitename,
    auth_mode => $auth_mode,
    summary   => {
        total        => scalar @findings,
        exposed      => scalar @critical,
        protected    => scalar @protected,
        errors       => scalar @errors,
        connect_fail => scalar @conn_fail,
    },
    findings => \@findings,
);
my $json_text = encode_json(\%report);

# Write live file (overwritten each run — used by poll endpoint)
if (open my $fh, '>', $output_file) {
    print $fh $json_text;
    close $fh;
    print "\nLive report written to: $output_file\n";
} else {
    warn "Cannot write $output_file: $!";
}

# Write timestamped archive (never overwritten — permanent history)
my $archive_file = "$archive_dir/${ts_file}_${host}.json";
if (open my $af, '>', $archive_file) {
    print $af $json_text;
    close $af;
    print "Archive report written to: $archive_file\n";
} else {
    warn "Cannot write archive $archive_file: $!";
}

print "Full report written to: $output_file\n";
print "=" x 60 . "\n";

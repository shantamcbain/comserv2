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
my $output_file = 'security_crawl_report.json';

GetOptions(
    'url=s'     => \$base_url,
    'site=s'    => \$sitename,
    'verbose'   => \$verbose,
    'max=i'     => \$max_pages,
    'output=s'  => \$output_file,
) or die "Usage: $0 --url http://host:port [--site sitename] [--verbose] [--max N] [--output file.json]\n";

$base_url =~ s|/$||;

print "=" x 60 . "\n";
print "Comserv Security Crawl\n";
print "Target: $base_url  Site: $sitename\n";
print "=" x 60 . "\n\n";

my $jar = HTTP::Cookies->new;
my $ua  = LWP::UserAgent->new(
    cookie_jar        => $jar,
    max_redirect      => 5,
    timeout           => 15,
    agent             => 'ComservSecurityScanner/1.0',
);

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
    qr|/api_credentials|i,
    qr|/navigation/manage|i,
    qr|/docker|i,
    qr|/user/admin|i,
    qr|/shanta|i,
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
    '/workshop/addworkshop',
);

my %visited;
my @queue     = ($base_url . '/');
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
    my $url = shift @queue;
    next if $visited{$url}++;
    $page_count++;

    print "  GET $url\n" if $verbose;

    my $resp = $ua->get($url, 'X-Sitename' => $sitename);
    my $finding = classify_response($url, $resp);

    if ($finding->{result} ne 'OK_PUBLIC' && $finding->{result} ne 'NOT_FOUND') {
        push @findings, { phase => 'crawl', %$finding };
        my $icon = $finding->{result} =~ /EXPOSED|LEAK/ ? '!!' : '--';
        printf "  %s [%s] %s => %s\n", $icon, $resp->code, $url, $finding->{result};
    }

    # Extract links only from public pages
    if ($resp->code == 200 && $resp->content_type =~ /html/) {
        my @links = extract_links($url, $resp->decoded_content // '');
        for my $link (@links) {
            push @queue, $link unless $visited{$link};
        }
    }
}

print "  Crawled $page_count pages, found " . scalar(grep { $_->{result} =~ /EXPOSED|LEAK/ } @findings) . " issues.\n\n";

# ============================================================
# Phase 2: Directly probe sensitive GET endpoints
# ============================================================
print "[Phase 2] Probing known sensitive GET endpoints...\n";

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
    '/api_credentials',
    '/navigation/manage',
    '/shanta/dashboard',
);

for my $path (@SENSITIVE_GET) {
    my $url = $base_url . $path;
    next if $visited{$url};
    my $resp = $ua->get($url, 'X-Sitename' => $sitename);
    my $finding = classify_response($url, $resp);
    $finding->{phase} = 'probe_get';

    my $icon = $finding->{result} =~ /EXPOSED|LEAK/ ? '!!' :
               $finding->{result} eq 'PROTECTED'    ? 'ok' : '--';
    printf "  %s [%s] %-50s => %s\n", $icon, $resp->code, $path, $finding->{result};

    push @findings, $finding
        unless $finding->{result} eq 'NOT_FOUND';
}

print "\n";

# ============================================================
# Phase 3: Probe sensitive POST endpoints with dummy data
# ============================================================
print "[Phase 3] Probing sensitive POST endpoints...\n";

for my $path (@SENSITIVE_POST_ENDPOINTS) {
    my $url = $base_url . $path;
    my $resp = $ua->post($url,
        'X-Sitename' => $sitename,
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

print "\n";

# ============================================================
# Phase 4: Check public pages for links to private areas
# ============================================================
print "[Phase 4] Checking public pages for leaking private links...\n";

my @PUBLIC_PAGES = ('/', '/ENCY', '/ENCY/BeePastureView', '/ENCY/BotanicalNameView',
                    '/workshop', '/HelpDesk', '/WeaverBeck', '/MCoop', '/3d', '/CSC');

for my $path (@PUBLIC_PAGES) {
    my $url  = $base_url . $path;
    my $resp = $ua->get($url, 'X-Sitename' => $sitename);
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

print "\n";

# ============================================================
# Summary
# ============================================================
my @critical = grep { $_->{result} =~ /EXPOSED|LEAK/i } @findings;
my @protected = grep { $_->{result} eq 'PROTECTED' } @findings;
my @errors   = grep { $_->{result} eq 'SERVER_ERROR' } @findings;

print "=" x 60 . "\n";
print "SUMMARY\n";
print "=" x 60 . "\n";
printf "  Total URLs tested : %d\n", scalar @findings;
printf "  PROTECTED (good)  : %d\n", scalar @protected;
printf "  EXPOSED/LEAK (BAD): %d\n", scalar @critical;
printf "  Server errors     : %d\n", scalar @errors;

if (@critical) {
    print "\nCRITICAL FINDINGS:\n";
    for my $f (@critical) {
        printf "  [%s] %s\n", $f->{result}, $f->{url} // $f->{leaked_link};
    }
}

# Write JSON report
open my $fh, '>', $output_file or warn "Cannot write $output_file: $!";
print $fh encode_json({
    scan_time => scalar localtime,
    base_url  => $base_url,
    sitename  => $sitename,
    summary   => {
        total    => scalar @findings,
        exposed  => scalar @critical,
        protected => scalar @protected,
        errors   => scalar @errors,
    },
    findings => \@findings,
});
close $fh;

print "\nFull report written to: $output_file\n";
print "=" x 60 . "\n";

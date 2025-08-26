#!/usr/bin/env perl

use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use Data::Dumper;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Util::CloudflareManager;

# Configuration
my $domains = [
    'computersystemconsulting.ca',
    'beemaster.ca'
];

# The API token from the configuration
my $api_token = 'cXPhJ9FFvNI6XcV7Xf-TxVI_IDC2zdlVPePa_n5w';

# Create a user agent
my $ua = LWP::UserAgent->new;
$ua->timeout(30);

# Create a CloudflareManager instance to use its caching functionality
my $manager = Comserv::Util::CloudflareManager->new();

print "Fetching DNS records for domains...\n";

foreach my $domain (@$domains) {
    print "\n=== Processing domain: $domain ===\n";
    
    # Step 1: Get zone ID
    my $zone_id = get_zone_id($domain);
    unless ($zone_id) {
        print "ERROR: Could not get zone ID for domain $domain. Skipping.\n";
        next;
    }
    
    # Step 2: Get DNS records
    my $dns_records = get_dns_records($zone_id);
    unless ($dns_records) {
        print "ERROR: Could not get DNS records for domain $domain. Skipping.\n";
        next;
    }
    
    # Step 3: Cache the DNS records
    cache_dns_records($domain, $dns_records);
}

print "\n=== All domains processed ===\n";

# Function to get zone ID for a domain
sub get_zone_id {
    my ($domain) = @_;
    
    print "Getting zone ID for domain $domain...\n";
    
    # First check if we have a hardcoded zone ID
    my %known_zones = (
        'computersystemconsulting.ca' => '589fee264de80c4a1f2ac27b77718e96',
        'beemaster.ca' => '589fee264de80c4a1f2ac27b77718e96',
    );
    
    if (exists $known_zones{$domain}) {
        my $zone_id = $known_zones{$domain};
        print "Using hardcoded zone ID for domain $domain: $zone_id\n";
        return $zone_id;
    }
    
    # If not, try to get it from the API
    my $zones_req = HTTP::Request->new(GET => 'https://api.cloudflare.com/client/v4/zones?name=' . $domain);
    $zones_req->header('Authorization' => "Bearer $api_token");
    $zones_req->header('Content-Type' => 'application/json');
    
    my $zones_res = $ua->request($zones_req);
    print "Response Status: " . $zones_res->status_line . "\n";
    
    if ($zones_res->is_success) {
        my $zones_data = decode_json($zones_res->content);
        if ($zones_data->{success} && $zones_data->{result} && @{$zones_data->{result}}) {
            my $zone_id = $zones_data->{result}->[0]->{id};
            print "Found Zone ID for $domain: $zone_id\n";
            return $zone_id;
        }
    }
    
    # If we couldn't get the zone ID from the API, try to list all zones
    print "Trying to list all accessible zones...\n";
    my $all_zones_req = HTTP::Request->new(GET => 'https://api.cloudflare.com/client/v4/zones');
    $all_zones_req->header('Authorization' => "Bearer $api_token");
    $all_zones_req->header('Content-Type' => 'application/json');
    
    my $all_zones_res = $ua->request($all_zones_req);
    print "Response Status: " . $all_zones_res->status_line . "\n";
    
    if ($all_zones_res->is_success) {
        my $all_zones_data = decode_json($all_zones_res->content);
        if ($all_zones_data->{success} && $all_zones_data->{result} && @{$all_zones_data->{result}}) {
            foreach my $zone (@{$all_zones_data->{result}}) {
                if ($zone->{name} eq $domain) {
                    my $zone_id = $zone->{id};
                    print "Found Zone ID for $domain: $zone_id\n";
                    return $zone_id;
                }
            }
        }
    }
    
    return undef;
}

# Function to get DNS records for a zone
sub get_dns_records {
    my ($zone_id) = @_;
    
    print "Getting DNS records for zone ID $zone_id...\n";
    
    my $dns_req = HTTP::Request->new(GET => "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records");
    $dns_req->header('Authorization' => "Bearer $api_token");
    $dns_req->header('Content-Type' => 'application/json');
    
    my $dns_res = $ua->request($dns_req);
    print "Response Status: " . $dns_res->status_line . "\n";
    
    if ($dns_res->is_success) {
        my $dns_data = decode_json($dns_res->content);
        if ($dns_data->{success} && $dns_data->{result}) {
            print "Successfully retrieved " . scalar(@{$dns_data->{result}}) . " DNS records\n";
            return $dns_data->{result};
        }
    }
    
    print "ERROR: Failed to get DNS records: " . $dns_res->status_line . "\n";
    print "Response Content: " . $dns_res->content . "\n";
    return undef;
}

# Function to cache DNS records
sub cache_dns_records {
    my ($domain, $records) = @_;
    
    print "Caching " . scalar(@$records) . " DNS records for domain $domain...\n";
    
    # Create cache directory
    my $cache_dir = "/tmp/comserv_cloudflare_cache/$domain";
    make_path($cache_dir) unless -d $cache_dir;
    
    # Write records to cache file
    my $cache_file = "$cache_dir/dns_records.json";
    open my $fh, '>', $cache_file or die "Could not open cache file: $!";
    print $fh encode_json($records);
    close $fh;
    
    print "DNS records cached to $cache_file\n";
    
    # Also use the CloudflareManager's caching method
    $manager->_cache_dns_records($domain, $records);
    
    return 1;
}
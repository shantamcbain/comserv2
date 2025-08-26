 #!/usr/bin/env perl

use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use Data::Dumper;

# The API key from the configuration
my $api_key = "2d95c4933bc217d6b44c8a2c0896e9e4c0d6c";
my $email = 'shantamcbain@gmail.com';
my $domain = "computersystemconsulting.ca";

print "Testing Cloudflare API for domain: $domain\n";
print "API Key: $api_key\n";
print "Email: $email\n";

# Create a user agent
my $ua = LWP::UserAgent->new;
$ua->timeout(30);

# Step 1: List zones to find the zone ID for the domain
print "\n=== Step 1: List Zones ===\n";
my $zones_req = HTTP::Request->new(GET => 'https://api.cloudflare.com/client/v4/zones?name=' . $domain);
$zones_req->header('X-Auth-Email' => $email);
$zones_req->header('X-Auth-Key' => $api_key);
$zones_req->header('Content-Type' => 'application/json');

my $zones_res = $ua->request($zones_req);
print "Response Status: " . $zones_res->status_line . "\n";
print "Response Content: " . substr($zones_res->content, 0, 200) . "...\n";

my $zone_id = '';
if ($zones_res->is_success) {
    my $zones_data = decode_json($zones_res->content);
    if ($zones_data->{success} && $zones_data->{result} && @{$zones_data->{result}}) {
        $zone_id = $zones_data->{result}->[0]->{id};
        print "Found Zone ID for $domain: $zone_id\n";
    } else {
        print "ERROR: Could not find zone ID for domain $domain\n";
        print "Response Content: " . $zones_res->content . "\n";
        
        # Try to list all zones the API key has access to
        print "\n=== Listing All Accessible Zones ===\n";
        my $all_zones_req = HTTP::Request->new(GET => 'https://api.cloudflare.com/client/v4/zones');
        $all_zones_req->header('X-Auth-Email' => $email);
        $all_zones_req->header('X-Auth-Key' => $api_key);
        $all_zones_req->header('Content-Type' => 'application/json');
        
        my $all_zones_res = $ua->request($all_zones_req);
        print "Response Status: " . $all_zones_res->status_line . "\n";
        
        if ($all_zones_res->is_success) {
            my $all_zones_data = decode_json($all_zones_res->content);
            if ($all_zones_data->{success} && $all_zones_data->{result} && @{$all_zones_data->{result}}) {
                print "Accessible zones:\n";
                foreach my $zone (@{$all_zones_data->{result}}) {
                    print "  - " . $zone->{name} . " (ID: " . $zone->{id} . ")\n";
                    # If we find the domain we're looking for, use its zone ID
                    if ($zone->{name} eq $domain) {
                        $zone_id = $zone->{id};
                        print "Found Zone ID for $domain: $zone_id\n";
                    }
                }
            } else {
                print "No zones accessible with this API key.\n";
            }
        } else {
            print "Failed to list accessible zones: " . $all_zones_res->status_line . "\n";
            print "Response Content: " . $all_zones_res->content . "\n";
        }
        
        if (!$zone_id) {
            exit 1;
        }
    }
} else {
    print "ERROR: Failed to list zones: " . $zones_res->status_line . "\n";
    print "Response Content: " . $zones_res->content . "\n";
    
    # Try to list all zones the API key has access to
    print "\n=== Listing All Accessible Zones ===\n";
    my $all_zones_req = HTTP::Request->new(GET => 'https://api.cloudflare.com/client/v4/zones');
    $all_zones_req->header('X-Auth-Email' => $email);
    $all_zones_req->header('X-Auth-Key' => $api_key);
    $all_zones_req->header('Content-Type' => 'application/json');
    
    my $all_zones_res = $ua->request($all_zones_req);
    print "Response Status: " . $all_zones_res->status_line . "\n";
    
    if ($all_zones_res->is_success) {
        my $all_zones_data = decode_json($all_zones_res->content);
        if ($all_zones_data->{success} && $all_zones_data->{result} && @{$all_zones_data->{result}}) {
            print "Accessible zones:\n";
            foreach my $zone (@{$all_zones_data->{result}}) {
                print "  - " . $zone->{name} . " (ID: " . $zone->{id} . ")\n";
                # If we find the domain we're looking for, use its zone ID
                if ($zone->{name} eq $domain) {
                    $zone_id = $zone->{id};
                    print "Found Zone ID for $domain: $zone_id\n";
                }
            }
        } else {
            print "No zones accessible with this API key.\n";
        }
    } else {
        print "Failed to list accessible zones: " . $all_zones_res->status_line . "\n";
        print "Response Content: " . $all_zones_res->content . "\n";
        exit 1;
    }
}

# Step 2: List DNS records for the zone
if ($zone_id) {
    print "\n=== Step 2: List DNS Records ===\n";
    my $dns_req = HTTP::Request->new(GET => "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records");
    $dns_req->header('X-Auth-Email' => $email);
    $dns_req->header('X-Auth-Key' => $api_key);
    $dns_req->header('Content-Type' => 'application/json');
    
    my $dns_res = $ua->request($dns_req);
    print "Response Status: " . $dns_res->status_line . "\n";
    
    if ($dns_res->is_success) {
        my $dns_data = decode_json($dns_res->content);
        if ($dns_data->{success} && $dns_data->{result}) {
            print "Successfully retrieved DNS records!\n";
            print "Number of records: " . scalar(@{$dns_data->{result}}) . "\n";
            
            # Print the first few records
            my $count = 0;
            foreach my $record (@{$dns_data->{result}}) {
                last if $count >= 5; # Only show first 5 records
                print "  - " . $record->{type} . " " . $record->{name} . " -> " . $record->{content} . "\n";
                $count++;
            }
            if (scalar(@{$dns_data->{result}}) > 5) {
                print "  ... and " . (scalar(@{$dns_data->{result}}) - 5) . " more records\n";
            }
        } else {
            print "Failed to retrieve DNS records: " . ($dns_data->{errors}->[0]->{message} || "Unknown error") . "\n";
            print "Response Content: " . $dns_res->content . "\n";
        }
    } else {
        print "ERROR: Failed to retrieve DNS records: " . $dns_res->status_line . "\n";
        print "Response Content: " . $dns_res->content . "\n";
    }
}

print "\n=== Test Complete ===\n";
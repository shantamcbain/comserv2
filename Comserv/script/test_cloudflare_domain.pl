#!/usr/bin/env perl

use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use Data::Dumper;
use Getopt::Long;

# Parse command line arguments
my $api_token = "cXPhJ9FFvNI6XcV7Xf-TxVI_IDC2zdlVPePa_n5w";  # Default token
my $domain = "computersystemconsulting.ca";  # Default domain
my $config_file = "";
my $help = 0;

GetOptions(
    "token=s" => \$api_token,
    "domain=s" => \$domain,
    "config=s" => \$config_file,
    "help" => \$help
);

# Show help if requested
if ($help) {
    print <<EOF;
Usage: $0 [options]

Options:
  --token=TOKEN    Use the specified API token instead of the default
  --domain=DOMAIN  Test with the specified domain instead of the default
  --config=FILE    Read the API token from the specified config file
  --help           Show this help message

Examples:
  $0
  $0 --token=your_api_token_here
  $0 --domain=example.com
  $0 --config=/path/to/cloudflare_config.json

EOF
    exit 0;
}

# Read token from config file if specified
if ($config_file && -f $config_file) {
    print "Reading API token from config file: $config_file\n";
    open my $fh, '<', $config_file or die "Could not open config file: $!";
    my $json = do { local $/; <$fh> };
    close $fh;
    
    my $config = decode_json($json);
    if ($config->{cloudflare} && $config->{cloudflare}->{api_token}) {
        $api_token = $config->{cloudflare}->{api_token};
        print "Found API token in config file.\n";
    } else {
        print "WARNING: Could not find API token in config file. Using default token.\n";
    }
}

# Trim any whitespace
$api_token =~ s/^\s+|\s+$//g;

print "\n=== Testing Cloudflare API ===\n";
print "Domain: $domain\n";
print "API Token: " . substr($api_token, 0, 4) . "..." . substr($api_token, -4) . " (masked for security)\n";

# Create a user agent
my $ua = LWP::UserAgent->new;
$ua->timeout(30);

# Step 1: Verify the token
print "\n=== Step 1: Verify API Token ===\n";
my $verify_req = HTTP::Request->new(GET => 'https://api.cloudflare.com/client/v4/user/tokens/verify');
$verify_req->header('Authorization' => "Bearer $api_token");
$verify_req->header('Content-Type' => 'application/json');

print "Making request to verify token...\n";
my $verify_res = $ua->request($verify_req);
print "Response Status: " . $verify_res->status_line . "\n";

if ($verify_res->is_success) {
    my $result = decode_json($verify_res->content);
    if ($result->{success}) {
        print "✓ Token is valid and active!\n";
        if ($result->{result} && $result->{result}->{id}) {
            print "Token ID: " . $result->{result}->{id} . "\n";
        }
    } else {
        print "✗ Token verification failed: " . ($result->{errors}->[0]->{message} || "Unknown error") . "\n";
        print "Response Content: " . $verify_res->content . "\n";
        print "\nPlease create a new API token following the instructions in the documentation:\n";
        print "/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/cloudflare_api_token_guide.tt\n";
        exit 1;
    }
} else {
    print "✗ Request failed: " . $verify_res->status_line . "\n";
    print "Response Content: " . $verify_res->content . "\n";
    print "\nPlease create a new API token following the instructions in the documentation:\n";
    print "/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/cloudflare_api_token_guide.tt\n";
    exit 1;
}

# Step 2: Get zone ID for the domain
print "\n=== Step 2: Get Zone ID for $domain ===\n";
my $zones_req = HTTP::Request->new(GET => 'https://api.cloudflare.com/client/v4/zones?name=' . $domain);
$zones_req->header('Authorization' => "Bearer $api_token");
$zones_req->header('Content-Type' => 'application/json');

print "Making request to get zone ID...\n";
my $zones_res = $ua->request($zones_req);
print "Response Status: " . $zones_res->status_line . "\n";

my $zone_id = '';
if ($zones_res->is_success) {
    my $zones_data = decode_json($zones_res->content);
    if ($zones_data->{success} && $zones_data->{result} && @{$zones_data->{result}}) {
        $zone_id = $zones_data->{result}->[0]->{id};
        print "✓ Found Zone ID for $domain: $zone_id\n";
    } else {
        print "✗ Could not find zone ID for domain $domain\n";
        print "Response Content: " . $zones_res->content . "\n";
        
        # Try to list all zones the token has access to
        print "\n=== Listing All Accessible Zones ===\n";
        my $all_zones_req = HTTP::Request->new(GET => 'https://api.cloudflare.com/client/v4/zones');
        $all_zones_req->header('Authorization' => "Bearer $api_token");
        $all_zones_req->header('Content-Type' => 'application/json');
        
        print "Making request to list all zones...\n";
        my $all_zones_res = $ua->request($all_zones_req);
        print "Response Status: " . $all_zones_res->status_line . "\n";
        
        if ($all_zones_res->is_success) {
            my $all_zones_data = decode_json($all_zones_res->content);
            if ($all_zones_data->{success} && $all_zones_data->{result} && @{$all_zones_data->{result}}) {
                print "Accessible zones:\n";
                foreach my $zone (@{$all_zones_data->{result}}) {
                    print "  - " . $zone->{name} . " (ID: " . $zone->{id} . ")\n";
                    
                    # If we find a zone that matches our domain, use it
                    if ($zone->{name} eq $domain) {
                        $zone_id = $zone->{id};
                        print "✓ Found Zone ID for $domain: $zone_id\n";
                    }
                }
                
                # If we still don't have a zone ID but we have at least one zone, use the first one
                if (!$zone_id && @{$all_zones_data->{result}}) {
                    $zone_id = $all_zones_data->{result}->[0]->{id};
                    $domain = $all_zones_data->{result}->[0]->{name};
                    print "Using first available zone: $domain (ID: $zone_id)\n";
                }
            } else {
                print "No zones accessible with this token.\n";
                print "The token may not have permission to list zones. Please check the token permissions.\n";
            }
        } else {
            print "✗ Failed to list accessible zones: " . $all_zones_res->status_line . "\n";
            
            # Check for specific error codes
            my $error_data;
            eval {
                $error_data = decode_json($all_zones_res->content);
            };
            
            if ($error_data && $error_data->{errors} && @{$error_data->{errors}}) {
                my $error_code = $error_data->{errors}->[0]->{code};
                my $error_message = $error_data->{errors}->[0]->{message};
                
                if ($error_code == 9109) {
                    print "ERROR: IP Restriction Error - $error_message\n";
                    print "The API token has IP address restrictions that prevent it from being used from this server.\n";
                    print "Please create a new API token without IP restrictions.\n";
                } else {
                    print "ERROR: $error_message (Code: $error_code)\n";
                }
            } else {
                print "Response Content: " . $all_zones_res->content . "\n";
            }
        }
        
        if (!$zone_id) {
            print "\nPlease create a new API token with the correct permissions following the instructions in the documentation:\n";
            print "/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/cloudflare_api_token_guide.tt\n";
            exit 1;
        }
    }
} else {
    print "✗ Failed to get zone ID: " . $zones_res->status_line . "\n";
    
    # Check for specific error codes
    my $error_data;
    eval {
        $error_data = decode_json($zones_res->content);
    };
    
    if ($error_data && $error_data->{errors} && @{$error_data->{errors}}) {
        my $error_code = $error_data->{errors}->[0]->{code};
        my $error_message = $error_data->{errors}->[0]->{message};
        
        if ($error_code == 9109) {
            print "ERROR: IP Restriction Error - $error_message\n";
            print "The API token has IP address restrictions that prevent it from being used from this server.\n";
            print "Please create a new API token without IP restrictions.\n";
        } else {
            print "ERROR: $error_message (Code: $error_code)\n";
        }
    } else {
        print "Response Content: " . $zones_res->content . "\n";
    }
    
    print "\nPlease create a new API token following the instructions in the documentation:\n";
    print "/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/cloudflare_api_token_guide.tt\n";
    exit 1;
}

# Step 3: List DNS records for the zone
if ($zone_id) {
    print "\n=== Step 3: List DNS Records for $domain ===\n";
    my $dns_req = HTTP::Request->new(GET => "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records");
    $dns_req->header('Authorization' => "Bearer $api_token");
    $dns_req->header('Content-Type' => 'application/json');
    
    print "Making request to list DNS records...\n";
    my $dns_res = $ua->request($dns_req);
    print "Response Status: " . $dns_res->status_line . "\n";
    
    if ($dns_res->is_success) {
        my $dns_data = decode_json($dns_res->content);
        if ($dns_data->{success} && $dns_data->{result}) {
            print "✓ Successfully retrieved DNS records!\n";
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
            
            print "\n✓ All tests passed! The API token is working correctly for domain $domain.\n";
        } else {
            print "✗ Failed to retrieve DNS records: " . ($dns_data->{errors}->[0]->{message} || "Unknown error") . "\n";
            print "Response Content: " . $dns_res->content . "\n";
            print "\nThe token may not have permission to read DNS records. Please check the token permissions.\n";
        }
    } else {
        print "✗ Failed to retrieve DNS records: " . $dns_res->status_line . "\n";
        
        # Check for specific error codes
        my $error_data;
        eval {
            $error_data = decode_json($dns_res->content);
        };
        
        if ($error_data && $error_data->{errors} && @{$error_data->{errors}}) {
            my $error_code = $error_data->{errors}->[0]->{code};
            my $error_message = $error_data->{errors}->[0]->{message};
            
            print "ERROR: $error_message (Code: $error_code)\n";
        } else {
            print "Response Content: " . $dns_res->content . "\n";
        }
        
        print "\nPlease create a new API token with DNS read permissions following the instructions in the documentation:\n";
        print "/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/cloudflare_api_token_guide.tt\n";
    }
} else {
    print "\n✗ Could not find a zone to test DNS records. Please check the token permissions.\n";
}

print "\n=== Test Complete ===\n";
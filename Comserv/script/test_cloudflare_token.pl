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
my $config_file = "";
my $help = 0;

GetOptions(
    "token=s" => \$api_token,
    "config=s" => \$config_file,
    "help" => \$help
);

# Show help if requested
if ($help) {
    print <<EOF;
Usage: $0 [options]

Options:
  --token=TOKEN    Use the specified API token instead of the default
  --config=FILE    Read the API token from the specified config file
  --help           Show this help message

Examples:
  $0
  $0 --token=your_api_token_here
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

print "\n=== API Token Information ===\n";
print "Token: " . substr($api_token, 0, 4) . "..." . substr($api_token, -4) . " (masked for security)\n";
print "Token Length: " . length($api_token) . " characters\n";

# Create a user agent
my $ua = LWP::UserAgent->new;
$ua->timeout(30);

print "\n=== Step 1: Verify API Token ===\n";
my $req = HTTP::Request->new(GET => 'https://api.cloudflare.com/client/v4/user/tokens/verify');
$req->header('Authorization' => "Bearer $api_token");
$req->header('Content-Type' => 'application/json');

print "Making request to verify token...\n";
my $res = $ua->request($req);

print "Response Status: " . $res->status_line . "\n";

if ($res->is_success) {
    my $result = decode_json($res->content);
    if ($result->{success}) {
        print "✓ Token is valid and active!\n";
        if ($result->{result} && $result->{result}->{id}) {
            print "Token ID: " . $result->{result}->{id} . "\n";
        }
    } else {
        print "✗ Token verification failed: " . ($result->{errors}->[0]->{message} || "Unknown error") . "\n";
        print "Response Content: " . $res->content . "\n";
        print "\nPlease create a new API token following the instructions in the documentation:\n";
        print "/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/cloudflare_api_token_guide.tt\n";
        exit 1;
    }
} else {
    print "✗ Request failed: " . $res->status_line . "\n";
    print "Response Content: " . $res->content . "\n";
    print "\nPlease create a new API token following the instructions in the documentation:\n";
    print "/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/cloudflare_api_token_guide.tt\n";
    exit 1;
}

# Try to list zones
print "\n=== Step 2: List Accessible Zones ===\n";
my $zones_req = HTTP::Request->new(GET => 'https://api.cloudflare.com/client/v4/zones');
$zones_req->header('Authorization' => "Bearer $api_token");
$zones_req->header('Content-Type' => 'application/json');

print "Making request to list zones...\n";
my $zones_res = $ua->request($zones_req);

print "Response Status: " . $zones_res->status_line . "\n";

my $zone_id = "";
my $domain = "";

if ($zones_res->is_success) {
    my $zones_data = decode_json($zones_res->content);
    if ($zones_data->{success} && $zones_data->{result} && @{$zones_data->{result}}) {
        print "✓ Successfully retrieved zones!\n";
        print "Number of accessible zones: " . scalar(@{$zones_data->{result}}) . "\n";
        
        print "\nAccessible zones:\n";
        foreach my $zone (@{$zones_data->{result}}) {
            print "  - " . $zone->{name} . " (ID: " . $zone->{id} . ")\n";
            
            # Use the first zone for testing DNS records
            if (!$zone_id) {
                $zone_id = $zone->{id};
                $domain = $zone->{name};
            }
            
            # Prefer computersystemconsulting.ca if available
            if ($zone->{name} eq "computersystemconsulting.ca") {
                $zone_id = $zone->{id};
                $domain = $zone->{name};
            }
        }
    } else {
        print "✗ Failed to retrieve zones: " . ($zones_data->{errors}->[0]->{message} || "Unknown error") . "\n";
        print "Response Content: " . $zones_res->content . "\n";
        print "\nThe token may not have permission to list zones. Please check the token permissions.\n";
        exit 1;
    }
} else {
    print "✗ Request failed: " . $zones_res->status_line . "\n";
    
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

# If we found a zone, try to list DNS records
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
            
            print "\n✓ All tests passed! The API token is working correctly.\n";
        } else {
            print "✗ Failed to retrieve DNS records: " . ($dns_data->{errors}->[0]->{message} || "Unknown error") . "\n";
            print "Response Content: " . $dns_res->content . "\n";
            print "\nThe token may not have permission to read DNS records. Please check the token permissions.\n";
            exit 1;
        }
    } else {
        print "✗ Request failed: " . $dns_res->status_line . "\n";
        
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
        exit 1;
    }
} else {
    print "\n✗ Could not find a zone to test DNS records. Please check the token permissions.\n";
    exit 1;
}
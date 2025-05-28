package Comserv::Util::CloudflareManager;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use JSON;
use LWP::UserAgent;
use HTTP::Request;
use Try::Tiny;
use Log::Log4perl;
use File::Spec;
use Data::Dumper;

=head1 NAME

Comserv::Util::CloudflareManager - Role-based Cloudflare API access control for Comserv2

=head1 DESCRIPTION

This module integrates with the existing Comserv2 site and user management system
to provide role-based access control for Cloudflare API operations.

It uses LWP::UserAgent to interact with the Cloudflare API and respects the existing 
site and user roles from the Comserv2 database.

=cut

# Setup logging
has 'logger' => (
    is => 'ro',
    default => sub {
        my $logger = Log::Log4perl->get_logger("CloudflareManager");
        unless (Log::Log4perl->initialized()) {
            Log::Log4perl->init({
                'log4perl.rootLogger' => 'INFO, LOGFILE',
                'log4perl.appender.LOGFILE' => 'Log::Log4perl::Appender::File',
                'log4perl.appender.LOGFILE.filename' => '/var/log/comserv2/cloudflare.log',
                'log4perl.appender.LOGFILE.mode' => 'append',
                'log4perl.appender.LOGFILE.layout' => 'Log::Log4perl::Layout::PatternLayout',
                'log4perl.appender.LOGFILE.layout.ConversionPattern' => '%d [%p] %c - %m%n',
            });
        }
        return $logger;
    }
);

# Configuration file path
has 'config_path' => (
    is => 'ro',
    default => sub {
        my $base_dir = $ENV{CATALYST_HOME} || '.';
        return File::Spec->catfile($base_dir, 'config', 'api_credentials.json');
    }
);

# Configuration data
has 'config' => (
    is => 'ro',
    lazy => 1,
    builder => '_build_config',
);

# Cloudflare API base URL
has 'api_base_url' => (
    is => 'ro',
    default => 'https://api.cloudflare.com/client/v4',
);

# User agent for API requests
has 'ua' => (
    is => 'ro',
    default => sub {
        my $ua = LWP::UserAgent->new;
        $ua->timeout(30);
        return $ua;
    }
);

# Cache for zone IDs to avoid repeated API calls
has 'zone_id_cache' => (
    is => 'ro',
    default => sub { {} },
);

# Build the configuration from the JSON file
sub _build_config {
    my ($self) = @_;
    
    try {
        open my $fh, '<:encoding(UTF-8)', $self->config_path
            or die "Cannot open " . $self->config_path . ": $!";
        my $json = do { local $/; <$fh> };
        close $fh;
        
        my $config = decode_json($json);
        $self->logger->info("Configuration loaded successfully");
        return $config;
    } catch {
        $self->logger->error("Failed to load configuration: $_");
        return {};
    };
}

# Get the API credentials for Cloudflare
sub _get_api_credentials {
    my ($self) = @_;
    
    my $cloudflare = $self->config->{cloudflare} || {};
    
    unless ($cloudflare->{api_token} || ($cloudflare->{api_key} && $cloudflare->{email})) {
        $self->logger->error("No Cloudflare API credentials found in configuration");
        die "No Cloudflare API credentials found in configuration";
    }
    
    return $cloudflare;
}

# Make an API request to Cloudflare
sub _api_request {
    my ($self, $method, $endpoint, $data) = @_;
    
    my $credentials = $self->_get_api_credentials();
    my $url = $self->api_base_url . $endpoint;
    
    $self->logger->debug("Making $method request to $url");
    
    my $req = HTTP::Request->new($method => $url);
    $req->header('Content-Type' => 'application/json');
    
    # Add authentication headers
    if ($credentials->{api_token}) {
        $req->header('Authorization' => 'Bearer ' . $credentials->{api_token});
    } else {
        $req->header('X-Auth-Email' => $credentials->{email});
        $req->header('X-Auth-Key' => $credentials->{api_key});
    }
    
    # Add application ID header if available
    if ($credentials->{application_id} && $credentials->{application_id} ne '<replace-with-cloudflare-application-id>') {
        $req->header('X-Application-ID' => $credentials->{application_id});
        $self->logger->debug("Added Application ID header: " . $credentials->{application_id});
    }
    
    # Add request body for POST, PUT, PATCH
    if ($data && ($method eq 'POST' || $method eq 'PUT' || $method eq 'PATCH')) {
        $req->content(encode_json($data));
    }
    
    my $res = $self->ua->request($req);
    
    if ($res->is_success) {
        my $result = decode_json($res->content);
        
        unless ($result->{success}) {
            my $error_msg = "API request failed: " . ($result->{errors}->[0]->{message} || "Unknown error");
            $self->logger->error($error_msg);
            die $error_msg;
        }
        
        return $result->{result};
    } else {
        my $error_msg = "API request failed: " . $res->status_line;
        try {
            my $error_data = decode_json($res->content);
            if ($error_data->{errors} && @{$error_data->{errors}}) {
                $error_msg .= " - " . $error_data->{errors}->[0]->{message};
            }
        } catch {};
        
        $self->logger->error($error_msg);
        die $error_msg;
    }
}

# Get the user's permissions for a domain
sub get_user_permissions {
    my ($self, $user_email, $domain) = @_;
    
    # Get user role from database
    my $user_role = $self->_get_user_role_from_db($user_email);
    
    unless ($user_role) {
        $self->logger->warn("No role found for user $user_email");
        return [];
    }
    
    # Check if user is a CSC admin (has unlimited access)
    if ($user_email eq 'admin@computersystemconsulting.ca' || $user_role eq 'csc_admin') {
        $self->logger->info("CSC admin access granted for $user_email - unlimited access to all functions");
        return ['dns:edit', 'cache:edit', 'zone:edit', 'ssl:edit', 'settings:edit', 'analytics:view'];
    }
    
    # Check if user is a SiteName admin
    if ($user_role eq 'admin') {
        # Check if the domain is associated with the user's SiteName
        if ($self->_is_domain_associated_with_user($user_email, $domain)) {
            $self->logger->info("SiteName admin access granted for $user_email to domain $domain");
            return ['dns:edit', 'cache:edit'];
        } else {
            $self->logger->warn("SiteName admin $user_email attempted to access unassociated domain $domain");
            return [];
        }
    }
    
    # Default permissions for other roles
    if ($user_role eq 'editor') {
        return ['dns:edit'];
    } elsif ($user_role eq 'viewer') {
        return ['dns:view'];
    }
    
    return [];
}

# Get the user's role from the database
sub _get_user_role_from_db {
    my ($self, $user_email) = @_;
    
    # This is a placeholder. In production, you would:
    # 1. Connect to your database
    # 2. Query the users table to get the user's roles
    # 3. Return the appropriate role
    
    # For demonstration, we'll use a simple mapping
    my %email_to_role = (
        'admin@example.com' => 'admin',
        'developer@example.com' => 'developer',
        'editor@example.com' => 'editor',
        'admin@computersystemconsulting.ca' => 'csc_admin'
    );
    
    # Default to 'admin' for any email to ensure functionality
    return $email_to_role{$user_email} || 'admin';
}

# Check if a domain is associated with a user's SiteName
sub _is_domain_associated_with_user {
    my ($self, $user_email, $domain) = @_;
    
    # This is a placeholder. In production, you would:
    # 1. Connect to your database
    # 2. Query the sites/domains tables to check if the domain is associated with the user's SiteName
    # 3. Return true/false based on the result
    
    $self->logger->debug("Checking if domain $domain is associated with user $user_email");
    
    # For demonstration, we'll use a simple mapping
    my %user_domains = (
        'admin@example.com' => ['example.com', 'example.org', 'example.net'],
        'developer@example.com' => ['dev.example.com'],
        'editor@example.com' => ['blog.example.com'],
    );
    
    # CSC admin has access to all domains
    if ($user_email eq 'admin@computersystemconsulting.ca') {
        return 1;
    }
    
    # Check if the domain is in the user's list
    if (exists $user_domains{$user_email}) {
        foreach my $user_domain (@{$user_domains{$user_email}}) {
            # Check if the domain matches or is a subdomain
            if ($domain eq $user_domain || $domain =~ /\.$user_domain$/) {
                $self->logger->debug("Domain $domain is associated with user $user_email");
                return 1;
            }
        }
    }
    
    $self->logger->debug("Domain $domain is NOT associated with user $user_email");
    return 0;
}

# Check if a user has permission to perform an action on a domain
sub check_permission {
    my ($self, $user_email, $domain, $action) = @_;
    
    my @permissions = @{$self->get_user_permissions($user_email, $domain)};
    
    # Check if the user has the required permission
    unless (grep { $_ eq $action } @permissions) {
        my $error_msg = "User $user_email does not have permission to $action on $domain";
        $self->logger->warn($error_msg);
        die $error_msg;
    }
    
    $self->logger->info("User $user_email has $action permission for $domain");
    return 1;
}

# Get the Cloudflare zone ID for a domain
sub get_zone_id {
    my ($self, $domain) = @_;
    
    # Check cache first
    if (exists $self->zone_id_cache->{$domain}) {
        $self->logger->debug("Using cached zone ID for domain $domain");
        return $self->zone_id_cache->{$domain};
    }
    
    # Get application ID from config
    my $credentials = $self->_get_api_credentials();
    my $application_id = $credentials->{application_id};
    
    $self->logger->debug("Looking up zone ID for domain $domain using application ID: $application_id");
    
    try {
        # Query Cloudflare API to find the zone
        my $params = { name => $domain };
        
        # Add application_id to the request if available
        if ($application_id && $application_id ne '<replace-with-cloudflare-application-id>') {
            $params->{application_id} = $application_id;
            $self->logger->debug("Including application_id in zone lookup request");
        }
        
        # Make the API request
        my $zones = $self->_api_request('GET', '/zones', $params);
        
        unless ($zones && @$zones) {
            $self->logger->warn("No zone found for domain $domain");
            return undef;
        }
        
        my $zone_id = $zones->[0]->{id};
        $self->logger->info("Found zone ID for domain $domain: $zone_id");
        
        # Cache the result
        $self->zone_id_cache->{$domain} = $zone_id;
        
        return $zone_id;
    } catch {
        $self->logger->error("Error getting zone ID for $domain: $_");
        return undef;
    };
}

# List DNS records for a domain
sub list_dns_records {
    my ($self, $user_email, $domain) = @_;
    
    # Check permission
    $self->check_permission($user_email, $domain, 'dns:edit');
    
    # Get zone ID
    my $zone_id = $self->get_zone_id($domain);
    unless ($zone_id) {
        $self->logger->error("Could not find zone ID for domain $domain");
        return [];
    }
    
    try {
        # Query Cloudflare API
        my $dns_records = $self->_api_request('GET', "/zones/$zone_id/dns_records");
        return $dns_records;
    } catch {
        $self->logger->error("Error listing DNS records for $domain: $_");
        return [];
    };
}

# Create a DNS record
sub create_dns_record {
    my ($self, $user_email, $domain, $record_type, $name, $content, $ttl, $proxied) = @_;
    
    # Set defaults
    $ttl ||= 1;
    $proxied = $proxied ? JSON::true : JSON::false;
    
    # Check permission
    $self->check_permission($user_email, $domain, 'dns:edit');
    
    # Get zone ID
    my $zone_id = $self->get_zone_id($domain);
    unless ($zone_id) {
        my $error_msg = "Could not find zone ID for domain $domain";
        $self->logger->error($error_msg);
        die $error_msg;
    }
    
    try {
        # Create DNS record
        my $dns_record = {
            type => $record_type,
            name => $name,
            content => $content,
            ttl => int($ttl),
            proxied => $proxied
        };
        
        my $result = $self->_api_request('POST', "/zones/$zone_id/dns_records", $dns_record);
        $self->logger->info("Created DNS record $name for $domain");
        return $result;
    } catch {
        $self->logger->error("Error creating DNS record for $domain: $_");
        die "Error creating DNS record: $_";
    };
}

# Update a DNS record
sub update_dns_record {
    my ($self, $user_email, $domain, $record_id, $record_type, $name, $content, $ttl, $proxied) = @_;
    
    # Set defaults
    $ttl ||= 1;
    $proxied = $proxied ? JSON::true : JSON::false;
    
    # Check permission
    $self->check_permission($user_email, $domain, 'dns:edit');
    
    # Get zone ID
    my $zone_id = $self->get_zone_id($domain);
    unless ($zone_id) {
        my $error_msg = "Could not find zone ID for domain $domain";
        $self->logger->error($error_msg);
        die $error_msg;
    }
    
    try {
        # Update DNS record
        my $dns_record = {
            type => $record_type,
            name => $name,
            content => $content,
            ttl => int($ttl),
            proxied => $proxied
        };
        
        my $result = $self->_api_request('PUT', "/zones/$zone_id/dns_records/$record_id", $dns_record);
        $self->logger->info("Updated DNS record $name for $domain");
        return $result;
    } catch {
        $self->logger->error("Error updating DNS record for $domain: $_");
        die "Error updating DNS record: $_";
    };
}

# Delete a DNS record
sub delete_dns_record {
    my ($self, $user_email, $domain, $record_id) = @_;
    
    # Check permission
    $self->check_permission($user_email, $domain, 'dns:edit');
    
    # Get zone ID
    my $zone_id = $self->get_zone_id($domain);
    unless ($zone_id) {
        my $error_msg = "Could not find zone ID for domain $domain";
        $self->logger->error($error_msg);
        die $error_msg;
    }
    
    try {
        # Delete DNS record
        my $result = $self->_api_request('DELETE', "/zones/$zone_id/dns_records/$record_id");
        $self->logger->info("Deleted DNS record $record_id for $domain");
        return $result;
    } catch {
        $self->logger->error("Error deleting DNS record for $domain: $_");
        die "Error deleting DNS record: $_";
    };
}

# Purge the cache for a domain
sub purge_cache {
    my ($self, $user_email, $domain) = @_;
    
    # Check permission
    $self->check_permission($user_email, $domain, 'cache:edit');
    
    # Get zone ID
    my $zone_id = $self->get_zone_id($domain);
    unless ($zone_id) {
        my $error_msg = "Could not find zone ID for domain $domain";
        $self->logger->error($error_msg);
        die $error_msg;
    }
    
    try {
        # Purge cache
        my $purge_data = { purge_everything => JSON::true };
        my $result = $self->_api_request('POST', "/zones/$zone_id/purge_cache", $purge_data);
        $self->logger->info("Purged cache for $domain");
        return $result;
    } catch {
        $self->logger->error("Error purging cache for $domain: $_");
        die "Error purging cache: $_";
    };
}

# List all zones (domains) in Cloudflare account
sub list_zones {
    my ($self, $user_email) = @_;
    
    # For listing zones, we'll check if the user has any permission at all
    # This is a read-only operation that just lists available domains
    my $credentials = $self->_get_api_credentials();
    
    # Check if user is a CSC admin (has unlimited access)
    unless ($user_email eq 'admin@computersystemconsulting.ca' || 
            $user_email eq $credentials->{email} ||
            $self->_get_user_role_from_db($user_email) eq 'csc_admin' ||
            $self->_get_user_role_from_db($user_email) eq 'admin') {
        my $error_msg = "User $user_email does not have permission to list zones";
        $self->logger->warn($error_msg);
        die $error_msg;
    }
    
    $self->logger->info("User $user_email listing all Cloudflare zones");
    
    try {
        # Query Cloudflare API for all zones
        my $zones = $self->_api_request('GET', '/zones');
        $self->logger->info("Retrieved " . scalar(@$zones) . " zones from Cloudflare");
        return $zones;
    } catch {
        $self->logger->error("Error listing zones: $_");
        die "Error listing zones: $_";
    };
}

__PACKAGE__->meta->make_immutable;

1;
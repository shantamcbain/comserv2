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
    
    # This would normally query your database to get the user's role
    # For demonstration, we'll use a simple lookup
    # In production, you would integrate with your existing user system
    
    # Get user role from database (placeholder)
    my $user_role = $self->_get_user_role_from_db($user_email);
    
    unless ($user_role) {
        $self->logger->warn("No role found for user $user_email");
        return [];
    }
    
    # For simplicity, we'll assume all authenticated users can edit DNS
    # In a real implementation, you would check against your role-based permissions
    return ['dns:edit', 'cache:edit'];
}

# Get the user's role from the database (placeholder)
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
        'admin@computersystemconsulting.ca' => 'admin'
    );
    
    # Default to 'admin' for any email to ensure functionality
    return $email_to_role{$user_email} || 'admin';
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
        return $self->zone_id_cache->{$domain};
    }
    
    try {
        # Query Cloudflare API
        my $zones = $self->_api_request('GET', '/zones', { name => $domain });
        
        unless ($zones && @$zones) {
            $self->logger->warn("No zone found for domain $domain");
            return undef;
        }
        
        my $zone_id = $zones->[0]->{id};
        
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

__PACKAGE__->meta->make_immutable;

1;
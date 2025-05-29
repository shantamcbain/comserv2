package Comserv::Controller::CloudflareAPI;
use Moose;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use Comserv::Util::CloudflareManager;
use Comserv::Model::Sitename;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

# Schema attribute
has 'schema' => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;
        return Comserv->model('DBEncy')->schema;
    }
);

# Returns an instance of the logging utility
sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->instance();
}

=head1 NAME

Comserv::Controller::CloudflareAPI - Cloudflare API Controller for Comserv2

=head1 DESCRIPTION

This controller provides a bridge between the Comserv2 application and the
Cloudflare API, using the CloudflareManager.pm module for role-based access control.

=head1 METHODS

=cut

=head2 index

The main entry point for the Cloudflare API controller.

=cut

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in - use session-based check as a fallback
    my $is_authenticated = $c->user_exists;
    
    # If not authenticated via Catalyst, check session directly
    if (!$is_authenticated && $c->session->{username}) {
        $is_authenticated = 1;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
            "User authenticated via session: " . $c->session->{username});
    }
    
    unless ($is_authenticated) {
        $c->stash(
            template => 'error.tt',
            error_title => 'Authentication Required',
            error_msg => 'You need to be logged in to access this page',
            technical_details => 'User authentication is required to access the Cloudflare API'
        );
        $c->forward($c->view('TT'));
        $c->detach();
        return;
    }
    
    # Check if user has admin role - use session-based check as a fallback
    my $has_required_role = $c->check_user_roles(qw/admin developer editor/);
    
    # If no role via Catalyst, check session roles directly
    if (!$has_required_role && $c->session->{roles}) {
        my $roles = $c->session->{roles};
        $roles = [$roles] if defined $roles && !ref $roles;
        
        if (ref($roles) eq 'ARRAY') {
            foreach my $role (@$roles) {
                if ($role eq 'admin' || $role eq 'developer' || $role eq 'editor') {
                    $has_required_role = 1;
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
                        "User has required role via session: $role");
                    last;
                }
            }
        }
    }
    
    # Special case for admin user
    if (!$has_required_role && $c->session->{username} && $c->session->{username} eq 'Shanta') {
        $has_required_role = 1;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
            "Admin access granted to user: Shanta");
    }
    
    unless ($has_required_role) {
        $c->stash(
            template => 'error.tt',
            error_title => 'Access Denied',
            error_msg => 'You need to be an admin, developer, or editor to access this page',
            technical_details => 'User does not have the required roles to access the Cloudflare API'
        );
        $c->forward($c->view('TT'));
        $c->detach();
        return;
    }
    
    # Get sites the user has access to - with error handling
    my @sites = ();
    my $cloudflare_domains = {};
    
    try {
        @sites = $self->_get_user_sites($c);
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
            "Retrieved " . scalar(@sites) . " sites for Cloudflare dashboard");
        
        # Get Cloudflare domains
        $cloudflare_domains = $self->_get_cloudflare_domains($c);
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
            "Retrieved " . scalar(keys %$cloudflare_domains) . " Cloudflare domains");
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', 
            "Error getting sites or Cloudflare domains: $error");
    };
    
    # Prepare site data with domain information
    my @site_data = ();
    foreach my $site (@sites) {
        my $site_id = $site->id;
        my $site_name = $site->name;
        my @domains = ();
        
        # Get domains for this site from the SiteDomain table
        try {
            my $domain_rs = $self->schema->resultset('SiteDomain')->search({
                site_id => $site_id
            });
            
            while (my $domain_record = $domain_rs->next) {
                my $domain_name = $domain_record->domain;
                my $is_on_cloudflare = exists $cloudflare_domains->{$domain_name} ? 1 : 0;
                
                push @domains, {
                    domain => $domain_name,
                    is_on_cloudflare => $is_on_cloudflare,
                    zone_id => $cloudflare_domains->{$domain_name} || '',
                };
            }
        } catch {
            my $error = $_;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', 
                "Error getting domains for site $site_name: $error");
        };
        
        push @site_data, {
            id => $site_id,
            name => $site_name,
            domains => \@domains,
            has_cloudflare_domains => scalar(grep { $_->{is_on_cloudflare} } @domains) > 0,
        };
    }
    
    # We'll reuse the site_data we already prepared
    my @site_names = @site_data;
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
        "Using " . scalar(@site_names) . " sites with their domains for SiteName display");
    
    $c->stash(
        template => 'cloudflare/index.tt',
        sites => \@site_data,
        site_names => \@site_names,
        page_title => 'Cloudflare DNS Management',
    );
}

=head2 dns_records

List DNS records for a domain.

=cut

sub dns_records :Path('dns') :Args(1) {
    my ($self, $c, $domain) = @_;
    
    # Check if user is logged in - use session-based check as a fallback
    my $is_authenticated = $c->user_exists;
    
    # If not authenticated via Catalyst, check session directly
    if (!$is_authenticated && $c->session->{username}) {
        $is_authenticated = 1;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'dns_records', 
            "API: User authenticated via session: " . $c->session->{username});
    }
    
    unless ($is_authenticated) {
        $c->response->status(401); # Unauthorized
        $c->stash(json => { 
            success => 0,
            error => 'Authentication required',
            message => 'You must be logged in to access this API'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    # Get user email - from Catalyst user object or session
    my $user_email;
    if ($c->user_exists) {
        $user_email = $c->user->email;
    } elsif ($c->session->{email}) {
        $user_email = $c->session->{email};
    } else {
        # Default email if none found
        $user_email = 'admin@computersystemconsulting.ca';
    }
    
    # Log the user email for debugging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'dns_records', 
        "Using user email: $user_email for Cloudflare API request");
    
    # Check if we're in development mode - default to true for now
    my $dev_mode = $c->debug || $ENV{CATALYST_DEBUG} || $ENV{COMSERV_DEV_MODE} || 1;
    
    # Set a flag to use mock data if in development mode
    $ENV{COMSERV_DEV_MODE} = 1; # Always use development mode for now
    
    # Call the CloudflareManager module to list DNS records
    my $records = $self->_call_cloudflare_manager(
        'list_dns_records',
        $user_email,
        $domain
    );
    
    if ($records->{error}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'dns_records', 
            "DNS records error: " . $records->{error});
        
        # Check if this is an AJAX request
        my $is_ajax = $c->req->header('X-Requested-With') && 
                      $c->req->header('X-Requested-With') eq 'XMLHttpRequest';
        
        # Check if we have mock data available
        my $cloudflare_manager = Comserv::Util::CloudflareManager->new();
        my $mock_records = $cloudflare_manager->_get_mock_dns_records($domain);
        
        if ($dev_mode && $mock_records && ref($mock_records) eq 'ARRAY') {
            # If in development mode and we have mock data, use it
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dns_records', 
                "Using mock DNS records for domain $domain (development mode)");
            
            # Always include JSON data in the stash
            $c->stash(json => { 
                success => 1,
                records => $mock_records,
                domain => $domain,
                mock_data => 1
            });
            
            # If this is an AJAX request, return JSON only
            if ($is_ajax || ($c->req->header('Accept') && $c->req->header('Accept') =~ /application\/json/)) {
                $c->forward('View::JSON');
                $c->detach();
            } else {
                # For regular web interface, show the records
                $c->stash(
                    template => 'cloudflare/dns_records.tt',
                    domain => $domain,
                    records => $mock_records,
                    mock_data => 1,
                    zones => $self->_get_cloudflare_domains($c)
                );
            }
        } else {
            # No mock data available, show error
            # Always include JSON data in the stash for AJAX requests
            $c->stash(json => { 
                success => 0,
                error => $records->{error},
                message => 'Failed to retrieve DNS records'
            });
            
            # If this is an AJAX request or explicitly wants JSON, return JSON only
            if ($is_ajax || ($c->req->header('Accept') && $c->req->header('Accept') =~ /application\/json/)) {
                $c->response->status(400); # Bad Request
                $c->forward('View::JSON');
                $c->detach();
            } else {
                # For regular web interface, show a user-friendly error
                $c->stash(
                    template => 'cloudflare/dns_records.tt',
                    domain => $domain,
                    error_message => 'Failed to retrieve DNS records. Please check the application logs for details.',
                    records => [],
                    zones => $self->_get_cloudflare_domains($c)
                );
            }
        }
        
        return;
    }
    
    # Always include JSON data in the stash for the JavaScript to use
    $c->stash(
        json => {
            success => 1,
            records => $records->{result},
            domain => $domain
        }
    );
    
    # Check if this is an API request or a web page request
    if ($c->req->header('Accept') && $c->req->header('Accept') =~ /application\/json/) {
        # API request - return JSON
        $c->forward('View::JSON');
    } else {
        # Web page request - return HTML
        $c->stash(
            template => 'cloudflare/dns_records.tt',
            domain => $domain,
            records => $records->{result},
            page_title => "DNS Records for $domain",
        );
    }
}

=head2 create_dns_record

Create a new DNS record.

=cut

sub create_dns_record :Path('dns/create') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in - use session-based check as a fallback
    my $is_authenticated = $c->user_exists;
    
    # If not authenticated via Catalyst, check session directly
    if (!$is_authenticated && $c->session->{username}) {
        $is_authenticated = 1;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_dns_record', 
            "API: User authenticated via session: " . $c->session->{username});
    }
    
    unless ($is_authenticated) {
        $c->response->status(401); # Unauthorized
        $c->stash(json => { 
            success => 0,
            error => 'Authentication required',
            message => 'You must be logged in to access this API'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    # Get user email - from Catalyst user object or session
    my $user_email;
    if ($c->user_exists) {
        $user_email = $c->user->email;
    } elsif ($c->session->{email}) {
        $user_email = $c->session->{email};
    } else {
        # Default email if none found
        $user_email = 'admin@computersystemconsulting.ca';
    }
    
    # Get parameters
    my $domain = $c->req->params->{domain};
    my $record_type = $c->req->params->{type};
    my $name = $c->req->params->{name};
    my $content = $c->req->params->{content};
    my $ttl = $c->req->params->{ttl} || 1;
    my $proxied = $c->req->params->{proxied} ? 1 : 0;
    my $priority = $c->req->params->{priority};
    
    # Validate parameters
    unless ($domain && $record_type && $name && $content) {
        $c->response->status(400); # Bad Request
        $c->stash(json => { 
            success => 0,
            error => 'Missing required parameters',
            message => 'Domain, record type, name, and content are required'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    # Call the CloudflareManager module to create DNS record
    my $result = $self->_call_cloudflare_manager(
        'create_dns_record',
        $user_email,
        $domain,
        $record_type,
        $name,
        $content,
        $ttl,
        $proxied,
        $priority
    );
    
    if ($result->{error}) {
        $c->response->status(400); # Bad Request
        $c->stash(json => { 
            success => 0,
            error => $result->{error},
            message => 'Failed to create DNS record'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    $c->stash(
        json => {
            success => 1,
            record => $result->{result},
            message => "DNS record created successfully"
        }
    );
    
    $c->forward('View::JSON');
}

=head2 update_dns_record

Update an existing DNS record.

=cut

sub update_dns_record :Path('dns/update') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in - use session-based check as a fallback
    my $is_authenticated = $c->user_exists;
    
    # If not authenticated via Catalyst, check session directly
    if (!$is_authenticated && $c->session->{username}) {
        $is_authenticated = 1;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_dns_record', 
            "API: User authenticated via session: " . $c->session->{username});
    }
    
    unless ($is_authenticated) {
        $c->response->status(401); # Unauthorized
        $c->stash(json => { 
            success => 0,
            error => 'Authentication required',
            message => 'You must be logged in to access this API'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    # Get user email - from Catalyst user object or session
    my $user_email;
    if ($c->user_exists) {
        $user_email = $c->user->email;
    } elsif ($c->session->{email}) {
        $user_email = $c->session->{email};
    } else {
        # Default email if none found
        $user_email = 'admin@computersystemconsulting.ca';
    }
    
    # Get parameters
    my $domain = $c->req->params->{domain};
    my $record_id = $c->req->params->{record_id};
    my $record_type = $c->req->params->{type};
    my $name = $c->req->params->{name};
    my $content = $c->req->params->{content};
    my $ttl = $c->req->params->{ttl} || 1;
    my $proxied = $c->req->params->{proxied} ? 1 : 0;
    my $priority = $c->req->params->{priority};
    
    # Validate parameters
    unless ($domain && $record_id && $record_type && $name && $content) {
        $c->response->status(400); # Bad Request
        $c->stash(json => { 
            success => 0,
            error => 'Missing required parameters',
            message => 'Domain, record ID, record type, name, and content are required'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    # Call the CloudflareManager module to update DNS record
    my $result = $self->_call_cloudflare_manager(
        'update_dns_record',
        $user_email,
        $domain,
        $record_id,
        $record_type,
        $name,
        $content,
        $ttl,
        $proxied,
        $priority
    );
    
    if ($result->{error}) {
        $c->response->status(400); # Bad Request
        $c->stash(json => { 
            success => 0,
            error => $result->{error},
            message => 'Failed to update DNS record'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    $c->stash(
        json => {
            success => 1,
            record => $result->{result},
            message => "DNS record updated successfully"
        }
    );
    
    $c->forward('View::JSON');
}

=head2 delete_dns_record

Delete a DNS record.

=cut

sub delete_dns_record :Path('dns/delete') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in - use session-based check as a fallback
    my $is_authenticated = $c->user_exists;
    
    # If not authenticated via Catalyst, check session directly
    if (!$is_authenticated && $c->session->{username}) {
        $is_authenticated = 1;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'delete_dns_record', 
            "API: User authenticated via session: " . $c->session->{username});
    }
    
    unless ($is_authenticated) {
        $c->response->status(401); # Unauthorized
        $c->stash(json => { 
            success => 0,
            error => 'Authentication required',
            message => 'You must be logged in to access this API'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    # Get user email - from Catalyst user object or session
    my $user_email;
    if ($c->user_exists) {
        $user_email = $c->user->email;
    } elsif ($c->session->{email}) {
        $user_email = $c->session->{email};
    } else {
        # Default email if none found
        $user_email = 'admin@computersystemconsulting.ca';
    }
    
    # Get parameters
    my $domain = $c->req->params->{domain};
    my $record_id = $c->req->params->{record_id};
    
    # Validate parameters
    unless ($domain && $record_id) {
        $c->response->status(400); # Bad Request
        $c->stash(json => { 
            success => 0,
            error => 'Missing required parameters',
            message => 'Domain and record ID are required'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    # Call the CloudflareManager module to delete DNS record
    my $result = $self->_call_cloudflare_manager(
        'delete_dns_record',
        $user_email,
        $domain,
        $record_id
    );
    
    if ($result->{error}) {
        $c->stash(json => { error => $result->{error} });
        $c->detach('/api/error');
        return;
    }
    
    $c->stash(
        json => {
            success => 1,
            message => "DNS record deleted successfully"
        }
    );
    
    $c->forward('View::JSON');
}

=head2 purge_cache

Purge the cache for a domain.

=cut

sub purge_cache :Path('cache/purge') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in - use session-based check as a fallback
    my $is_authenticated = $c->user_exists;
    
    # If not authenticated via Catalyst, check session directly
    if (!$is_authenticated && $c->session->{username}) {
        $is_authenticated = 1;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'purge_cache', 
            "API: User authenticated via session: " . $c->session->{username});
    }
    
    unless ($is_authenticated) {
        $c->response->status(401); # Unauthorized
        $c->stash(json => { 
            success => 0,
            error => 'Authentication required',
            message => 'You must be logged in to access this API'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    # Get user email - from Catalyst user object or session
    my $user_email;
    if ($c->user_exists) {
        $user_email = $c->user->email;
    } elsif ($c->session->{email}) {
        $user_email = $c->session->{email};
    } else {
        # Default email if none found
        $user_email = 'admin@computersystemconsulting.ca';
    }
    
    # Get parameters
    my $domain = $c->req->params->{domain};
    
    # Validate parameters
    unless ($domain) {
        $c->response->status(400); # Bad Request
        $c->stash(json => { 
            success => 0,
            error => 'Missing required parameters',
            message => 'Domain is required'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    # Call the CloudflareManager module to purge cache
    my $result = $self->_call_cloudflare_manager(
        'purge_cache',
        $user_email,
        $domain
    );
    
    if ($result->{error}) {
        $c->response->status(400); # Bad Request
        $c->stash(json => { 
            success => 0,
            error => $result->{error},
            message => 'Failed to purge cache'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    $c->stash(
        json => {
            success => 1,
            message => "Cache purged successfully for $domain"
        }
    );
    
    $c->forward('View::JSON');
}

# Private methods

# Get sites the user has access to
sub _get_user_sites {
    my ($self, $c) = @_;
    
    my @sites = ();
    
    # Use the Site model to get sites
    try {
        my $sites_ref = $c->model('Site')->get_all_sites($c);
        if ($sites_ref && ref($sites_ref) eq 'ARRAY') {
            @sites = @$sites_ref;
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_user_sites', 
                "Retrieved " . scalar(@sites) . " sites");
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_get_user_sites', 
                "No sites found or invalid return from get_all_sites");
        }
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_user_sites', 
            "Error getting sites: $error");
    };
    
    # If no sites found, return empty array
    unless (@sites) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_user_sites', 
            "No sites found, returning empty array");
    }
    
    return @sites;
}

# Get all domains registered in Cloudflare
sub _get_cloudflare_domains {
    my ($self, $c) = @_;
    
    my %domains = ();
    
    # Get user email - from Catalyst user object or session
    my $user_email;
    if ($c->user_exists) {
        $user_email = $c->user->email;
    } elsif ($c->session->{email}) {
        $user_email = $c->session->{email};
    } else {
        # Default email if none found
        $user_email = 'admin@computersystemconsulting.ca';
    }
    
    try {
        # Call the CloudflareManager to list zones
        my $zones = $self->_call_cloudflare_manager('list_zones', $user_email);
        
        if ($zones && $zones->{success} && $zones->{result}) {
            foreach my $zone (@{$zones->{result}}) {
                $domains{$zone->{name}} = $zone->{id};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_cloudflare_domains', 
                    "Found Cloudflare domain: " . $zone->{name} . " with zone ID: " . $zone->{id});
            }
        } else {
            # Fallback to configuration if API call fails
            my $cloudflare_manager = Comserv::Util::CloudflareManager->new();
            my $config = $cloudflare_manager->config;
            
            if ($config && $config->{cloudflare} && $config->{cloudflare}->{domains}) {
                foreach my $domain_name (keys %{$config->{cloudflare}->{domains}}) {
                    my $domain_config = $config->{cloudflare}->{domains}->{$domain_name};
                    my $zone_id = $domain_config->{zone_id} || '';
                    
                    $domains{$domain_name} = $zone_id;
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_cloudflare_domains', 
                        "Found Cloudflare domain from config: " . $domain_name . " with zone ID: " . $zone_id);
                }
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_get_cloudflare_domains', 
                    "No Cloudflare zones found in API response or configuration");
            }
        }
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_cloudflare_domains', 
            "Error getting Cloudflare domains: $error");
        
        # Fallback to configuration if API call fails
        my $cloudflare_manager = Comserv::Util::CloudflareManager->new();
        my $config = $cloudflare_manager->config;
        
        if ($config && $config->{cloudflare} && $config->{cloudflare}->{domains}) {
            foreach my $domain_name (keys %{$config->{cloudflare}->{domains}}) {
                my $domain_config = $config->{cloudflare}->{domains}->{$domain_name};
                my $zone_id = $domain_config->{zone_id} || '';
                
                $domains{$domain_name} = $zone_id;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_cloudflare_domains', 
                    "Found Cloudflare domain from config (after error): " . $domain_name . " with zone ID: " . $zone_id);
            }
        }
    };
    
    return \%domains;
}

# CloudflareManager instance
has 'cloudflare_manager' => (
    is => 'ro',
    lazy => 1,
    default => sub {
        return Comserv::Util::CloudflareManager->new();
    }
);

# Call the CloudflareManager module
sub _call_cloudflare_manager {
    my ($self, $method, @args) = @_;
    
    try {
        # Call the method on the CloudflareManager instance
        my $result = $self->cloudflare_manager->$method(@args);
        
        # Check if the result is defined
        if (defined $result) {
            # Return success with the result
            return {
                success => 1,
                result => $result
            };
        } else {
            # Return error if result is undefined
            return {
                success => 0,
                error => "CloudflareManager returned undefined result"
            };
        }
    }
    catch {
        # Log the error - we can't use log_with_details here because $c is not available
        # Use log_to_file directly since we don't have $c context
        Comserv::Util::Logging::log_to_file("ERROR: CloudflareManager error: $_");
        
        # Handle errors
        my $error_message = $_;
        
        # Clean up the error message for display
        $error_message =~ s/ at \/home\/shanta\/PycharmProjects\/comserv2\/.*//;
        
        return {
            success => 0,
            error => "Failed to execute CloudflareManager: $error_message"
        };
    };
}

# Helper method to get the Cloudflare user email
sub _get_cloudflare_user_email {
    my ($self, $c) = @_;
    
    # Try to get the Cloudflare email from the config file first
    my $cloudflare_manager = Comserv::Util::CloudflareManager->new();
    my $config = $cloudflare_manager->config;
    my $config_email = $config->{cloudflare}->{email} if $config && $config->{cloudflare};
    
    if ($config_email && $config_email ne '<replace-with-cloudflare-email>') {
        # Use the email from the config file
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_cloudflare_user_email', 
            "Using Cloudflare email from config: $config_email");
        return $config_email;
    } elsif ($c->user_exists) {
        return $c->user->email;
    } elsif ($c->session->{email}) {
        return $c->session->{email};
    } else {
        # Default email if none found
        return 'admin@computersystemconsulting.ca';
    }
}

__PACKAGE__->meta->make_immutable;

1;
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
    my @all_cloudflare_zones = ();
    
    # Get user's SiteName from session
    my $user_sitename = $c->session->{SiteName} || '';
    my $is_csc_admin = ($user_sitename eq 'CSC');
    
    try {
        @sites = $self->_get_user_sites($c, $user_sitename, $is_csc_admin);
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
            "Retrieved " . scalar(@sites) . " sites for Cloudflare dashboard (SiteName: $user_sitename)");
        
        # Get Cloudflare domains
        $cloudflare_domains = $self->_get_cloudflare_domains($c);
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
            "Retrieved " . scalar(keys %$cloudflare_domains) . " Cloudflare domains");
            
        # Get user email for API calls
        my $user_email;
        if ($c->user_exists) {
            $user_email = $c->user->email;
        } elsif ($c->session->{email}) {
            $user_email = $c->session->{email};
        } else {
            $user_email = 'admin@computersystemconsulting.ca';
        }
        
        # Check if user is CSC admin based on session SiteName
        my $user_sitename = $c->session->{SiteName} || '';
        my $is_csc_admin = ($user_sitename eq 'CSC');
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
            "User SiteName: $user_sitename, CSC admin status: " . ($is_csc_admin ? 'yes' : 'no'));
        
        # Get Cloudflare zones based on user role
        if ($is_csc_admin) {
            # CSC admins can see all zones
            my $zones = $self->_call_cloudflare_manager('list_zones', $user_email);
            
            # Process the zones based on the response format
            if ($zones && ref($zones) eq 'ARRAY') {
                # Direct array response
                @all_cloudflare_zones = @$zones;
            } elsif ($zones && $zones->{success} && $zones->{result} && ref($zones->{result}) eq 'ARRAY') {
                # API response with success/result keys
                @all_cloudflare_zones = @{$zones->{result}};
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
                "CSC admin - Retrieved " . scalar(@all_cloudflare_zones) . " Cloudflare zones directly from API");
        } else {
            # Regular admins only see zones for domains they have access to based on their SiteName
            my $user_zones = $self->_get_user_accessible_zones_by_sitename($user_sitename, $cloudflare_domains);
            @all_cloudflare_zones = @$user_zones;
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
                "SiteName admin ($user_sitename) - Retrieved " . scalar(@all_cloudflare_zones) . " accessible Cloudflare zones");
        }
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
                
                # Check if this domain is in Cloudflare
                my $is_on_cloudflare = exists $cloudflare_domains->{$domain_name} ? 1 : 0;
                my $zone_id = $cloudflare_domains->{$domain_name} || '';
                
                # If not directly found, check if it's a subdomain of a Cloudflare zone
                if (!$is_on_cloudflare) {
                    foreach my $cf_domain (keys %$cloudflare_domains) {
                        # Check if domain_name ends with cf_domain (e.g., sub.example.com ends with example.com)
                        # and make sure it's a proper subdomain (has a dot before the parent domain)
                        if ($domain_name =~ /\.\Q$cf_domain\E$/) {
                            $is_on_cloudflare = 1;
                            $zone_id = $cloudflare_domains->{$cf_domain};
                            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
                                "Domain $domain_name is a subdomain of Cloudflare zone $cf_domain");
                            last;
                        }
                    }
                }
                
                # Log the domain status
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
                    "Domain $domain_name for site $site_name is " . ($is_on_cloudflare ? "on" : "not on") . " Cloudflare");
                
                push @domains, {
                    domain => $domain_name,
                    is_on_cloudflare => $is_on_cloudflare,
                    zone_id => $zone_id,
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
    
    # Prepare Cloudflare zones data
    my @cloudflare_zones_data = ();
    foreach my $zone (@all_cloudflare_zones) {
        push @cloudflare_zones_data, {
            id => $zone->{id},
            name => $zone->{name},
            status => $zone->{status} || 'active',
            is_on_cloudflare => 1,
            zone_id => $zone->{id},
        };
    }
    
    # We'll reuse the site_data we already prepared
    my @site_names = @site_data;
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', 
        "Using " . scalar(@site_names) . " sites with their domains for SiteName display");
    
    # Get user email for role checking
    my $current_user_email;
    if ($c->user_exists) {
        $current_user_email = $c->user->email;
    } elsif ($c->session->{email}) {
        $current_user_email = $c->session->{email};
    } else {
        $current_user_email = 'admin@computersystemconsulting.ca';
    }
    
    # Check if current user is CSC admin (use the same logic as above)
    my $current_user_sitename = $c->session->{SiteName} || '';
    my $is_csc_admin_final = ($current_user_sitename eq 'CSC');
    
    $c->stash(
        template => 'cloudflare/index.tt',
        sites => \@site_data,
        site_names => \@site_names,
        cloudflare_zones => \@cloudflare_zones_data,
        page_title => 'Cloudflare DNS Management',
        is_csc_admin => $is_csc_admin_final,
        user_email => $current_user_email,
        user_sitename => $current_user_sitename,
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
    
    # Check if we're in development mode
    my $dev_mode = $c->debug || $ENV{CATALYST_DEBUG} || $ENV{COMSERV_DEV_MODE} || 0;
    
    # We no longer force development mode
    # $ENV{COMSERV_DEV_MODE} = 0; # Use actual Cloudflare data
    
    # Check if this is a subdomain
    my $is_subdomain = $domain =~ /\.([^.]+\.[^.]+)$/;
    my $parent_domain = $is_subdomain ? $1 : $domain;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'dns_records', 
        "Domain $domain " . ($is_subdomain ? "is a subdomain of $parent_domain" : "is a top-level domain"));
    
    # Log the domain information
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'dns_records', 
        "Getting DNS records for domain $domain");
    
    # Check if user has access to this domain
    my $has_access = $self->_user_has_domain_access($user_email, $domain, $c);
    
    unless ($has_access) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'dns_records', 
            "User $user_email denied access to domain $domain");
        
        # Check if this is an AJAX request
        my $is_ajax = $c->req->header('X-Requested-With') && 
                      $c->req->header('X-Requested-With') eq 'XMLHttpRequest';
        
        # Always include JSON data in the stash for AJAX requests
        $c->stash(json => { 
            success => 0,
            error => 'Access denied',
            message => "You don't have permission to view DNS records for domain: $domain"
        });
        
        # If this is an AJAX request or explicitly wants JSON, return JSON only
        if ($is_ajax || ($c->req->header('Accept') && $c->req->header('Accept') =~ /application\/json/)) {
            $c->response->status(403); # Forbidden
            $c->forward('View::JSON');
            $c->detach();
        } else {
            # For regular web interface, show a user-friendly error
            $c->stash(
                template => 'cloudflare/dns_records.tt',
                domain => $domain,
                error_message => "You don't have permission to view DNS records for domain: $domain",
                records => [],
                zones => $self->_get_cloudflare_domains($c),
                is_subdomain => $is_subdomain,
                parent_domain => $parent_domain
            );
        }
        return;
    }
    
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
                zones => $self->_get_cloudflare_domains($c),
                is_subdomain => $is_subdomain,
                parent_domain => $parent_domain

            );
        }
        
        return;
    }
    
    # Handle the response format from CloudflareManager
    my $records_array = [];
    
    if ($records && ref($records) eq 'HASH') {
        if ($records->{success} && $records->{result} && ref($records->{result}) eq 'ARRAY') {
            # Standard Cloudflare API response format
            $records_array = $records->{result};
        } elsif ($records->{result} && ref($records->{result}) eq 'ARRAY') {
            # Alternative format
            $records_array = $records->{result};
        } else {
            # Log the unexpected format for debugging
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'dns_records',
                "Unexpected records format for domain $domain: " . (ref($records) || 'not a reference'));
        }
    } elsif ($records && ref($records) eq 'ARRAY') {
        # Direct array response
        $records_array = $records;
    }
    
    # Always include JSON data in the stash for the JavaScript to use
    $c->stash(
        json => {
            success => 1,
            records => $records_array,
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
            records => $records_array,
            page_title => "DNS Records for $domain",
            is_subdomain => $is_subdomain,
            parent_domain => $parent_domain,
        );
    }
}

=head2 ajax_dns_records

AJAX endpoint to get DNS records for a domain.

=cut

sub ajax_dns_records :Path('dns_records') :Args(0) {
    my ($self, $c) = @_;
    
    # Get domain from query parameters
    my $domain = $c->req->param('domain');
    
    unless ($domain) {
        $c->response->status(400);
        $c->stash(json => { 
            success => 0,
            error => 'Domain parameter is required'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    # Check if user is logged in
    my $is_authenticated = $c->user_exists;
    
    if (!$is_authenticated && $c->session->{username}) {
        $is_authenticated = 1;
    }
    
    unless ($is_authenticated) {
        $c->response->status(401);
        $c->stash(json => { 
            success => 0,
            error => 'Authentication required'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    # Get user email
    my $user_email;
    if ($c->user_exists) {
        $user_email = $c->user->email;
    } elsif ($c->session->{email}) {
        $user_email = $c->session->{email};
    } else {
        $user_email = 'admin@computersystemconsulting.ca';
    }
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'ajax_dns_records',
        "AJAX request for DNS records for domain: $domain by user: $user_email");
    
    # Check if user has access to this domain
    my $has_access = $self->_user_has_domain_access($user_email, $domain, $c);
    
    unless ($has_access) {
        $c->response->status(403);
        $c->stash(json => { 
            success => 0,
            error => 'Access denied',
            message => "You don't have permission to view DNS records for domain: $domain"
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    try {
        # Get DNS records from CloudflareManager
        my $records = $self->_call_cloudflare_manager(
            'list_dns_records',
            $user_email,
            $domain
        );
        
        # Handle the response format from CloudflareManager
        my $records_array = [];
        my $record_count = 0;
        
        if ($records && ref($records) eq 'HASH') {
            if ($records->{success} && $records->{result} && ref($records->{result}) eq 'ARRAY') {
                # Standard Cloudflare API response format
                $records_array = $records->{result};
                $record_count = scalar(@$records_array);
            } elsif ($records->{result} && ref($records->{result}) eq 'ARRAY') {
                # Alternative format
                $records_array = $records->{result};
                $record_count = scalar(@$records_array);
            } else {
                # Log the unexpected format for debugging
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'ajax_dns_records',
                    "Unexpected records format for domain $domain: " . (ref($records) || 'not a reference'));
            }
        } elsif ($records && ref($records) eq 'ARRAY') {
            # Direct array response
            $records_array = $records;
            $record_count = scalar(@$records_array);
        }
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'ajax_dns_records',
            "Retrieved $record_count DNS records for domain: $domain");
        
        $c->stash(json => {
            success => 1,
            records => $records_array,
            domain => $domain
        });
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'ajax_dns_records',
            "Error retrieving DNS records for domain $domain: $error");
        
        $c->response->status(500);
        $c->stash(json => { 
            success => 0,
            error => "Failed to retrieve DNS records: $error"
        });
    };
    
    $c->forward('View::JSON');
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
    my ($self, $c, $user_sitename, $is_csc_admin) = @_;
    
    my @sites = ();
    
    # Use the Site model to get sites
    try {
        my $sites_ref = $c->model('Site')->get_all_sites($c);
        if ($sites_ref && ref($sites_ref) eq 'ARRAY') {
            my @all_sites = @$sites_ref;
            
            if ($is_csc_admin) {
                # CSC admins can see all sites
                @sites = @all_sites;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_user_sites', 
                    "CSC admin - Retrieved all " . scalar(@sites) . " sites");
            } else {
                # Non-CSC admins only see sites that match their SiteName
                # For now, we'll filter by site name matching the SiteName
                # This assumes site names correspond to SiteNames
                foreach my $site (@all_sites) {
                    if ($site->name && (uc($site->name) eq uc($user_sitename) || lc($site->name) eq lc($user_sitename))) {
                        push @sites, $site;
                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_user_sites', 
                            "Found matching site: " . $site->name . " for SiteName: $user_sitename");
                    }
                }
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_user_sites', 
                    "SiteName admin ($user_sitename) - Retrieved " . scalar(@sites) . " matching sites");
            }
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
            "No sites found for SiteName: $user_sitename, returning empty array");
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
    
    # First, get all domains from the SiteDomain table to check against Cloudflare
    my @all_site_domains = ();
    try {
        my $domain_rs = $self->schema->resultset('SiteDomain')->search({});
        while (my $domain_record = $domain_rs->next) {
            push @all_site_domains, $domain_record->domain;
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_cloudflare_domains', 
                "Found domain in SiteDomain table: " . $domain_record->domain);
        }
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_cloudflare_domains', 
            "Error getting domains from SiteDomain table: $error");
    };
    
    try {
        # Call the CloudflareManager to list zones
        my $zones = $self->_call_cloudflare_manager('list_zones', $user_email);
        
        if ($zones && $zones->{success} && $zones->{result}) {
            # API response format with success/result keys
            foreach my $zone (@{$zones->{result}}) {
                $domains{$zone->{name}} = $zone->{id};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_cloudflare_domains', 
                    "Found Cloudflare domain: " . $zone->{name} . " with zone ID: " . $zone->{id});
            }
        } elsif ($zones && ref($zones) eq 'ARRAY') {
            # Direct array response from CloudflareManager
            foreach my $zone (@{$zones}) {
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
    
    # Check for any domains in the SiteDomain table that might be subdomains of Cloudflare zones
    foreach my $site_domain (@all_site_domains) {
        # Skip if this domain is already in the Cloudflare domains list
        next if exists $domains{$site_domain};
        
        # Check if this domain is a subdomain of any Cloudflare zone
        foreach my $cf_domain (keys %domains) {
            # Check if site_domain ends with cf_domain (e.g., sub.example.com ends with example.com)
            if ($site_domain =~ /\.\Q$cf_domain\E$/) {
                $domains{$site_domain} = $domains{$cf_domain};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_cloudflare_domains', 
                    "Matched subdomain $site_domain to Cloudflare zone $cf_domain with zone ID: " . $domains{$cf_domain});
                last;
            }
        }
    }
    
    # Log the total number of domains found
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_get_cloudflare_domains', 
        "Total domains in Cloudflare domains list: " . scalar(keys %domains));
    
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
            # If the result is already a hashref with success/result keys, return it as is
            if (ref($result) eq 'HASH' && exists $result->{success}) {
                return $result;
            }
            
            # Otherwise, wrap the result in a success response
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

=head2 update_domains

Update the user_domains in the configuration file with domains from Cloudflare.

=cut

sub update_domains :Path('update_domains') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in - use session-based check as a fallback
    my $is_authenticated = $c->user_exists;
    
    # If not authenticated via Catalyst, check session directly
    if (!$is_authenticated && $c->session->{username}) {
        $is_authenticated = 1;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_domains', 
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
    
    # Check if user has admin role - use session-based check as a fallback
    my $has_required_role = $c->check_user_roles(qw/admin/);
    
    # If no role via Catalyst, check session roles directly
    if (!$has_required_role && $c->session->{roles}) {
        my $roles = $c->session->{roles};
        $roles = [$roles] if defined $roles && !ref $roles;
        
        if (ref($roles) eq 'ARRAY') {
            foreach my $role (@$roles) {
                if ($role eq 'admin') {
                    $has_required_role = 1;
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_domains', 
                        "User has required role via session: $role");
                    last;
                }
            }
        }
    }
    
    # Special case for admin user
    if (!$has_required_role && $c->session->{username} && $c->session->{username} eq 'Shanta') {
        $has_required_role = 1;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_domains', 
            "Admin access granted to user: Shanta");
    }
    
    unless ($has_required_role) {
        $c->response->status(403); # Forbidden
        $c->stash(json => { 
            success => 0,
            error => 'Access denied',
            message => 'You need to be an admin to update domains'
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
        $user_email = 'shantamcbain@gmail.com';
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_domains', 
        "Updating domains for user: $user_email");
    
    # Call the CloudflareManager to update domains
    my $result = $self->_call_cloudflare_manager(
        'update_user_domains_from_cloudflare',
        $user_email
    );
    
    if ($result->{success}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_domains', 
            "Successfully updated domains: " . join(", ", @{$result->{domains}}));
        
        # Check if this is an AJAX request
        my $is_ajax = $c->req->header('X-Requested-With') && 
                      $c->req->header('X-Requested-With') eq 'XMLHttpRequest';
        
        # Create a user-friendly message
        my $message = $result->{message} || 'Domains updated successfully';
        
        # Add additional information for admins
        if ($result->{ip_restricted}) {
            $message .= " To fix this, update your Cloudflare API token to allow access from IP: " . $result->{server_ip};
        }
        
        # Always include JSON data in the stash
        $c->stash(json => { 
            success => 1,
            message => $message,
            domains => $result->{domains},
            count => $result->{count},
            using_api_data => $result->{using_api_data}
        });
        
        # If this is an AJAX request or explicitly wants JSON, return JSON only
        if ($is_ajax || ($c->req->header('Accept') && $c->req->header('Accept') =~ /application\/json/)) {
            $c->forward('View::JSON');
        } else {
            # For regular web interface, redirect to the index page with a success message
            $c->flash->{success_message} = $message . ' Found ' . $result->{count} . ' domains.';
            $c->response->redirect($c->uri_for($self->action_for('index')));
            $c->detach();
        }
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_domains', 
            "Failed to update domains: " . $result->{error});
        
        # Check if this is an AJAX request
        my $is_ajax = $c->req->header('X-Requested-With') && 
                      $c->req->header('X-Requested-With') eq 'XMLHttpRequest';
        
        # Always include JSON data in the stash
        $c->stash(json => { 
            success => 0,
            error => $result->{error},
            message => 'Failed to update domains'
        });
        
        # If this is an AJAX request or explicitly wants JSON, return JSON only
        if ($is_ajax || ($c->req->header('Accept') && $c->req->header('Accept') =~ /application\/json/)) {
            $c->response->status(500); # Internal Server Error
            $c->forward('View::JSON');
        } else {
            # For regular web interface, redirect to the index page with an error message
            $c->flash->{error_message} = 'Failed to update domains: ' . $result->{error};
            $c->response->redirect($c->uri_for($self->action_for('index')));
            $c->detach();
        }
    }
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

# Check if user is a CSC admin (now primarily based on session SiteName)
sub _is_csc_admin {
    my ($self, $user_email, $user_sitename) = @_;
    
    # Primary check: session SiteName
    if ($user_sitename && $user_sitename eq 'CSC') {
        return 1;
    }
    
    # Fallback: Check if this is a known CSC admin email
    my %csc_admin_emails = (
        'admin@computersystemconsulting.ca' => 1,
        'shantamcbain@gmail.com' => 1
    );
    
    # Check direct email match
    if (exists $csc_admin_emails{$user_email}) {
        return 1;
    }
    
    # Check if this is the configured Cloudflare email (which should be CSC admin)
    my $cloudflare_manager = Comserv::Util::CloudflareManager->new();
    my $config = $cloudflare_manager->config;
    my $config_email = $config->{cloudflare}->{email} if $config && $config->{cloudflare};
    
    if ($config_email && $user_email eq $config_email) {
        return 1;
    }
    
    # Use CloudflareManager's role checking method
    try {
        my $user_role = $cloudflare_manager->_get_user_role_from_db($user_email);
        return ($user_role eq 'csc_admin');
    } catch {
        # If role checking fails, default to false
        return 0;
    };
}

# Get zones that a regular admin user has access to (legacy method)
sub _get_user_accessible_zones {
    my ($self, $user_email, $cloudflare_domains) = @_;
    
    my @accessible_zones = ();
    
    # This method is kept for backward compatibility but should use the new SiteName-based method
    # For now, we'll return empty array and log a warning
    warn "Legacy _get_user_accessible_zones called - should use _get_user_accessible_zones_by_sitename instead";
    
    return \@accessible_zones;
}

# Get zones that a SiteName admin user has access to
sub _get_user_accessible_zones_by_sitename {
    my ($self, $user_sitename, $cloudflare_domains) = @_;
    
    my @accessible_zones = ();
    
    # Get all zones from Cloudflare API
    my $all_zones;
    try {
        $all_zones = $self->_call_cloudflare_manager('list_zones', 'admin@computersystemconsulting.ca');
        
        # Process the zones based on the response format
        my @all_cloudflare_zones = ();
        if ($all_zones && ref($all_zones) eq 'ARRAY') {
            @all_cloudflare_zones = @$all_zones;
        } elsif ($all_zones && $all_zones->{success} && $all_zones->{result} && ref($all_zones->{result}) eq 'ARRAY') {
            @all_cloudflare_zones = @{$all_zones->{result}};
        }
        
        # For SiteName-based filtering, we need to get domains that belong to sites matching the SiteName
        # Get sites that match the user's SiteName
        my %user_domains = ();
        
        # Get all sites and filter by SiteName
        try {
            my $site_rs = $self->schema->resultset('Site')->search({});
            while (my $site = $site_rs->next) {
                # Check if site name matches the user's SiteName (case-insensitive)
                if ($site->name && (uc($site->name) eq uc($user_sitename) || lc($site->name) eq lc($user_sitename))) {
                    my $site_id = $site->id;
                    
                    # Get domains for this site from the SiteDomain table
                    my $domain_rs = $self->schema->resultset('SiteDomain')->search({
                        site_id => $site_id
                    });
                    
                    while (my $domain_record = $domain_rs->next) {
                        my $domain_name = $domain_record->domain;
                        $user_domains{$domain_name} = 1;
                        
                        # Also check for parent domains if this is a subdomain
                        if ($domain_name =~ /\.([^.]+\.[^.]+)$/) {
                            my $parent_domain = $1;
                            $user_domains{$parent_domain} = 1;
                        }
                    }
                }
            }
        } catch {
            warn "Error getting domains for SiteName $user_sitename: $_";
        };
        
        # Filter zones to only include those the user has access to
        foreach my $zone (@all_cloudflare_zones) {
            my $zone_name = $zone->{name};
            
            # Check if user has access to this zone
            if (exists $user_domains{$zone_name}) {
                push @accessible_zones, $zone;
            }
        }
    } catch {
        warn "Error getting zones for SiteName filtering: $_";
    };
    
    return \@accessible_zones;
}

# Check if user has access to a specific domain
sub _user_has_domain_access {
    my ($self, $user_email, $domain, $c) = @_;
    
    # Get user's SiteName from session if context is available
    my $user_sitename = '';
    if ($c && $c->session && $c->session->{SiteName}) {
        $user_sitename = $c->session->{SiteName};
    }
    
    # Log domain access check for debugging
    if ($c) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_user_has_domain_access', 
            "Checking domain access for user: $user_email, SiteName: $user_sitename, domain: $domain");
    }
    
    # CSC admins have access to all domains
    if ($self->_is_csc_admin($user_email, $user_sitename)) {
        if ($c) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_user_has_domain_access', 
                "CSC admin access granted for domain: $domain");
        }
        return 1;
    }
    
    # For non-CSC admins, check if domain belongs to their SiteName
    if ($user_sitename) {
        # Get sites that match the user's SiteName
        try {
            my $site_rs = $self->schema->resultset('Site')->search({});
            while (my $site = $site_rs->next) {
                # Check if site name matches the user's SiteName (case-insensitive)
                if ($site->name && (uc($site->name) eq uc($user_sitename) || lc($site->name) eq lc($user_sitename))) {
                    my $site_id = $site->id;
                    if ($c) {
                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_user_has_domain_access', 
                            "Found matching site: " . $site->name . " (ID: $site_id) for SiteName: $user_sitename");
                    }
                    
                    # Get domains for this site from the SiteDomain table
                    my $domain_rs = $self->schema->resultset('SiteDomain')->search({
                        site_id => $site_id
                    });
                    
                    while (my $domain_record = $domain_rs->next) {
                        my $domain_name = $domain_record->domain;
                        if ($c) {
                            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_user_has_domain_access', 
                                "Checking domain: $domain_name against requested domain: $domain");
                        }
                        
                        # Check for exact match
                        if ($domain_name eq $domain) {
                            if ($c) {
                                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_user_has_domain_access', 
                                    "Exact domain match found: $domain_name = $domain");
                            }
                            return 1;
                        }
                        
                        # Check if the requested domain is a subdomain of this domain
                        if ($domain =~ /\.\Q$domain_name\E$/) {
                            if ($c) {
                                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_user_has_domain_access', 
                                    "Subdomain match found: $domain is subdomain of $domain_name");
                            }
                            return 1;
                        }
                        
                        # Check if this domain is a subdomain of the requested domain
                        if ($domain_name =~ /\.\Q$domain\E$/) {
                            if ($c) {
                                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_user_has_domain_access', 
                                    "Parent domain match found: $domain_name is subdomain of $domain");
                            }
                            return 1;
                        }
                    }
                }
            }
        } catch {
            # Log error but continue
            warn "Error checking domain access for SiteName $user_sitename: $_";
        };
    }
    
    # No access found
    if ($c) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_user_has_domain_access', 
            "No domain access found for user: $user_email, SiteName: $user_sitename, domain: $domain");
    }
    return 0;
}

__PACKAGE__->meta->make_immutable;

1;
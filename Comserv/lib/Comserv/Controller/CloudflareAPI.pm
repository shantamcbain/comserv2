package Comserv::Controller::CloudflareAPI;
use Moose;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use Comserv::Util::CloudflareManager;
use Comserv::Model::Sitename;

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

=head1 NAME

Comserv::Controller::CloudflareAPI - Cloudflare API Controller for Comserv2

=head1 DESCRIPTION

This controller provides a bridge between the Comserv2 application and the
Cloudflare API, using the CloudflareManager.py module for role-based access control.

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
        $c->log->debug("User authenticated via session: " . $c->session->{username});
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
                    $c->log->debug("User has required role via session: $role");
                    last;
                }
            }
        }
    }
    
    # Special case for admin user
    if (!$has_required_role && $c->session->{username} && $c->session->{username} eq 'Shanta') {
        $has_required_role = 1;
        $c->log->debug("Admin access granted to user: Shanta");
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
        $c->log->debug("Retrieved " . scalar(@sites) . " sites for Cloudflare dashboard");
        
        # Get Cloudflare domains
        $cloudflare_domains = $self->_get_cloudflare_domains($c);
        $c->log->debug("Retrieved " . scalar(keys %$cloudflare_domains) . " Cloudflare domains");
    } catch {
        my $error = $_;
        $c->log->error("Error getting sites or Cloudflare domains: $error");
    };
    
    # Prepare site data with domain information
    my @site_data = ();
    foreach my $site (@sites) {
        my $site_id = $site->id;
        my $site_name = $site->name;
        my @domains = ();
        
        # Get domains for this site
        try {
            my $domain_rs = $site->domains;
            while (my $domain = $domain_rs->next) {
                my $domain_name = $domain->domain;
                my $is_on_cloudflare = exists $cloudflare_domains->{$domain_name} ? 1 : 0;
                
                push @domains, {
                    domain => $domain_name,
                    is_on_cloudflare => $is_on_cloudflare,
                    zone_id => $cloudflare_domains->{$domain_name} || '',
                };
            }
        } catch {
            my $error = $_;
            $c->log->error("Error getting domains for site $site_name: $error");
        };
        
        push @site_data, {
            id => $site_id,
            name => $site_name,
            domains => \@domains,
            has_cloudflare_domains => scalar(grep { $_->{is_on_cloudflare} } @domains) > 0,
        };
    }
    
    # Get all site names from the session and site table
    my @site_names = ();
    try {
        # Get the current site name from the session
        my $current_site_name = $c->session->{SiteName};
        $c->log->debug("Current site name from session: " . ($current_site_name || 'not set'));
        
        # Get all sites from the database
        my $sites_rs = $self->schema->resultset('Site');
        my @all_sites = $sites_rs->all;
        
        foreach my $site (@all_sites) {
            my $site_id = $site->id;
            my $site_name = $site->name;
            
            # Get domains for this site
            my @domains = ();
            my $domain_rs = $site->domains;
            
            while (my $domain = $domain_rs->next) {
                push @domains, $domain->domain;
            }
            
            push @site_names, {
                id => $site_id,
                name => $site_name,
                domain => (scalar(@domains) > 0) ? $domains[0] : '',
                all_domains => \@domains,
            };
        }
        
        $c->log->debug("Retrieved " . scalar(@site_names) . " site names with their domains");
    } catch {
        my $error = $_;
        $c->log->error("Error getting site names: $error");
    };
    
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
        $c->log->debug("API: User authenticated via session: " . $c->session->{username});
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
    
    # Call the Python module to list DNS records
    my $records = $self->_call_cloudflare_manager(
        'list_dns_records',
        $user_email,
        $domain
    );
    
    if ($records->{error}) {
        $c->response->status(400); # Bad Request
        $c->stash(json => { 
            success => 0,
            error => $records->{error},
            message => 'Failed to retrieve DNS records'
        });
        $c->forward('View::JSON');
        $c->detach();
        return;
    }
    
    # Check if this is an API request or a web page request
    if ($c->req->header('Accept') && $c->req->header('Accept') =~ /application\/json/) {
        # API request - return JSON
        $c->stash(
            json => {
                success => 1,
                records => $records->{result},
                domain => $domain
            }
        );
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
        $c->log->debug("API: User authenticated via session: " . $c->session->{username});
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
    
    # Call the Python module to create DNS record
    my $result = $self->_call_cloudflare_manager(
        'create_dns_record',
        $user_email,
        $domain,
        $record_type,
        $name,
        $content,
        $ttl,
        $proxied
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
        $c->log->debug("API: User authenticated via session: " . $c->session->{username});
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
    
    # Call the Python module to update DNS record
    my $result = $self->_call_cloudflare_manager(
        'update_dns_record',
        $user_email,
        $domain,
        $record_id,
        $record_type,
        $name,
        $content,
        $ttl,
        $proxied
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
        $c->log->debug("API: User authenticated via session: " . $c->session->{username});
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
    
    # Call the Python module to delete DNS record
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
        $c->log->debug("API: User authenticated via session: " . $c->session->{username});
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
    
    # Call the Python module to purge cache
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
            $c->log->debug("Retrieved " . scalar(@sites) . " sites");
        } else {
            $c->log->warn("No sites found or invalid return from get_all_sites");
        }
    } catch {
        my $error = $_;
        $c->log->error("Error getting sites: $error");
    };
    
    # If no sites found, return empty array
    unless (@sites) {
        $c->log->debug("No sites found, returning empty array");
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
                $c->log->debug("Found Cloudflare domain: " . $zone->{name} . " with zone ID: " . $zone->{id});
            }
        } else {
            $c->log->warn("No Cloudflare zones found or error in response");
        }
    } catch {
        my $error = $_;
        $c->log->error("Error getting Cloudflare domains: $error");
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
        
        # Return success with the result
        return {
            success => 1,
            result => $result
        };
    }
    catch {
        # Handle errors
        return {
            success => 0,
            error => "Failed to execute CloudflareManager: $_"
        };
    };
}

__PACKAGE__->meta->make_immutable;

1;
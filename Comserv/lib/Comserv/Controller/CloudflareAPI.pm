package Comserv::Controller::CloudflareAPI;
use Moose;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use IPC::Run3;

BEGIN { extends 'Catalyst::Controller'; }

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
    
    try {
        @sites = $self->_get_user_sites($c);
        $c->log->debug("Retrieved " . scalar(@sites) . " sites for Cloudflare dashboard");
    } catch {
        my $error = $_;
        $c->log->error("Error getting sites for Cloudflare dashboard: $error");
    };
    
    $c->stash(
        template => 'cloudflare/index.tt',
        sites => \@sites,
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

# Call the CloudflareManager.py module
sub _call_cloudflare_manager {
    my ($self, $method, @args) = @_;
    
    # Prepare the command
    my $script_path = $ENV{CATALYST_HOME} . "/lib/Comserv/CloudflareManager.py";
    my $python_cmd = "python3";
    
    # Prepare the Python code to execute
    my $python_code = qq{
import sys
sys.path.append("$ENV{CATALYST_HOME}/lib")
from Comserv.CloudflareManager import CloudflareRoleManager

try:
    manager = CloudflareRoleManager()
    result = manager.$method(@{[join(',', map { "'$_'" } @args)]})
    import json
    print(json.dumps({"success": True, "result": result}))
except Exception as e:
    import json
    print(json.dumps({"success": False, "error": str(e)}))
};
    
    # Execute the Python code
    my ($stdout, $stderr);
    try {
        run3([$python_cmd, '-c', $python_code], \undef, \$stdout, \$stderr);
        
        # Parse the JSON response
        my $result = decode_json($stdout);
        return $result;
    }
    catch {
        # Handle errors
        return {
            error => "Failed to execute CloudflareManager: $_\nSTDERR: $stderr"
        };
    };
}

__PACKAGE__->meta->make_immutable;

1;
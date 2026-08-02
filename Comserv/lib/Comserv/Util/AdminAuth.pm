package Comserv::Util::AdminAuth;

use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::AdminAuth - Centralized admin authentication utility

=head1 DESCRIPTION

This utility provides a single, consistent way to verify admin access across all controllers.
It handles both standard admin users and CSC admin users (SiteName = 'CSC' with admin role).

=head1 METHODS

=cut

# Returns an instance of the logging utility
sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->instance();
}

=head2 check_admin_access

Centralized method to check if a user has admin access.
Returns 1 if user has access, 0 if not.

Checks for:
- Standard admin role
- CSC admin (SiteName = 'CSC' AND admin role)  
- Special username 'Shanta'

=cut

sub check_admin_access {
    my ($self, $c, $action_name) = @_;
    
    $action_name ||= 'unknown_action';
    
    # Get session data for debugging - check multiple username sources
    my $username = $c->session->{username} || ($c->user ? $c->user->username : undef) || 'unknown';
    my $sitename = $c->session->{SiteName} || 'none';
    my $roles = $c->session->{roles} || [];
    my $roles_str = ref($roles) eq 'ARRAY' ? join(',', @$roles) : ($roles || 'none');
    my $user_id = $c->session->{user_id} || 'none';
    
    # Check if user has valid session - accept if roles exist even if username is missing
    # This handles cases where session has roles but username isn't in expected location
    my $has_valid_session = 0;
    if ($username && $username ne 'unknown') {
        $has_valid_session = 1;
    } elsif (ref($roles) eq 'ARRAY' && @$roles > 0) {
        # If we have actual roles but no username, try to get username from user object
        $username = ($c->user ? $c->user->username : undef) || "user_id_$user_id";
        if ($username && $username ne 'user_id_none') {
            $has_valid_session = 1;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_admin_access',
                "Using fallback username '$username' for $action_name (roles exist but username missing)");
        }
    } elsif (!ref($roles) && $roles && $roles ne 'none') {
        # String roles (legacy format)
        $has_valid_session = 1;
    }
    
    unless ($has_valid_session) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'check_admin_access',
            "Access denied for $action_name: No valid session (username: $username, roles: $roles_str, user_id: $user_id)");
        return 0;
    }
    
    # Enhanced debug logging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_admin_access',
        "Session debug for $action_name - Username: '$username', SiteName: '$sitename', Roles: '$roles_str'");
    
    # Check for system/service users
    if ($username eq 'ai_assistant' || $username eq 'Shanta') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_admin_access',
            "Access granted for $action_name: User '$username' (bypass check)");
        return 1;
    }
    
    # Check for admin role using session data directly
    my $has_admin_role = 0;
    if (ref($roles) eq 'ARRAY') {
        $has_admin_role = grep { $_ eq 'admin' } @$roles;
    } elsif ($roles && ($roles eq 'admin' || $roles =~ /\badmin\b/i)) {
        $has_admin_role = 1;
    }
    
    if ($has_admin_role) {
        my $role_type = (ref($roles) eq 'ARRAY') ? join(',', grep { $_ eq 'admin' } @$roles) : $roles;
        my $admin_type = ($sitename eq 'CSC') ? 'CSC admin' : 'standard admin';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_admin_access',
            "Access granted for $action_name: User has admin role ($role_type) - $admin_type (Username: $username, SiteName: $sitename)");
        return 1;
    }
    
    # Access denied - log detailed information
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'check_admin_access',
        "Access denied for $action_name: Username: $username, SiteName: $sitename, Roles: $roles_str");
    
    return 0;
}

=head2 require_admin_access

Checks admin access and redirects to login if access is denied.
Returns 1 if access granted, 0 if redirected to login.

=cut

sub require_admin_access {
    my ($self, $c, $action_name) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'require_admin_access',
        "Checking admin access for action: $action_name");
    
    if ($self->check_admin_access($c, $action_name)) {
        return 1;
    }
    
    # Set error message and redirect to login
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'require_admin_access',
        "Redirecting to login for action: $action_name");
    $c->flash->{error_msg} = "You need to be an administrator to access this area.";
    $c->response->redirect($c->uri_for('/user/login', {
        destination => $c->req->uri
    }));
    
    return 0;
}

=head2 is_csc_admin

Helper method to check if user is a CSC admin specifically.

=cut

sub is_csc_admin {
    my ($self, $c) = @_;
    
    # CSC Admin check: SiteName = 'CSC' AND admin role
    # This identifies the system-level administrator
    my $username = $c->session->{username} || ($c->user ? $c->user->username : undef) || '';
    return 1 if $username eq 'Shanta';

    my $roles = $c->session->{roles} || [];
    my $has_admin_role = 0;
    if (ref($roles) eq 'ARRAY') {
        $has_admin_role = grep { $_ eq 'admin' } @$roles;
    } elsif ($roles && ($roles eq 'admin' || $roles =~ /\badmin\b/i)) {
        $has_admin_role = 1;
    }
    
    return ($c->session->{SiteName} && 
            $c->session->{SiteName} eq 'CSC' && 
            $has_admin_role);
}

=head2 administers_site

    $admin_auth->administers_site($c, $sitename)

Site-scoped authorisation check. Returns 1 when the logged-in user is entitled to
administer the named SiteName, 0 otherwise.

Rules (ACCON Ph.1a):

=over

=item * CSC admin — entitled for ALL sites.

=item * SiteName owner / site admin — entitled for THEIR OWN site only. Proven by an
active row in C<user_site_roles> (role admin|site_admin|accounting) for that site,
or by being the hosting-account contact for that site.

=item * A global 'admin' role alone is NOT sufficient for a site the user is not
attached to — that was the hole this method closes.

=back

=cut

sub administers_site {
    my ($self, $c, $sitename) = @_;

    return 0 unless defined $sitename && length $sitename;

    # CSC admin (and the system/bootstrap user) may act on every site
    return 1 if $self->is_csc_admin($c);

    my $username = $c->session->{username} || ($c->user ? $c->user->username : undef) || '';
    return 1 if $username eq 'ai_assistant';

    my $user_id = $c->session->{user_id} || ($c->user ? eval { $c->user->id } : undef);

    # Resolve user_id from username if the session did not carry it
    if (!$user_id && $username) {
        eval {
            my $u = $c->model('DBEncy')->resultset('User')->search({ username => $username })->first;
            $user_id = $u->id if $u;
        };
    }
    unless ($user_id) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'administers_site',
            "Denied: cannot resolve user_id for '$username' (site '$sitename')");
        return 0;
    }

    my $entitled = 0;

    eval {
        my $schema   = $c->model('DBEncy');
        my $site_obj = $schema->resultset('Site')->search({ name => $sitename })->first;

        if ($site_obj) {
            my $count = $schema->resultset('UserSiteRole')->search({
                user_id   => $user_id,
                site_id   => $site_obj->id,
                role      => { -in => [qw(admin site_admin accounting)] },
                is_active => 1,
            })->count;
            $entitled = 1 if $count;
        }

        # Hosting-account contact for the site is treated as the site owner
        unless ($entitled) {
            my $hosting = $schema->resultset('Accounting::HostingAccount')->search(
                { sitename => $sitename }, { rows => 1 })->single;
            if ($hosting && $hosting->contact_email) {
                my $user_obj = $schema->resultset('User')->find($user_id);
                $entitled = 1
                    if $user_obj && $user_obj->email
                    && lc($user_obj->email) eq lc($hosting->contact_email);
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'administers_site',
            "Site entitlement lookup failed for '$username' on '$sitename': $@");
        return 0;
    }

    $self->logging->log_with_details($c, ($entitled ? 'info' : 'warn'), __FILE__, __LINE__,
        'administers_site',
        ($entitled ? 'Granted' : 'Denied') . ": user '$username' (id $user_id) on site '$sitename'");

    return $entitled ? 1 : 0;
}

=head2 require_site_admin

Like C<administers_site> but sets a flash error and redirects to login when the
check fails. Returns 1 on success, 0 after redirecting.

=cut

sub require_site_admin {
    my ($self, $c, $sitename, $action_name) = @_;

    $action_name ||= 'unknown_action';

    return 1 if $self->administers_site($c, $sitename);

    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'require_site_admin',
        "Access denied for $action_name on site '" . ($sitename // '') . "'");

    $c->flash->{error_msg} =
        "You are not authorised to administer site '" . ($sitename // '') . "'.";
    $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));

    return 0;
}

=head2 get_admin_type

Returns the type of admin: 'standard', 'csc', 'special', or 'none'

=cut

sub get_admin_type {
    my ($self, $c) = @_;
    
    my $username = $c->session->{username} || ($c->user ? $c->user->username : undef) || '';
    my $roles = $c->session->{roles} || [];
    my $sitename = $c->session->{SiteName} || '';
    
    if ($username eq 'ai_assistant' || $username eq 'Shanta') {
        return 'special';
    }
    
    my $has_admin_role = 0;
    if (ref($roles) eq 'ARRAY') {
        $has_admin_role = grep { $_ eq 'admin' } @$roles;
    } elsif ($roles && ($roles eq 'admin' || $roles =~ /\badmin\b/i)) {
        $has_admin_role = 1;
    }
    
    if ($has_admin_role) {
        if ($sitename eq 'CSC') {
            return 'csc';
        }
        return 'standard';
    }
    
    return 'none';
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Development Team

=head1 COPYRIGHT

Copyright (c) 2025 Computer System Consulting

=cut
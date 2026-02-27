package Comserv::Model::WorkShop;
use Moose;
use namespace::autoclean;
use Comserv::Util::AdminAuth;
use Comserv::Util::Logging;
use DateTime;

extends 'Catalyst::Model';

# In Model/WorkShop.pm
sub get_active_workshops {
    my ($self, $c) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'WorkShop' table
    my $rs = $schema->resultset('WorkShop');

    my @workshops;
    my $error;
    eval {
        my $admin_auth = Comserv::Util::AdminAuth->new();
        my $admin_type = $admin_auth->get_admin_type($c);
        my $sitename = $c->session->{SiteName};
        my $user_id = $c->session->{user_id};
        my $roles = $c->session->{roles} || [];
        my $is_workshop_leader = _has_workshop_leader_role($roles);
        
        # CSC admin (god-level) sees all non-draft workshops in the public listing.
        # Drafts are only visible in the Dashboard.
        if ($admin_type eq 'csc' || $admin_type eq 'special') {
            @workshops = $rs->search(
                {
                    'me.date'   => { '>=' => DateTime->today->ymd },
                    'me.status' => { '!=' => 'draft' },
                },
                { 
                    order_by => { -asc => 'me.date' },
                    prefetch => 'creator'
                }
            );
        } elsif ($admin_type eq 'standard' || $is_workshop_leader) {
            my $site_id;
            if ($sitename) {
                my $site = $schema->resultset('Site')->search({ name => $sitename })->first;
                $site_id = $site->id if $site;
            }
            
            my $search_filter = {
                'me.date' => { '>=' => DateTime->today->ymd },
            };
            
            if ($site_id) {
                $search_filter->{-or} = [
                    { 'me.share' => 'public', 'me.status' => 'published' },
                    { 'site_associations.site_id' => $site_id, 'me.status' => 'published' },
                    { 'me.created_by' => $user_id }
                ];
            } else {
                $search_filter->{-or} = [
                    { 'me.share' => 'public', 'me.status' => 'published' },
                    { 'me.created_by' => $user_id }
                ];
            }
            
            @workshops = $rs->search(
                $search_filter,
                { 
                    order_by => { -asc => 'me.date' },
                    prefetch => 'creator',
                    join => 'site_associations',
                    distinct => 1
                }
            );
        } else {
            # Regular users see all non-draft past workshops they can access.
            my $site_id;
            if ($sitename) {
                my $site = $schema->resultset('Site')->search({ name => $sitename })->first;
                $site_id = $site->id if $site;
            }
            
            my $search_filter = {
                'me.date'   => { '>=' => DateTime->today->ymd },
                'me.status' => 'published',
            };
            
            if ($site_id) {
                $search_filter->{-or} = [
                    { 'me.share' => 'public' },
                    { 'site_associations.site_id' => $site_id }
                ];
            } else {
                $search_filter->{'me.share'} = 'public';
            }
            
            @workshops = $rs->search(
                $search_filter,
                { 
                    order_by => { -asc => 'me.date' },
                    prefetch => 'creator',
                    join => 'site_associations',
                    distinct => 1
                }
            );
        }
    };
    if ($@) {
        $error = "Error fetching active workshops: $@";
        my $logger = Comserv::Util::Logging->instance;
        $logger->log_with_details($c, 'error', __FILE__, __LINE__, 'get_active_workshops', $error);
    }

    return (\@workshops, $error);
}
sub get_workshop_by_id {
    my ($self, $c, $id) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'WorkShop' table
    my $rs = $schema->resultset('WorkShop');

    # Try to find the workshop by its ID
    my $workshop;
    eval {
        $workshop = $rs->find($id);
    };
    if ($@) {
        return (undef, "Error fetching workshop: $@");
    }

    return ($workshop, undef);
}

sub get_past_workshops {
    my ($self, $c) = @_;

    my $schema = $c->model('DBEncy');
    my $rs = $schema->resultset('WorkShop');

    my @workshops;
    my $error;
    eval {
        my $admin_auth = Comserv::Util::AdminAuth->new();
        my $admin_type = $admin_auth->get_admin_type($c);
        my $sitename = $c->session->{SiteName};
        my $user_id = $c->session->{user_id};
        my $roles = $c->session->{roles} || [];
        my $is_workshop_leader = _has_workshop_leader_role($roles);
        
        # CSC admin sees all past workshops.
        if ($admin_type eq 'csc' || $admin_type eq 'special') {
            @workshops = $rs->search(
                {
                    'me.date'   => { '<' => DateTime->today->ymd },
                },
                { 
                    order_by => { -desc => 'me.date' },
                    prefetch => 'creator'
                }
            );
        } elsif ($admin_type eq 'standard' || $is_workshop_leader) {
            my $site_id;
            if ($sitename) {
                my $site = $schema->resultset('Site')->search({ name => $sitename })->first;
                $site_id = $site->id if $site;
            }
            
            my $search_filter = {
                'me.date'   => { '<' => DateTime->today->ymd },
            };
            
            if ($site_id) {
                $search_filter->{-or} = [
                    { 'me.share' => 'public' },
                    { 'site_associations.site_id' => $site_id },
                    { 'me.created_by' => $user_id },
                ];
            } else {
                $search_filter->{-or} = [
                    { 'me.share' => 'public' },
                    { 'me.created_by' => $user_id },
                ];
            }
            
            @workshops = $rs->search(
                $search_filter,
                { 
                    order_by => { -desc => 'me.date' },
                    prefetch => 'creator',
                    join => 'site_associations',
                    distinct => 1
                }
            );
        } else {
            # Regular users see only published workshops
            my $site_id;
            if ($sitename) {
                my $site = $schema->resultset('Site')->search({ name => $sitename })->first;
                $site_id = $site->id if $site;
            }
            
            my $search_filter = {
                'me.date'   => { '<' => DateTime->today->ymd },
                'me.status' => { '!=' => 'draft' },
            };
            
            if ($site_id) {
                $search_filter->{-or} = [
                    { 'me.share' => 'public' },
                    { 'site_associations.site_id' => $site_id }
                ];
            } else {
                $search_filter->{'me.share'} = 'public';
            }
            
            @workshops = $rs->search(
                $search_filter,
                { 
                    order_by => { -desc => 'me.date' },
                    prefetch => 'creator',
                    join => 'site_associations',
                    distinct => 1
                }
            );
        }
    };
    if ($@) {
        $error = "Error fetching past workshops: $@";
        my $logger = Comserv::Util::Logging->instance;
        $logger->log_with_details($c, 'error', __FILE__, __LINE__, 'get_past_workshops', $error);
    }

    return (\@workshops, $error);
}

sub _normalize_roles {
    my ($roles) = @_;
    return () unless defined $roles;

    if (ref $roles eq 'ARRAY') {
        return map { lc($_ // '') } @$roles;
    }

    return map { lc($_) } grep { length $_ } map { s/^\s+|\s+$//gr } split(/\s*,\s*/, $roles);
}

sub _has_workshop_leader_role {
    my ($roles) = @_;
    my @normalized = _normalize_roles($roles);
    for my $role (@normalized) {
        return 1 if $role eq 'workshop_leader'
                 || $role eq 'workshop_leaders'
                 || $role eq 'workshopleader'
                 || $role eq 'workshopleaders';
    }
    return 0;
}

__PACKAGE__->meta->make_immutable;

1;

package Comserv::Model::WorkShop;
use Moose;
use namespace::autoclean;
use Comserv::Util::AdminAuth;

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
        
        # Check if user is workshop leader
        my $is_workshop_leader = 0;
        if (ref $roles eq 'ARRAY') {
            $is_workshop_leader = grep { $_ eq 'workshop_leader' } @$roles;
        }
        
        # CSC admin (god-level) sees all non-draft workshops in the public listing.
        # Drafts are only visible in the Dashboard.
        if ($admin_type eq 'csc' || $admin_type eq 'special') {
            @workshops = $rs->search(
                {
                    date   => { '>=' => DateTime->today->ymd },
                    status => { '!=' => 'draft' },
                },
                { 
                    order_by => { -asc => 'date' },
                    prefetch => 'creator'
                }
            );
        } elsif ($admin_type eq 'standard' || $is_workshop_leader) {
            # Site admin and workshop leaders see:
            # 1. All published workshops (public + their site)
            # 2. Their own draft workshops (in Dashboard only — excluded from index via status filter above)
            my $site_id;
            if ($sitename) {
                my $site = $schema->resultset('Site')->search({ name => $sitename })->first;
                $site_id = $site->id if $site;
            }
            
            my $search_filter = {
                date => { '>=' => DateTime->today->ymd },
                -or => [
                    { status => 'published' },
                    { created_by => $user_id }
                ]
            };
            
            if ($site_id) {
                $search_filter->{-or} = [
                    { share => 'public', status => 'published' },
                    { 'site_associations.site_id' => $site_id, status => 'published' },
                    { created_by => $user_id }
                ];
            } else {
                $search_filter->{-or} = [
                    { share => 'public', status => 'published' },
                    { created_by => $user_id }
                ];
            }
            
            @workshops = $rs->search(
                $search_filter,
                { 
                    order_by => { -asc => 'date' },
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
                date => { '>=' => DateTime->today->ymd },
                status => 'published',
            };
            
            if ($site_id) {
                $search_filter->{-or} = [
                    { share => 'public' },
                    { 'site_associations.site_id' => $site_id }
                ];
            } else {
                $search_filter->{share} = 'public';
            }
            
            @workshops = $rs->search(
                $search_filter,
                { 
                    order_by => { -asc => 'date' },
                    prefetch => 'creator',
                    join => 'site_associations',
                    distinct => 1
                }
            );
        }
    };
    if ($@) {
        $error = "Error fetching active workshops: $@";
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
        
        # Check if user is workshop leader
        my $is_workshop_leader = 0;
        if (ref $roles eq 'ARRAY') {
            $is_workshop_leader = grep { $_ eq 'workshop_leader' } @$roles;
        }
        
        # CSC admin sees all non-draft past workshops in the public listing.
        # Drafts are only visible in the Dashboard.
        if ($admin_type eq 'csc' || $admin_type eq 'special') {
            @workshops = $rs->search(
                {
                    date   => { '<' => DateTime->today->ymd },
                    status => { '!=' => 'draft' },
                },
                { 
                    order_by => { -desc => 'date' },
                    prefetch => 'creator'
                }
            );
        } elsif ($admin_type eq 'standard' || $is_workshop_leader) {
            # Site admin and workshop leaders see published workshops from their site
            # (drafts belong in the Dashboard, not the public listing)
            my $site_id;
            if ($sitename) {
                my $site = $schema->resultset('Site')->search({ name => $sitename })->first;
                $site_id = $site->id if $site;
            }
            
            my $search_filter = {
                date   => { '<' => DateTime->today->ymd },
                status => { '!=' => 'draft' },
            };
            
            if ($site_id) {
                $search_filter->{-or} = [
                    { share => 'public', status => 'published' },
                    { 'site_associations.site_id' => $site_id, status => 'published' },
                ];
            } else {
                $search_filter->{-or} = [
                    { share => 'public', status => 'published' },
                ];
            }
            
            @workshops = $rs->search(
                $search_filter,
                { 
                    order_by => { -desc => 'date' },
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
                date => { '<' => DateTime->today->ymd },
                status => 'published',
            };
            
            if ($site_id) {
                $search_filter->{-or} = [
                    { share => 'public' },
                    { 'site_associations.site_id' => $site_id }
                ];
            } else {
                $search_filter->{share} = 'public';
            }
            
            @workshops = $rs->search(
                $search_filter,
                { 
                    order_by => { -desc => 'date' },
                    prefetch => 'creator',
                    join => 'site_associations',
                    distinct => 1
                }
            );
        }
    };
    if ($@) {
        $error = "Error fetching past workshops: $@";
    }

    return (\@workshops, $error);
}

__PACKAGE__->meta->make_immutable;

1;

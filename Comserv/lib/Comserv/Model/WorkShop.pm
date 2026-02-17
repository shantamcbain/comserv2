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
        
        # CSC admin (god-level) sees all workshops
        if ($admin_type eq 'csc' || $admin_type eq 'special') {
            @workshops = $rs->search(
                {
                    date => { '>=' => DateTime->today->ymd },
                },
                { 
                    order_by => { -asc => 'date' },
                    prefetch => 'creator'
                }
            );
        } else {
            # Get site_id from session or sites table
            my $site_id;
            if ($sitename) {
                my $site = $schema->resultset('Site')->search({ name => $sitename })->first;
                $site_id = $site->id if $site;
            }
            
            # Site admin and regular users see:
            # 1. Public workshops (share='public')
            # 2. Workshops associated with their site via site_workshop table
            my $search_filter = {
                date => { '>=' => DateTime->today->ymd },
            };
            
            if ($site_id) {
                $search_filter->{-or} = [
                    { share => 'public' },
                    { 'site_associations.site_id' => $site_id }
                ];
            } else {
                # If no site_id, only show public workshops
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
        
        # CSC admin (god-level) sees all workshops
        if ($admin_type eq 'csc' || $admin_type eq 'special') {
            @workshops = $rs->search(
                {
                    date => { '<' => DateTime->today->ymd },
                },
                { 
                    order_by => { -desc => 'date' },
                    prefetch => 'creator'
                }
            );
        } else {
            # Get site_id from session or sites table
            my $site_id;
            if ($sitename) {
                my $site = $schema->resultset('Site')->search({ name => $sitename })->first;
                $site_id = $site->id if $site;
            }
            
            # Site admin and regular users see:
            # 1. Public workshops (share='public')
            # 2. Workshops associated with their site via site_workshop table
            my $search_filter = {
                date => { '<' => DateTime->today->ymd },
            };
            
            if ($site_id) {
                $search_filter->{-or} = [
                    { share => 'public' },
                    { 'site_associations.site_id' => $site_id }
                ];
            } else {
                # If no site_id, only show public workshops
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

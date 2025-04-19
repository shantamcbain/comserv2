package Comserv::Controller::Navigation;
use Moose;
use namespace::autoclean;
use Data::Dumper;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::Navigation - Catalyst Controller for navigation components

=head1 DESCRIPTION

This controller handles database queries for navigation components,
replacing the direct DBI usage in templates with proper model usage.

=cut

# Method to get internal links for a specific category and site
sub get_internal_links {
    my ($self, $c, $category, $site_name) = @_;
    
    $c->log->debug("Getting internal links for category: $category, site: $site_name");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        # Get the database handle from the DBEncy model
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        
        # Prepare and execute the query
        my $query = "SELECT * FROM internal_links_tb WHERE category = ? AND (sitename = ? OR sitename = 'All') ORDER BY link_order";
        my $sth = $dbh->prepare($query);
        $sth->execute($category, $site_name);
        
        # Fetch all results
        while (my $row = $sth->fetchrow_hashref) {
            push @results, $row;
        }
        
        $c->log->debug("Found " . scalar(@results) . " internal links");
    };
    if ($@) {
        $c->log->error("Error getting internal links: $@");
    }
    
    return \@results;
}

# Method to get pages for a specific menu and site
sub get_pages {
    my ($self, $c, $menu, $site_name, $status) = @_;
    
    $status //= 2; # Default status is 2 (active)
    
    $c->log->debug("Getting pages for menu: $menu, site: $site_name, status: $status");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        # Get the database handle from the DBEncy model
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        
        # Prepare and execute the query
        my $query = "SELECT * FROM page_tb WHERE menu = ? AND status = ? AND (sitename = ? OR sitename = 'All') ORDER BY link_order";
        my $sth = $dbh->prepare($query);
        $sth->execute($menu, $status, $site_name);
        
        # Fetch all results
        while (my $row = $sth->fetchrow_hashref) {
            push @results, $row;
        }
        
        $c->log->debug("Found " . scalar(@results) . " pages");
    };
    if ($@) {
        $c->log->error("Error getting pages: $@");
    }
    
    return \@results;
}

# Method to get admin pages
sub get_admin_pages {
    my ($self, $c, $site_name) = @_;
    
    $c->log->debug("Getting admin pages for site: $site_name");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        # Get the database handle from the DBEncy model
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        
        # Prepare and execute the query
        my $query = "SELECT * FROM page_tb WHERE (menu = 'Admin' AND status = 2) AND (sitename = ? OR sitename = 'All') ORDER BY link_order";
        my $sth = $dbh->prepare($query);
        $sth->execute($site_name);
        
        # Fetch all results
        while (my $row = $sth->fetchrow_hashref) {
            push @results, $row;
        }
        
        $c->log->debug("Found " . scalar(@results) . " admin pages");
    };
    if ($@) {
        $c->log->error("Error getting admin pages: $@");
    }
    
    return \@results;
}

# Method to get admin links
sub get_admin_links {
    my ($self, $c, $site_name) = @_;
    
    $c->log->debug("Getting admin links for site: $site_name");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        # Get the database handle from the DBEncy model
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        
        # Prepare and execute the query
        my $query = "SELECT * FROM internal_links_tb WHERE category = 'Admin_links' AND (sitename = ? OR sitename = 'All') ORDER BY link_order";
        my $sth = $dbh->prepare($query);
        $sth->execute($site_name);
        
        # Fetch all results
        while (my $row = $sth->fetchrow_hashref) {
            push @results, $row;
        }
        
        $c->log->debug("Found " . scalar(@results) . " admin links");
    };
    if ($@) {
        $c->log->error("Error getting admin links: $@");
    }
    
    return \@results;
}

# Method to populate navigation data in the stash
sub populate_navigation_data {
    my ($self, $c) = @_;
    
    # Use eval to catch any errors
    eval {
        my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
        $c->log->debug("Populating navigation data for site: $site_name");
        
        # Populate member links
        $c->stash->{member_links} = $self->get_internal_links($c, 'Member_links', $site_name);
        $c->stash->{member_pages} = $self->get_pages($c, 'member', $site_name);
        
        # Populate main links
        $c->stash->{main_links} = $self->get_internal_links($c, 'Main_links', $site_name);
        $c->stash->{main_pages} = $self->get_pages($c, 'Main', $site_name);
        
        # Populate hosted links
        $c->stash->{hosted_links} = $self->get_internal_links($c, 'Hosted_link', $site_name);
        
        # Populate admin links and pages
        if ($c->session->{group} && $c->session->{group} eq 'admin') {
            $c->stash->{admin_pages} = $self->get_admin_pages($c, $site_name);
            $c->stash->{admin_links} = $self->get_admin_links($c, $site_name);
        }
        
        $c->log->debug("Navigation data populated successfully");
    };
    if ($@) {
        $c->log->error("Error populating navigation data: $@");
    }
}

# Auto method to populate navigation data for all requests
sub auto :Private {
    my ($self, $c) = @_;
    
    # Use eval to catch any errors
    eval {
        $self->populate_navigation_data($c);
    };
    if ($@) {
        $c->log->error("Error in Navigation auto method: $@");
    }
    
    return 1; # Allow the request to proceed
}

__PACKAGE__->meta->make_immutable;

1;
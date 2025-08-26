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
        # Try to use the DBIx::Class API first
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search({
            category => $category,
            sitename => [ $site_name, 'All' ]
        }, {
            order_by => { -asc => 'link_order' }
        });
        
        while (my $row = $rs->next) {
            push @results, { $row->get_columns };
        }
        
        # If no results and we might need to fall back to direct SQL
        if (!@results) {
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
        # Try to use the DBIx::Class API first
        my $rs = $c->model('DBEncy')->resultset('PageTb')->search({
            menu => $menu,
            status => $status,
            sitename => [ $site_name, 'All' ]
        }, {
            order_by => { -asc => 'link_order' }
        });
        
        while (my $row = $rs->next) {
            push @results, { $row->get_columns };
        }
        
        # If no results and we might need to fall back to direct SQL
        if (!@results) {
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
        # Try to use the DBIx::Class API first
        my $rs = $c->model('DBEncy')->resultset('PageTb')->search({
            menu => 'Admin',
            status => 2,
            sitename => [ $site_name, 'All' ]
        }, {
            order_by => { -asc => 'link_order' }
        });
        
        while (my $row = $rs->next) {
            push @results, { $row->get_columns };
        }
        
        # If no results and we might need to fall back to direct SQL
        if (!@results) {
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
        # Try to use the DBIx::Class API first
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search({
            category => 'Admin_links',
            sitename => [ $site_name, 'All' ]
        }, {
            order_by => { -asc => 'link_order' }
        });
        
        while (my $row = $rs->next) {
            push @results, { $row->get_columns };
        }
        
        # If no results and we might need to fall back to direct SQL
        if (!@results) {
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
        
        # Ensure tables exist before querying them
        my $db_model = $c->model('DBEncy');
        my $schema = $db_model->schema;
        
        # Check if tables exist in the database
        my $dbh = $schema->storage->dbh;
        my $tables = $db_model->list_tables();
        my $internal_links_exists = grep { $_ eq 'internal_links_tb' } @$tables;
        my $page_tb_exists = grep { $_ eq 'page_tb' } @$tables;
        
        # If tables don't exist, try to create them
        if (!$internal_links_exists || !$page_tb_exists) {
            $c->log->debug("Navigation tables don't exist. Attempting to create them.");
            
            # Create tables if they don't exist
            $db_model->create_table_from_result('InternalLinksTb', $schema, $c);
            $db_model->create_table_from_result('PageTb', $schema, $c);
            
            # Check if tables were created successfully
            $tables = $db_model->list_tables();
            $internal_links_exists = grep { $_ eq 'internal_links_tb' } @$tables;
            $page_tb_exists = grep { $_ eq 'page_tb' } @$tables;
            
            # If tables still don't exist, try to create them using SQL files
            if (!$internal_links_exists || !$page_tb_exists) {
                $c->log->debug("Creating tables from SQL files.");
                
                # Try to execute SQL files
                if (!$internal_links_exists) {
                    my $sql_file = $c->path_to('sql', 'internal_links_tb.sql')->stringify;
                    if (-e $sql_file) {
                        my $sql = do { local (@ARGV, $/) = $sql_file; <> };
                        my @statements = split /;/, $sql;
                        foreach my $statement (@statements) {
                            $statement =~ s/^\s+|\s+$//g;  # Trim whitespace
                            next unless $statement;  # Skip empty statements
                            eval { $dbh->do($statement); };
                            if ($@) {
                                $c->log->error("Error executing SQL: $@");
                            }
                        }
                    } else {
                        $c->log->error("SQL file not found: $sql_file");
                    }
                }
                
                if (!$page_tb_exists) {
                    my $sql_file = $c->path_to('sql', 'page_tb.sql')->stringify;
                    if (-e $sql_file) {
                        my $sql = do { local (@ARGV, $/) = $sql_file; <> };
                        my @statements = split /;/, $sql;
                        foreach my $statement (@statements) {
                            $statement =~ s/^\s+|\s+$//g;  # Trim whitespace
                            next unless $statement;  # Skip empty statements
                            eval { $dbh->do($statement); };
                            if ($@) {
                                $c->log->error("Error executing SQL: $@");
                            }
                        }
                    } else {
                        $c->log->error("SQL file not found: $sql_file");
                    }
                }
            }
        }
        
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
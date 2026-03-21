package Comserv::Model::ApiaryModel;
use Moose;
use namespace::autoclean;
use DateTime;

extends 'Catalyst::Model';

=head1 NAME

Comserv::Model::ApiaryModel - Model for Apiary operations

=head1 DESCRIPTION

This model provides methods for managing bee operations, including queens, frames, yards, and hives.

=head1 METHODS

=head2 get_frames_for_queen

Retrieves all frames associated with a specific queen.

=cut

sub get_frames_for_queen {
    my ($self, $queen_tag_number) = @_;

    my @frames;
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;

        # Get a DBIx::Class::ResultSet object for the 'Frame' table
        my $rs = $schema->resultset('Frame');

        # Fetch the frames for the given queen
        @frames = $rs->search({ queen_id => $queen_tag_number });
    };
    if ($@) {
        # An error occurred, handle it here
        warn "An error occurred while fetching frames for queen: $@";
        return;
    }

    return \@frames;
}

=head2 get_yards_for_site

Retrieves all bee yards associated with a specific site.

=cut

sub get_yards_for_site {
    my ($self, $site_name) = @_;

    my @yards;
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;

        # Get a DBIx::Class::ResultSet object for the 'ApisYardsTb' table
        my $rs = $schema->resultset('ApisYardsTb');

        # Fetch all yards for the given site
        @yards = $rs->search({ sitename => $site_name });
    };
    if ($@) {
        # An error occurred, handle it here
        warn "An error occurred while fetching yards: $@";
        return;
    }

    return \@yards;
}

=head2 get_hives_for_yard

Retrieves all hives in a specific yard.

=cut

sub get_hives_for_yard {
    my ($self, $yard_id) = @_;

    my @hives;
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;

        # Get a DBIx::Class::ResultSet object for the 'Hive' table
        my $rs = $schema->resultset('Hive');

        # Fetch all hives for the given yard
        @hives = $rs->search({ yard_id => $yard_id });
    };
    if ($@) {
        # An error occurred, handle it here
        warn "An error occurred while fetching hives for yard: $@";
        return;
    }

    return \@hives;
}

=head2 get_queens_for_hive

Retrieves all queens associated with a specific hive.

=cut

sub get_queens_for_hive {
    my ($self, $hive_id) = @_;

    my @queens;
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;

        # Get a DBIx::Class::ResultSet object for the 'Queen' table
        my $rs = $schema->resultset('Queen');

        # Fetch all queens for the given hive
        @queens = $rs->search({ hive_id => $hive_id });
    };
    if ($@) {
        # An error occurred, handle it here
        warn "An error occurred while fetching queens for hive: $@";
        return;
    }

    return \@queens;
}

=head2 get_hive_statistics

Retrieves statistics about hives (total count, healthy count, etc.)

=cut

sub get_hive_statistics {
    my ($self) = @_;
    
    my $stats = { total => 0, healthy => 0 };
    
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;
        
        # Get a DBIx::Class::ResultSet object for the 'Hive' table
        my $rs = $schema->resultset('Hive');
        
        # Count total hives
        $stats->{total} = $rs->count();
        
        # Count healthy hives (assuming there's a status field)
        $stats->{healthy} = $rs->search({ status => 'healthy' })->count();
    };
    
    if ($@) {
        warn "An error occurred while fetching hive statistics: $@";
        return undef;
    }
    
    return $stats;
}

=head2 get_recent_inspections

Retrieves recent inspections within the specified number of days

=cut

sub get_recent_inspections {
    my ($self, $days) = @_;
    $days ||= 7; # Default to 7 days
    
    my @inspections;
    
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;
        
        # Calculate date threshold
        my $date_threshold = DateTime->now->subtract(days => $days)->ymd;
        
        # Get a DBIx::Class::ResultSet object for the 'Inspection' table
        my $rs = $schema->resultset('Inspection');
        
        # Fetch recent inspections
        @inspections = $rs->search({
            inspection_date => { '>=' => $date_threshold }
        });
    };
    
    if ($@) {
        warn "An error occurred while fetching recent inspections: $@";
        return undef;
    }
    
    return \@inspections;
}

=head2 get_todo_statistics

Retrieves statistics about todos (pending count, overdue count, etc.)

=cut

sub get_todo_statistics {
    my ($self) = @_;
    
    my $stats = { pending => 0, overdue => 0 };
    
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;
        
        # Get a DBIx::Class::ResultSet object for the 'Todo' table
        my $rs = $schema->resultset('Todo');
        
        # Count pending todos
        $stats->{pending} = $rs->search({ status => 'pending' })->count();
        
        # Count overdue todos (assuming there's a due_date field)
        my $today = DateTime->now->ymd;
        $stats->{overdue} = $rs->search({
            status => 'pending',
            due_date => { '<' => $today }
        })->count();
    };
    
    if ($@) {
        warn "An error occurred while fetching todo statistics: $@";
        return undef;
    }
    
    return $stats;
}

=head2 get_low_stock_items

Retrieves inventory items that are low in stock

=cut

sub get_low_stock_items {
    my ($self) = @_;
    
    my @low_stock_items;
    
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $self->schema;
        
        # Get a DBIx::Class::ResultSet object for the 'Inventory' table
        my $rs = $schema->resultset('Inventory');
        
        # Fetch items where current stock is below minimum threshold
        @low_stock_items = $rs->search({
            -or => [
                { current_stock => { '<' => \'minimum_stock' } },
                { current_stock => { '<=' => 5 } } # Default threshold
            ]
        });
    };
    
    if ($@) {
        warn "An error occurred while fetching low stock items: $@";
        return undef;
    }
    
    return \@low_stock_items;
}

__PACKAGE__->meta->make_immutable;

1;
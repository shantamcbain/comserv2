package Comserv::Model::Schema::Ency::Result::QueenEnhanced;
use base 'DBIx::Class::Core';

__PACKAGE__->table('queens_enhanced');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    tag_number => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
    },
    birth_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    introduction_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    removal_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    breed => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    genetic_line => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        comment => 'Genetic lineage or breeding line',
    },
    color_marking => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
        comment => 'Physical color marking on queen',
    },
    origin => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        comment => 'Source/breeder of queen',
    },
    parent_queen_id => {
        data_type => 'integer',
        is_nullable => 1,
        comment => 'Mother queen for genetic tracking',
    },
    drone_source => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        comment => 'Source of drone genetics',
    },
    mating_status => {
        data_type => 'enum',
        extra => {
            list => [qw/virgin mated laying drone_layer superseded missing dead/]
        },
        default_value => 'virgin',
    },
    laying_status => {
        data_type => 'enum',
        extra => {
            list => [qw/laying_well laying_poor not_laying drone_layer superseded missing/]
        },
        is_nullable => 1,
    },
    performance_rating => {
        data_type => 'integer',
        is_nullable => 1,
        comment => 'Performance rating 1-10',
    },
    temperament_rating => {
        data_type => 'enum',
        extra => {
            list => [qw/calm moderate aggressive very_aggressive/]
        },
        default_value => 'calm',
    },
    health_status => {
        data_type => 'enum',
        extra => {
            list => [qw/healthy diseased injured missing dead/]
        },
        default_value => 'healthy',
    },
    current_yard_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    current_pallet_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    current_position => {
        data_type => 'integer',
        is_nullable => 1,
        comment => 'Position on pallet',
    },
    current_hive_configuration_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    purpose => {
        data_type => 'enum',
        extra => {
            list => [qw/production breeding replacement sale research/]
        },
        default_value => 'production',
    },
    acquisition_cost => {
        data_type => 'decimal',
        size => [8,2],
        is_nullable => 1,
    },
    acquisition_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    status => {
        data_type => 'enum',
        extra => {
            list => [qw/active inactive sold dead missing/]
        },
        default_value => 'active',
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
    },
    created_by => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    updated_by => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(
    unique_tag_number => ['tag_number'],
);

# Relationships
__PACKAGE__->belongs_to(
    'parent_queen',
    'Comserv::Model::Schema::Ency::Result::QueenEnhanced',
    'parent_queen_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->has_many(
    'offspring_queens',
    'Comserv::Model::Schema::Ency::Result::QueenEnhanced',
    'parent_queen_id',
    { cascade_delete => 0 }
);

__PACKAGE__->belongs_to(
    'current_yard',
    'Comserv::Model::Schema::Ency::Result::Yard',
    'current_yard_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'current_pallet',
    'Comserv::Model::Schema::Ency::Result::Pallet',
    'current_pallet_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'current_hive_configuration',
    'Comserv::Model::Schema::Ency::Result::HiveConfiguration',
    'current_hive_configuration_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->has_many(
    'hive_configuration_history',
    'Comserv::Model::Schema::Ency::Result::HiveConfigurationHistory',
    'queen_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'queen_movements',
    'Comserv::Model::Schema::Ency::Result::QueenMovement',
    'queen_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'inspections',
    'Comserv::Model::Schema::Ency::Result::InspectionEnhanced',
    'queen_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'production_records',
    'Comserv::Model::Schema::Ency::Result::ProductionRecord',
    'queen_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'product_movements',
    'Comserv::Model::Schema::Ency::Result::ProductMovement',
    'queen_id'
);

# Custom methods
sub display_name {
    my $self = shift;
    my $name = $self->tag_number;
    $name .= " (" . $self->genetic_line . ")" if $self->genetic_line;
    return $name;
}

sub current_location {
    my $self = shift;
    return unless $self->current_yard && $self->current_pallet;
    
    return sprintf("%s - %s - Position %d",
        $self->current_yard->name,
        $self->current_pallet->code,
        $self->current_position || 0
    );
}

sub age_in_days {
    my $self = shift;
    return unless $self->birth_date;
    
    use DateTime;
    my $birth = DateTime->new(
        year => substr($self->birth_date, 0, 4),
        month => substr($self->birth_date, 5, 2),
        day => substr($self->birth_date, 8, 2)
    );
    
    return DateTime->now->delta_days($birth)->days;
}

sub is_productive {
    my $self = shift;
    return $self->laying_status && $self->laying_status eq 'laying_well';
}

sub needs_attention {
    my $self = shift;
    return $self->health_status ne 'healthy' ||
           $self->laying_status =~ /^(not_laying|drone_layer|superseded)$/ ||
           $self->mating_status eq 'missing';
}

sub genetic_family_tree {
    my $self = shift;
    my $depth = shift || 3;
    
    my @ancestors;
    my $current = $self;
    
    for my $level (1..$depth) {
        last unless $current->parent_queen;
        $current = $current->parent_queen;
        push @ancestors, {
            level => $level,
            queen => $current,
            tag => $current->tag_number,
            genetic_line => $current->genetic_line,
        };
    }
    
    return \@ancestors;
}

sub offspring_count {
    my $self = shift;
    return $self->offspring_queens->count;
}

sub latest_inspection {
    my $self = shift;
    return $self->inspections->search(
        {},
        { 
            order_by => { -desc => 'inspection_date' },
            rows => 1 
        }
    )->first;
}

sub production_summary {
    my $self = shift;
    my $year = shift || (localtime)[5] + 1900;
    
    return $self->production_records->search(
        { 
            'me.created_at' => { 
                '>=' => "$year-01-01",
                '<=' => "$year-12-31"
            }
        },
        {
            select => [
                'product_type',
                { sum => 'quantity' },
                { count => 'id' }
            ],
            as => ['product_type', 'total_quantity', 'record_count'],
            group_by => 'product_type'
        }
    );
}

sub movement_history {
    my $self = shift;
    my $limit = shift || 10;
    
    return $self->queen_movements->search(
        {},
        {
            order_by => { -desc => 'movement_date' },
            rows => $limit,
            prefetch => ['from_yard', 'to_yard', 'from_pallet', 'to_pallet']
        }
    );
}

sub configuration_changes {
    my $self = shift;
    my $limit = shift || 10;
    
    return $self->hive_configuration_history->search(
        {},
        {
            order_by => { -desc => 'change_date' },
            rows => $limit,
            prefetch => 'hive_configuration'
        }
    );
}

sub performance_metrics {
    my $self = shift;
    my $year = shift || (localtime)[5] + 1900;
    
    # Calculate various performance metrics
    my $inspections = $self->inspections->search({
        'me.inspection_date' => {
            '>=' => "$year-01-01",
            '<=' => "$year-12-31"
        }
    });
    
    my $total_inspections = $inspections->count;
    return {} unless $total_inspections;
    
    my $good_inspections = $inspections->search({
        overall_status => { -in => ['excellent', 'good'] }
    })->count;
    
    my $production = $self->production_summary($year);
    my %production_totals;
    while (my $record = $production->next) {
        $production_totals{$record->get_column('product_type')} = $record->get_column('total_quantity');
    }
    
    return {
        total_inspections => $total_inspections,
        good_inspection_rate => sprintf("%.1f", ($good_inspections / $total_inspections) * 100),
        honey_production => $production_totals{honey} || 0,
        queen_cells_produced => $production_totals{queen_cells} || 0,
        performance_score => $self->calculate_performance_score(),
    };
}

sub calculate_performance_score {
    my $self = shift;
    
    my $score = 0;
    
    # Base score from performance rating
    $score += ($self->performance_rating || 5) * 10;
    
    # Laying status bonus/penalty
    if ($self->laying_status) {
        $score += 20 if $self->laying_status eq 'laying_well';
        $score += 10 if $self->laying_status eq 'laying_poor';
        $score -= 30 if $self->laying_status eq 'not_laying';
        $score -= 50 if $self->laying_status eq 'drone_layer';
    }
    
    # Temperament adjustment
    if ($self->temperament_rating) {
        $score += 10 if $self->temperament_rating eq 'calm';
        $score -= 10 if $self->temperament_rating eq 'aggressive';
        $score -= 20 if $self->temperament_rating eq 'very_aggressive';
    }
    
    # Health status
    $score -= 20 if $self->health_status ne 'healthy';
    
    # Age factor (peak performance typically 1-2 years)
    my $age_days = $self->age_in_days;
    if ($age_days) {
        if ($age_days > 365 && $age_days < 730) {
            $score += 10; # Prime age bonus
        } elsif ($age_days > 1095) {
            $score -= 15; # Old age penalty
        }
    }
    
    return $score > 100 ? 100 : ($score < 0 ? 0 : $score);
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::QueenEnhanced - Enhanced Queen tracking with comprehensive lifecycle management

=head1 DESCRIPTION

This enhanced queen model provides comprehensive tracking of queen bees throughout their lifecycle,
including genetic lineage, performance metrics, location history, and production records. This is
the central entity in the queen-centric apiary management system.

Key features:
- Genetic family tree tracking
- Performance scoring and metrics
- Location and movement history
- Production record integration
- Lifecycle status management
- Breeding program support

=head1 RELATIONSHIPS

- parent_queen: Genetic mother for breeding records
- offspring_queens: All queens bred from this queen
- current_yard/pallet: Current physical location
- current_hive_configuration: Current hive setup
- hive_configuration_history: All configuration changes
- queen_movements: Location change history
- inspections: All inspection records
- production_records: All products created/harvested
- product_movements: Product transfer history

=cut
package Comserv::Model::Schema::Ency::Result::Inspection;
use base 'DBIx::Class::Core';

__PACKAGE__->table('inspections');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    hive_id => {
        data_type => 'integer',
    },
    inspection_date => {
        data_type => 'date',
    },
    start_time => {
        data_type => 'time',
        is_nullable => 1,
    },
    end_time => {
        data_type => 'time',
        is_nullable => 1,
    },
    weather_conditions => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    temperature => {
        data_type => 'decimal',
        size => [5,2],
        is_nullable => 1,
    },
    queen_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → queens — queen confirmed present during this inspection (nullable)',
    },
    inspector => {
        data_type => 'varchar',
        size => 50,
    },
    inspection_type => {
        data_type => 'enum',
        extra => {
            list => [qw/routine disease_check harvest treatment emergency queen_check/]
        },
        default_value => 'routine',
    },
    overall_status => {
        data_type => 'enum',
        extra => {
            list => [qw/excellent good fair poor critical/]
        },
        default_value => 'good',
    },
    queen_seen => {
        data_type => 'boolean',
        default_value => 0,
    },
    queen_marked => {
        data_type => 'boolean',
        default_value => 0,
    },
    eggs_seen => {
        data_type => 'boolean',
        default_value => 0,
    },
    larvae_seen => {
        data_type => 'boolean',
        default_value => 0,
    },
    capped_brood_seen => {
        data_type => 'boolean',
        default_value => 0,
    },
    supersedure_cells => {
        data_type => 'integer',
        default_value => 0,
    },
    swarm_cells => {
        data_type => 'integer',
        default_value => 0,
    },
    queen_cells => {
        data_type => 'integer',
        default_value => 0,
    },
    population_estimate => {
        data_type => 'enum',
        extra => {
            list => [qw/very_strong strong moderate weak very_weak/]
        },
        is_nullable => 1,
    },
    temperament => {
        data_type => 'enum',
        extra => {
            list => [qw/calm moderate aggressive very_aggressive/]
        },
        default_value => 'calm',
    },
    general_notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    action_required => {
        data_type => 'text',
        is_nullable => 1,
    },
    next_inspection_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    feeding_done => {
        data_type     => 'boolean',
        default_value => 0,
        comment       => 'Whether feeding was performed during this inspection',
    },
    feed_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
        comment     => 'Type of feed provided (syrup, fondant, pollen substitute, etc.)',
    },
    feed_amount => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
        comment     => 'Amount of feed provided (e.g. 1L, 500g)',
    },
    boosted_from_hive => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → hives — hive from which frames/bees were donated to boost this hive',
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

# Relationships
__PACKAGE__->belongs_to(
    'hive',
    'Comserv::Model::Schema::Ency::Result::Hive',
    'hive_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'queen',
    'Comserv::Model::Schema::Ency::Result::Queen',
    'queen_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->has_many(
    'inspection_details',
    'Comserv::Model::Schema::Ency::Result::InspectionDetail',
    'inspection_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'inspection_feedings',
    'Comserv::Model::Schema::Ency::Result::InspectionFeeding',
    'inspection_id',
    { cascade_delete => 1 }
);

__PACKAGE__->belongs_to(
    'boosted_hive',
    'Comserv::Model::Schema::Ency::Result::Hive',
    'boosted_from_hive',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

# Custom methods
sub duration_minutes {
    my $self = shift;
    return unless $self->start_time && $self->end_time;
    
    my ($start_h, $start_m) = split /:/, $self->start_time;
    my ($end_h, $end_m) = split /:/, $self->end_time;
    
    my $start_minutes = $start_h * 60 + $start_m;
    my $end_minutes = $end_h * 60 + $end_m;
    
    return $end_minutes - $start_minutes;
}

sub queen_status {
    my $self = shift;
    if ($self->queen_seen) {
        return $self->queen_marked ? 'seen_marked' : 'seen_unmarked';
    }
    return 'not_seen';
}

sub brood_status {
    my $self = shift;
    my @stages;
    push @stages, 'eggs' if $self->eggs_seen;
    push @stages, 'larvae' if $self->larvae_seen;
    push @stages, 'capped' if $self->capped_brood_seen;
    return @stages ? join(', ', @stages) : 'none';
}

sub has_queen_issues {
    my $self = shift;
    return $self->supersedure_cells > 0 || 
           $self->swarm_cells > 0 || 
           (!$self->queen_seen && !$self->eggs_seen);
}

sub needs_attention {
    my $self = shift;
    return $self->overall_status =~ /^(poor|critical)$/ ||
           $self->has_queen_issues ||
           $self->action_required;
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::Inspection - Inspection table result class

=head1 DESCRIPTION

Represents individual hive inspections. Each inspection captures the overall state
of a hive at a specific point in time, replacing the time-based entries in the
legacy ApisQueenLogTb structure.

=cut
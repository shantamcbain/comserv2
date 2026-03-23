package Comserv::Model::Schema::Ency::Result::Hive;
use base 'DBIx::Class::Core';

__PACKAGE__->table('hives');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    hive_number => {
        data_type => 'varchar',
        size => 50,
    },
    yard_id => {
        data_type => 'integer',
    },
    pallet_code => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 1,
    },
    queen_code => {
        data_type => 'varchar',
        size => 30,
        is_nullable => 1,
    },
    status => {
        data_type => 'enum',
        extra => {
            list => [qw/active inactive dead split combined/]
        },
        default_value => 'active',
    },
    owner => {
        data_type => 'varchar',
        size => 30,
        is_nullable => 1,
    },
    sitename => {
        data_type => 'varchar',
        size => 30,
        is_nullable => 1,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
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
    unique_hive_yard => [qw/hive_number yard_id/],
);

# Relationships
__PACKAGE__->belongs_to(
    'yard',
    'Comserv::Model::Schema::Ency::Result::Yard',
    'yard_id',
    { is_deferrable => 1, on_delete => 'RESTRICT' }
);

__PACKAGE__->has_many(
    'boxes',
    'Comserv::Model::Schema::Ency::Result::Box',
    'hive_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'inspections',
    'Comserv::Model::Schema::Ency::Result::Inspection',
    'hive_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'honey_harvests',
    'Comserv::Model::Schema::Ency::Result::HoneyHarvest',
    'hive_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'treatments',
    'Comserv::Model::Schema::Ency::Result::Treatment',
    'hive_id',
    { cascade_delete => 1 }
);

# Custom methods
sub active_boxes {
    my $self = shift;
    return $self->boxes->search({ status => 'active' });
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

sub frame_count {
    my $self = shift;
    return $self->search_related('boxes')
                ->search_related('hive_frames')
                ->search({ 'hive_frames.status' => 'active' })
                ->count;
}

sub display_name {
    my $self = shift;
    my $name = $self->hive_number;
    $name .= " (" . $self->pallet_code . ")" if $self->pallet_code;
    return $name;
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::Hive - Hive table result class

=head1 DESCRIPTION

Represents individual hives in the apiary management system. Each hive belongs to a yard
and can contain multiple boxes. This replaces the denormalized structure where hive data
was scattered across multiple columns in ApisQueenLogTb.

=cut
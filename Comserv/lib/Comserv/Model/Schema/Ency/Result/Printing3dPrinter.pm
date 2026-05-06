package Comserv::Model::Schema::Ency::Result::Printing3dPrinter;
use base 'DBIx::Class::Core';

__PACKAGE__->table('printing_3d_printers');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar',
        size      => 100,
    },
    name => {
        data_type => 'varchar',
        size      => 255,
    },
    model => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 20,
        default_value => 'idle',
    },
    nozzle_diameter => {
        data_type   => 'decimal',
        size        => [4, 2],
        is_nullable => 1,
        default_value => '0.40',
    },
    bed_size => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    current_job_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    inventory_item_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 1,
    },
    updated_at => {
        data_type     => 'datetime',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(
    jobs => 'Comserv::Model::Schema::Ency::Result::Printing3dJob',
    'printer_id',
    { cascade_delete => 0 }
);

__PACKAGE__->belongs_to(
    inventory_item => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    'inventory_item_id',
    { join_type => 'left', on_delete => 'SET NULL' }
);

sub depreciation_per_hour {
    my $self = shift;
    my $item = eval { $self->inventory_item };
    return undef unless $item;
    my $eq = eval { $item->equipment };
    return $eq ? $eq->depreciation_per_hour : undef;
}

sub wattage {
    my $self = shift;
    my $item = eval { $self->inventory_item };
    return undef unless $item;
    my $eq = eval { $item->equipment };
    return $eq ? $eq->wattage : undef;
}

1;

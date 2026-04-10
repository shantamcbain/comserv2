package Comserv::Model::Schema::Ency::Result::HiveComponent;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hive_components');

# Physical instances of hive accessory components: bottom boards, inner covers,
# outer covers/tops, feeders, queen excluders.
# Boxes and frames have their own dedicated tables (Box, HiveFrame); this table
# handles the remaining assembled components that attach to a hive.
#
# inventory_item_id → InventoryItem defines WHAT this component is and its BOM.
# Examples of InventoryItem entries:
#   name='Screened Bottom Board', category='Apiary', item_origin='manufactured', is_assemblable=1
#   name='Telescoping Outer Cover', category='Apiary', item_origin='manufactured', is_assemblable=1
#   name='Top Hive Feeder',        category='Apiary', item_origin='purchased'
#   name='Wire Queen Excluder',    category='Apiary', item_origin='purchased'

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    hive_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'Hive currently using this component (null = in storage)',
    },
    inventory_item_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → inventory_items — defines what type of component this is + its BOM',
    },
    serial_number => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    condition => {
        data_type     => 'enum',
        extra         => { list => [qw/new good fair poor damaged/] },
        is_nullable   => 0,
        default_value => 'new',
    },
    status => {
        data_type     => 'enum',
        extra         => { list => [qw/in_use stored needs_repair retired/] },
        is_nullable   => 0,
        default_value => 'in_use',
    },
    assembled_date => {
        data_type   => 'date',
        is_nullable => 1,
    },
    assembled_by => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    purchase_date => {
        data_type   => 'date',
        is_nullable => 1,
    },
    cost => {
        data_type   => 'decimal',
        size        => [8, 2],
        is_nullable => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_by => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        is_nullable   => 1,
        set_on_create => 1,
    },
    updated_at => {
        data_type     => 'timestamp',
        is_nullable   => 1,
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'hive',
    'Comserv::Model::Schema::Ency::Result::Hive',
    { 'foreign.id' => 'self.hive_id' },
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'inventory_item',
    'Comserv::Model::Schema::Ency::Result::InventoryItem',
    { 'foreign.id' => 'self.inventory_item_id' },
    { is_deferrable => 1, on_delete => 'RESTRICT' }
);

sub display_name {
    my $self = shift;
    my $name = eval { $self->inventory_item->name } || 'Component';
    my $sn   = $self->serial_number ? ' #' . $self->serial_number : '';
    return "$name$sn";
}

sub bom_parts {
    my $self = shift;
    return $self->inventory_item->bom_components;
}

sub needs_attention {
    my $self = shift;
    return $self->condition =~ /^(poor|damaged)$/ || $self->status eq 'needs_repair';
}

1;

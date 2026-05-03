package Comserv::Model::Schema::Ency::Result::Accounting::InventoryItemBOM;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_item_bom');

# Generic Bill of Materials / Recipe table.
# Links any finished/assembled item to its component items with quantities.
#
# Works for ANY item type:
#   Beehive Frame:  parent=Deep Frame,      components=[top_bar, bottom_bar, end_bar×2, nails×24, foundation(opt)]
#   Honey Jar:      parent=Honey 500g jar,  components=[bulk_honey 500g, glass_jar, label, lid]
#   Wooden Cabinet: parent=Oak Cabinet,     components=[oak_board 2m, nails 50, wood_stain 500ml, handles 2]
#   3D Bracket:     parent=Printed Bracket, components=[PLA_filament 45g]
#   Herb Bundle:    parent=Sage Bundle 50g, components=[fresh_sage 60g, twine 30cm]
#   Tractor Kit:    parent=Service Kit,     components=[oil_filter, air_filter, engine_oil 2L, spark_plug 2]
#   Potato Bag 5kg: parent=Potatoes 5kg,   components=[potatoes_bulk 5kg, mesh_bag]
#
# The parent item's item_origin tells you HOW it's made:
#   manufactured | crafted | 3d_printed | harvested | grown | foraged

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    parent_item_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'The finished/assembled item (FK → inventory_items)',
    },
    component_item_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'The raw material or sub-component (FK → inventory_items)',
    },
    quantity => {
        data_type     => 'decimal',
        size          => [12, 4],
        is_nullable   => 0,
        default_value => 1,
        comment       => 'Quantity of component needed per ONE unit of parent',
    },
    unit => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'each',
        comment       => 'Override unit if different from component item default (each/g/kg/ml/L/cm/m/sheet)',
    },
    is_optional => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
        comment       => '1 = optional ingredient (e.g. foundation in a frame, paint on a box)',
    },
    scrap_factor => {
        data_type     => 'decimal',
        size          => [5, 4],
        is_nullable   => 1,
        default_value => '0.0000',
        comment       => 'Extra material fraction to account for waste (0.05 = 5% waste)',
    },
    sort_order => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => 0,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
    },
    updated_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(unique_parent_component => [qw/parent_item_id component_item_id/]);

__PACKAGE__->belongs_to(
    'parent_item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.parent_item_id' },
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'component_item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.component_item_id' },
    { is_deferrable => 1, on_delete => 'RESTRICT' }
);

sub effective_quantity {
    my $self = shift;
    my $scrap = $self->scrap_factor || 0;
    return $self->quantity * (1 + $scrap);
}

sub display_line {
    my $self = shift;
    my $opt  = $self->is_optional ? ' (optional)' : '';
    my $name = eval { $self->component_item->name } || 'Unknown';
    return sprintf('%s %s %s%s', $self->quantity, $self->unit, $name, $opt);
}

1;

package Comserv::Model::Schema::Ency::Result::BeeEquipmentBOM;

# DEPRECATED — use InventoryItemBOM instead.
# The generic BOM table (inventory_item_bom) handles all item types:
# frames, boxes, honey jars, wooden cabinets, 3D prints, herb bundles, etc.

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('bee_equipment_bom');
__PACKAGE__->add_columns(
    id => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
);
__PACKAGE__->set_primary_key('id');

1;

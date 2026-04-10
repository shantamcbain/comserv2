package Comserv::Model::Schema::Ency::Result::BeeEquipmentType;

# DEPRECATED — use InventoryItem with category + item_origin instead.
# Beekeeping equipment types (frames, boxes, bottom boards, covers, feeders)
# are now standard InventoryItem records with:
#   category    => 'Apiary'  (or 'Apiary Frame', 'Apiary Box', etc.)
#   item_origin => 'manufactured' | 'purchased'
#   is_assemblable => 1  (if item has a BOM)
#
# Bill of Materials is managed via InventoryItemBOM.
# Physical hive component instances are managed via HiveComponent,
# which references inventory_item_id (FK → inventory_items).

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('bee_equipment_types');
__PACKAGE__->add_columns(
    id => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
);
__PACKAGE__->set_primary_key('id');

1;

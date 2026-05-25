package Comserv::Model::Schema::Accounting::Result::Pricegroup;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('pricegroup');

__PACKAGE__->add_columns(
    id         => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    pricegroup => { data_type => 'varchar', size => 100, is_nullable => 0 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many('vendors',   'Comserv::Model::Schema::Accounting::Result::Vendor',
    { 'foreign.pricegroup_id' => 'self.id' });
__PACKAGE__->has_many('customers', 'Comserv::Model::Schema::Accounting::Result::Customer',
    { 'foreign.pricegroup_id' => 'self.id' });

1;

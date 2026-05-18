package Comserv::Model::Schema::Accounting::Result::Partsgroup;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('partsgroup');

__PACKAGE__->add_columns(
    id         => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    partsgroup => { data_type => 'varchar', size => 100, is_nullable => 0 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many('parts', 'Comserv::Model::Schema::Accounting::Result::Parts',
    { 'foreign.partsgroup_id' => 'self.id' });

1;

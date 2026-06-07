package Comserv::Model::Schema::Accounting::Result::Taxmodule;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('taxmodule');

__PACKAGE__->add_columns(
    taxmodule_id  => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    taxmodulename => { data_type => 'varchar', size => 50, is_nullable => 0 },
);

__PACKAGE__->set_primary_key('taxmodule_id');
__PACKAGE__->add_unique_constraint(['taxmodulename']);

__PACKAGE__->has_many('taxes', 'Comserv::Model::Schema::Accounting::Result::Tax',
    { 'foreign.taxmodule_id' => 'self.taxmodule_id' });

1;

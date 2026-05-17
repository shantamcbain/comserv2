package Comserv::Model::Schema::Accounting::Result::Makemodel;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('makemodel');

__PACKAGE__->add_columns(
    parts_id => { data_type => 'integer',     is_nullable => 0, is_foreign_key => 1 },
    make     => { data_type => 'varchar', size => 255, is_nullable => 1 },
    model    => { data_type => 'varchar', size => 255, is_nullable => 1 },
);

__PACKAGE__->set_primary_key('parts_id', 'make', 'model');

__PACKAGE__->belongs_to('part', 'Comserv::Model::Schema::Accounting::Result::Parts',
    { 'foreign.id' => 'self.parts_id' });

1;

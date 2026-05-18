package Comserv::Model::Schema::Accounting::Result::Orderitems;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('orderitems');

__PACKAGE__->add_columns(
    id           => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    trans_id     => { data_type => 'integer',     is_nullable => 0, is_foreign_key => 1 },
    parts_id     => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    description  => { data_type => 'text',        is_nullable => 1 },
    qty          => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    sellprice    => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    discount     => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    unit         => { data_type => 'varchar', size => 35,  is_nullable => 1 },
    project_id   => { data_type => 'integer',     is_nullable => 1 },
    serialnumber => { data_type => 'text',        is_nullable => 1 },
    reqdate      => { data_type => 'date',        is_nullable => 1 },
    ship         => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    base_qty     => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    itemnotes    => { data_type => 'text',        is_nullable => 1 },
    taxaccounts  => { data_type => 'text',        is_nullable => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to('order', 'Comserv::Model::Schema::Accounting::Result::Oe',
    { 'foreign.id' => 'self.trans_id' });
__PACKAGE__->belongs_to('part',  'Comserv::Model::Schema::Accounting::Result::Parts',
    { 'foreign.id' => 'self.parts_id' }, { join_type => 'LEFT' });

1;

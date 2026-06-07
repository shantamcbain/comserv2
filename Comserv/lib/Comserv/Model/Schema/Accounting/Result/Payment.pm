package Comserv::Model::Schema::Accounting::Result::Payment;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('payment');

__PACKAGE__->add_columns(
    id          => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    description => { data_type => 'varchar', size => 255, is_nullable => 0 },
    terms       => { data_type => 'integer',     is_nullable => 1, default_value => 0 },
    discount    => { data_type => 'numeric', size => [5,2], is_nullable => 1, default_value => 0 },
    net         => { data_type => 'integer',     is_nullable => 1, default_value => 0 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many('vendors',   'Comserv::Model::Schema::Accounting::Result::Vendor',
    { 'foreign.payment_id' => 'self.id' });
__PACKAGE__->has_many('customers', 'Comserv::Model::Schema::Accounting::Result::Customer',
    { 'foreign.payment_id' => 'self.id' });

1;

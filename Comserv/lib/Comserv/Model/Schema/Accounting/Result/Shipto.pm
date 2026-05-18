package Comserv::Model::Schema::Accounting::Result::Shipto;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('shipto');

__PACKAGE__->add_columns(
    id          => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    trans_id    => { data_type => 'integer',     is_nullable => 1 },
    transtype   => { data_type => 'varchar', size => 10,  is_nullable => 1 },
    shiptoname  => { data_type => 'varchar', size => 255, is_nullable => 1 },
    address1    => { data_type => 'varchar', size => 255, is_nullable => 1 },
    address2    => { data_type => 'varchar', size => 255, is_nullable => 1 },
    city        => { data_type => 'varchar', size => 100, is_nullable => 1 },
    state       => { data_type => 'varchar', size => 100, is_nullable => 1 },
    zipcode     => { data_type => 'varchar', size => 20,  is_nullable => 1 },
    country     => { data_type => 'varchar', size => 100, is_nullable => 1 },
    contact     => { data_type => 'varchar', size => 255, is_nullable => 1 },
    phone       => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    fax         => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    email       => { data_type => 'text',        is_nullable => 1 },
);

__PACKAGE__->set_primary_key('id');

1;

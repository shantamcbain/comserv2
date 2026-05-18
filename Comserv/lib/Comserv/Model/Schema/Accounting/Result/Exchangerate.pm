package Comserv::Model::Schema::Accounting::Result::Exchangerate;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('exchangerate');

__PACKAGE__->add_columns(
    curr      => { data_type => 'char', size => 3,    is_nullable => 0 },
    transdate => { data_type => 'date',               is_nullable => 0 },
    buy       => { data_type => 'numeric', size => [10,5], is_nullable => 1 },
    sell      => { data_type => 'numeric', size => [10,5], is_nullable => 1 },
);

__PACKAGE__->set_primary_key('curr', 'transdate');

1;

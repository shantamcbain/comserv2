package Comserv::Model::Schema::Accounting::Result::Defaults;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('defaults');

__PACKAGE__->add_columns(
    setting_key => { data_type => 'varchar', size => 50, is_nullable => 0 },
    value       => { data_type => 'text',               is_nullable => 1 },
);

__PACKAGE__->set_primary_key('setting_key');

1;

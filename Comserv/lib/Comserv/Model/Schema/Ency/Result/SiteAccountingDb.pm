package Comserv::Model::Schema::Ency::Result::SiteAccountingDb;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('site_accounting_dbs');

__PACKAGE__->add_columns(
    id          => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    sitename    => { data_type => 'varchar', size => 50,  is_nullable => 0 },
    db_host     => { data_type => 'varchar', size => 255, is_nullable => 0, default_value => '192.168.1.20' },
    db_port     => { data_type => 'integer',              is_nullable => 0, default_value => 5432 },
    db_name     => { data_type => 'varchar', size => 100, is_nullable => 0 },
    db_user     => { data_type => 'varchar', size => 100, is_nullable => 0, default_value => 'postgres' },
    db_pass     => { data_type => 'varchar', size => 255, is_nullable => 1 },
    jurisdiction => { data_type => 'varchar', size => 10,  is_nullable => 0, default_value => 'CA' },
    currency    => { data_type => 'varchar', size => 3,   is_nullable => 0, default_value => 'CAD' },
    status      => { data_type => 'varchar', size => 20,  is_nullable => 0, default_value => 'active' },
    notes       => { data_type => 'text',                 is_nullable => 1 },
    created_at  => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at  => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['sitename']);

1;

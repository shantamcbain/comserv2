package Comserv::Schema::Ency::Result::SiteDomain;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('SiteDomain');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
        is_nullable => 0,
    },
    site_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    domain => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'site' => 'Comserv::Schema::Result::Site',
    { 'foreign.id' => 'self.site_id' },
);

1;
package Comserv::Schema::Result::SiteTheme;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('site_themes');

__PACKAGE__->add_columns(
    site_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    theme_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    is_customized => {
        data_type => 'boolean',
        is_nullable => 0,
        default_value => 0,
    },
);

__PACKAGE__->set_primary_key('site_id');

__PACKAGE__->belongs_to(
    'site' => 'Comserv::Schema::Result::Site',
    { 'foreign.id' => 'self.site_id' },
);

__PACKAGE__->belongs_to(
    'theme' => 'Comserv::Schema::Result::Theme',
    { 'foreign.id' => 'self.theme_id' },
);

1;
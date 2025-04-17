package Comserv::Schema
Generated Version::Result::Site;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components(qw/InflateColumn::DateTime/);
__PACKAGE__->table('Site');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
        is_nullable => 0,
    },
    name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    # Add other existing columns here
    
    # Add the theme column
    theme => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
        default_value => 'default',
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['name']);

__PACKAGE__->has_many(
    'domains' => 'Comserv::Schema::Result::SiteDomain',
    { 'foreign.site_id' => 'self.id' },
    { cascade_delete => 1 },
);

__PACKAGE__->has_one(
    'site_theme' => 'Comserv::Schema::Result::SiteTheme',
    { 'foreign.site_id' => 'self.id' },
);

1;
package Comserv::Model::Schema::Ency::Result::Theme;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components(qw/InflateColumn::DateTime/);
__PACKAGE__->table('themes');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
        is_nullable => 0,
    },
    name => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    base_theme => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
        default_value => 'default',
    },
    is_active => {
        data_type => 'boolean',
        is_nullable => 0,
        default_value => 1,
    },
    created_at => {
        data_type => 'timestamp',
        is_nullable => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type => 'timestamp',
        is_nullable => 0,
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['name']);

__PACKAGE__->has_many(
    'variables' => 'Comserv::Model::Schema::Ency::Result::ThemeVariable',
    { 'foreign.theme_id' => 'self.id' },
    { cascade_delete => 1 },
);

__PACKAGE__->has_many(
    'site_themes' => 'Comserv::Model::Schema::Ency::Result::SiteTheme',
    { 'foreign.theme_id' => 'self.id' },
);

1;
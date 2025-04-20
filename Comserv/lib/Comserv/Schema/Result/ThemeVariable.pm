package Comserv::Schema::ENCY::Result::ThemeVariable;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('ThemeVariable');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
        is_nullable => 0,
    },
    theme_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    variable_name => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
    },
    variable_value => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['theme_id', 'variable_name']);

__PACKAGE__->belongs_to(
    'theme' => 'Comserv::Schema::Result::Theme',
    { 'foreign.id' => 'self.theme_id' },
);

1;
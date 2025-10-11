package Comserv::Model::Schema::Ency::Result::SiteConfig;
use base 'DBIx::Class::Core';

__PACKAGE__->table('site_config');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    site_id => {
        data_type => 'integer',
    },
    config_key => {
        data_type => 'varchar',
        size => 255,
    },
    config_value => {
        data_type => 'text',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['site_id', 'config_key']);
__PACKAGE__->belongs_to(site => 'Comserv::Model::Schema::Ency::Result::Site', 'site_id');

1;

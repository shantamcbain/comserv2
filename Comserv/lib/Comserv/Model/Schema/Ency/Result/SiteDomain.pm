package Comserv::Model::Schema::Ency::Result::SiteDomain;
use base 'DBIx::Class::Core';

__PACKAGE__->table('sitedomain');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    site_id => {
        data_type => 'integer',
    },
    domain => {
        data_type => 'varchar',
        size => 255,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(site => 'Comserv::Model::Schema::Ency::Result::Site', 'site_id');

1;
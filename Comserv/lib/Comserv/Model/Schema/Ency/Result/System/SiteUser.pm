package Comserv::Model::Schema::Ency::Result::System::SiteUser;
use base 'DBIx::Class::Core';

__PACKAGE__->table('user_sites');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    user_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    site_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('user_site_unique' => ['user_id', 'site_id']);
1;
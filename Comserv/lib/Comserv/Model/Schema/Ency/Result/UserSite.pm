package Comserv::Model::Schema::Ency::Result::UserSite;
use base 'DBIx::Class::Core';

# Canonical (single) Result class for the user_sites join table.
# Merged from the duplicate System/SiteUser.pm (id PK + unique constraint)
# and UserSite.pm (belongs_to relationships) so there is exactly one class
# per table, named to match the table, with no redundant second file.

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

__PACKAGE__->belongs_to(user => 'Comserv::Model::Schema::Ency::Result::User', 'user_id');
__PACKAGE__->belongs_to(site => 'Comserv::Model::Schema::Ency::Result::Project', 'site_id');

1;

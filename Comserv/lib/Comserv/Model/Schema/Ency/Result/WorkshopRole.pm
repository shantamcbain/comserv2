package Comserv::Model::Schema::Ency::Result::WorkshopRole;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components("TimeStamp");
__PACKAGE__->table('workshop_roles');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    user_id => {
        data_type => 'integer',
    },
    workshop_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    role => {
        data_type => 'enum',
        default_value => 'workshop_leader',
        extra => {
            list => ['workshop_leader']
        },
    },
    site_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    granted_by => {
        data_type => 'integer',
        is_nullable => 1,
    },
    granted_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(user_workshop_role => ['user_id', 'workshop_id']);

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.user_id' },
);

__PACKAGE__->belongs_to(
    workshop => 'Comserv::Model::Schema::Ency::Result::WorkShop',
    { 'foreign.id' => 'self.workshop_id' },
    { join_type => 'left' },
);

__PACKAGE__->belongs_to(
    granter => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.granted_by' },
    { join_type => 'left' },
);

1;

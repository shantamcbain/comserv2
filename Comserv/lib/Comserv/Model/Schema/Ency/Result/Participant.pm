package Comserv::Model::Schema::Ency::Result::Participant;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components("TimeStamp");
__PACKAGE__->table('participant');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    workshop_id => {
        data_type => 'integer',
    },
    user_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    name => {
        data_type => 'varchar',
        size => 255,
    },
    first_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    last_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    email => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    site_affiliation => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    registered_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    status => {
        data_type => 'enum',
        default_value => 'registered',
        extra => {
            list => ['registered', 'waitlist', 'attended', 'cancelled']
        },
    },
    email_opt_out => {
        data_type     => 'tinyint',
        default_value => 0,
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    workshop => 'Comserv::Model::Schema::Ency::Result::WorkShop',
    { 'foreign.id' => 'self.workshop_id' },
);

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.user_id' },
    { join_type => 'left' },
);

1;
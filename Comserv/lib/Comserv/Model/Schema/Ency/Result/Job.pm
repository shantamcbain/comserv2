package Comserv::Model::Schema::Ency::Result::Job;
use base 'DBIx::Class::Core';

__PACKAGE__->table('jobs');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    sitename => {
        data_type     => 'varchar',
        size          => 255,
        is_nullable   => 0,
        default_value => 'CSC',
    },
    title => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    description => {
        data_type   => 'text',
        is_nullable => 0,
    },
    requirements => {
        data_type   => 'text',
        is_nullable => 1,
    },
    location => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    remote => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 0,
    },
    posted_by_user_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    poster_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    poster_email => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'open',
    },
    payment_type => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'cash',
    },
    point_rate => {
        data_type   => 'decimal',
        size        => [14, 4],
        is_nullable => 1,
    },
    cash_rate => {
        data_type   => 'decimal',
        size        => [14, 4],
        is_nullable => 1,
    },
    currency => {
        data_type     => 'varchar',
        size          => 10,
        is_nullable   => 0,
        default_value => 'CAD',
    },
    accept_points_payment => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 0,
    },
    expires_at => {
        data_type   => 'date',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    posted_by => 'Comserv::Model::Schema::Ency::Result::User',
    'posted_by_user_id',
    { join_type => 'left', on_delete => 'set null' }
);

__PACKAGE__->has_many(
    applications => 'Comserv::Model::Schema::Ency::Result::JobApplication',
    'job_id',
    { cascade_delete => 1 }
);

1;

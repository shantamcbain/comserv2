package Comserv::Model::Schema::Ency::Result::JobApplication;
use base 'DBIx::Class::Core';

__PACKAGE__->table('job_applications');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    job_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    user_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    applicant_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    applicant_email => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    cover_letter => {
        data_type   => 'text',
        is_nullable => 1,
    },
    resume_file => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    use_points_payment => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 0,
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'pending',
    },
    notes => {
        data_type   => 'text',
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
    job => 'Comserv::Model::Schema::Ency::Result::Job',
    'job_id',
    { on_delete => 'cascade' }
);

__PACKAGE__->belongs_to(
    applicant => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id',
    { join_type => 'left', on_delete => 'set null' }
);

1;

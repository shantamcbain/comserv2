package Comserv::Model::Schema::Ency::Result::Job_applications;
use base 'DBIx::Class::Core';

__PACKAGE__->table('job_applications');
__PACKAGE__->add_columns(
    applicant_email => {
        data_type => 'varchar',
        size => 255,
    },
    applicant_name => {
        data_type => 'varchar',
        size => 255,
    },
    cover_letter => {
        data_type => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    job_id => {
        data_type => 'int',
        size => 11,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    resume_file => {
        data_type => 'text',
        is_nullable => 1,
    },
    status => {
        data_type => 'varchar',
        size => 50,
        default_value => 'pending',
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    use_points_payment => {
        data_type => 'tinyint',
        size => 1,
        default_value => '0',
    },
    user_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;

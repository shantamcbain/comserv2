package Comserv::Model::Schema::Ency::Result::WorkshopMailTemplate;
use base 'DBIx::Class::Core';
use strict;
use warnings;

__PACKAGE__->load_components(qw/TimeStamp/);
__PACKAGE__->table('workshop_mail_templates');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    name => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
        # e.g. 'registration_confirmation', 'announcement', 'reminder', 'cancellation'
    },
    template_type => {
        data_type     => 'enum',
        extra         => { list => ['registration_confirmation', 'announcement', 'reminder', 'update', 'cancellation', 'custom'] },
        is_nullable   => 0,
        default_value => 'custom',
    },
    subject => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    body_text => {
        data_type   => 'text',
        is_nullable => 1,
    },
    body_html => {
        data_type   => 'text',
        is_nullable => 1,
    },
    # NULL workshop_id = global template available to all workshops
    # non-NULL = template scoped to a specific workshop
    workshop_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    created_by => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    is_active => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        set_on_create => 1,
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(
    unique_workshop_template_name => ['workshop_id', 'name'],
);

__PACKAGE__->belongs_to(
    workshop => 'Comserv::Model::Schema::Ency::Result::WorkShop',
    { 'foreign.id' => 'self.workshop_id' },
    { join_type => 'LEFT' },
);

__PACKAGE__->belongs_to(
    creator => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.created_by' },
    { join_type => 'LEFT' },
);

1;

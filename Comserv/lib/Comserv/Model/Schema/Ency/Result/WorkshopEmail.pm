package Comserv::Model::Schema::Ency::Result::WorkshopEmail;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components("TimeStamp");
__PACKAGE__->table('workshop_emails');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    workshop_id => {
        data_type => 'integer',
    },
    sent_by => {
        data_type => 'integer',
    },
    subject => {
        data_type => 'varchar',
        size => 255,
    },
    body => {
        data_type => 'text',
    },
    sent_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    recipient_count => {
        data_type => 'integer',
        default_value => 0,
    },
    status => {
        data_type => 'enum',
        extra => { list => ['draft', 'sent', 'failed'] },
        is_nullable => 0,
        default_value => 'draft',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    workshop => 'Comserv::Model::Schema::Ency::Result::WorkShop',
    { 'foreign.id' => 'self.workshop_id' },
);

__PACKAGE__->belongs_to(
    sender => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.sent_by' },
);

1;

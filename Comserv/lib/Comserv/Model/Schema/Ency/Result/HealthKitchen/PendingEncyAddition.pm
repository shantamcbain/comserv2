package Comserv::Model::Schema::Ency::Result::HealthKitchen::PendingEncyAddition;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_pending_ency_addition');

# Staging/review queue for user-submitted ENCY entries (first type: 'symptom').
# Submitter identity and severity stay here; ENCY only receives the reviewed,
# de-personalised entry on approval.
__PACKAGE__->add_columns(
    id                => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    user_id           => { data_type => 'integer', is_nullable => 0 },
    username          => { data_type => 'varchar', size => 255, is_nullable => 1 },
    sitename          => { data_type => 'varchar', size => 255, is_nullable => 0 },
    entity_type       => { data_type => 'varchar', size => 20,  is_nullable => 0 },
    payload           => { data_type => 'text', is_nullable => 0 },   # JSON
    status            => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => 'pending' },
    reviewer_user_id  => { data_type => 'integer', is_nullable => 1 },
    reviewer_username => { data_type => 'varchar', size => 255, is_nullable => 1 },
    review_notes      => { data_type => 'text', is_nullable => 1 },
    ency_record_id    => { data_type => 'integer', is_nullable => 1 },
    todo_id           => { data_type => 'integer', is_nullable => 1 },
    reviewed_at       => { data_type => 'datetime', is_nullable => 1 },
    created_at        => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at        => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);
__PACKAGE__->set_primary_key('id');
1;

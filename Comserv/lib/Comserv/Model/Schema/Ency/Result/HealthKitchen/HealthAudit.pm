package Comserv::Model::Schema::Ency::Result::HealthKitchen::HealthAudit;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_health_audit');

# Audit trail for admin views of shared health history (and export/delete events).
# Holds no health content: who, whose, what action, when.

__PACKAGE__->add_columns(
    id         => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    actor_user_id   => { data_type => 'integer', is_nullable => 0 },
    subject_user_id => { data_type => 'integer', is_nullable => 0 },
    sitename        => { data_type => 'varchar', size => 255, is_nullable => 0 },
    action          => { data_type => 'varchar', size => 40, is_nullable => 0, comment => 'admin_view | export | delete_all | consent | revoke' },
    entry_count     => { data_type => 'integer', is_nullable => 1 },
    created_at => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

1;

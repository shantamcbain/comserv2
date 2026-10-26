package Comserv::Model::Schema::Ency::Result::HealthKitchen::HealthHistory;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_health_history');

# Opt-in health & disease history. label/notes are encrypted (ENC:...); ENCY ids stay
# plain so matching can join ENCY tables. visibility: private (default) | site_admin.

__PACKAGE__->add_columns(
    id         => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    user_id          => { data_type => 'integer', is_nullable => 0 },
    sitename         => { data_type => 'varchar', size => 255, is_nullable => 0 },
    entry_type       => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => 'condition',
                         comment => 'condition | symptom | medication | allergy | procedure' },
    ency_disease_id  => { data_type => 'integer', is_nullable => 1 },
    ency_symptom_id  => { data_type => 'integer', is_nullable => 1 },
    ency_drug_id     => { data_type => 'integer', is_nullable => 1 },
    label            => { data_type => 'text', is_nullable => 1, comment => 'encrypted' },
    status           => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => 'active',
                         comment => 'active | resolved | managed' },
    onset_date       => { data_type => 'date', is_nullable => 1 },
    resolved_date    => { data_type => 'date', is_nullable => 1 },
    severity         => { data_type => 'varchar', size => 20, is_nullable => 1 },
    notes            => { data_type => 'text', is_nullable => 1, comment => 'encrypted' },
    use_for_matching => { data_type => 'tinyint', is_nullable => 0, default_value => 1 },
    visibility       => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => 'private' },
    created_at => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

1;

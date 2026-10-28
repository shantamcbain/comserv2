package Comserv::Model::Schema::Ency::Result::HealthKitchen::HealthConsent;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_health_consent');

# Opt-in consent for Health Kitchen health history. Active = granted and not revoked.
# ip_address / user_agent are stored encrypted (Comserv::Util::Encryption, namespace healthkitchen).

__PACKAGE__->add_columns(
    id         => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    user_id         => { data_type => 'integer', is_nullable => 0 },
    sitename        => { data_type => 'varchar', size => 255, is_nullable => 0 },
    consent_version => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => '1' },
    granted_at      => { data_type => 'datetime', is_nullable => 0 },
    revoked_at      => { data_type => 'datetime', is_nullable => 1 },
    ip_address      => { data_type => 'text', is_nullable => 1, comment => 'encrypted' },
    user_agent      => { data_type => 'text', is_nullable => 1, comment => 'encrypted' },
    created_at => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

1;

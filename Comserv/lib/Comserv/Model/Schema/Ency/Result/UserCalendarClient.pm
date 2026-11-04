package Comserv::Model::Schema::Ency::Result::UserCalendarClient;
use base 'DBIx::Class::Core';

# Per-user list of the mail readers / calendars / devices a user uses, and what
# the Comserv calendar may do with each (Calendar phase 1 data, Nov 2026).
# Alert-sweep SENDING is not built yet (see /tmp/cal1104/PLAN.md, phase 3).
# client_type: system | thunderbird | gmail | sms | android | grokbot | other
# ua_hint is a convenience to recognise a client; it is NOT a security boundary
# (the feed token is). push_endpoint_enc / push_key_enc hold values encrypted
# with Comserv::Util::Encryption (namespace 'calendar_push'), never plain text.
__PACKAGE__->table('user_calendar_clients');
__PACKAGE__->add_columns(
    id          => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    user_id     => { data_type => 'integer', is_nullable => 0 },
    client_type => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => 'other' },
    label       => { data_type => 'varchar', size => 100, is_nullable => 1 },
    enabled     => { data_type => 'tinyint', is_nullable => 0, default_value => 1 },
    may_read    => { data_type => 'tinyint', is_nullable => 0, default_value => 1,
                     documentation => '1 = may subscribe to / read the calendar feed' },
    may_alert   => { data_type => 'tinyint', is_nullable => 0, default_value => 0,
                     documentation => '1 = may be used by the alert sweep' },
    sweep_order => { data_type => 'integer', is_nullable => 0, default_value => 50,
                     documentation => 'lower = tried first; grokbot defaults last (expensive)' },
    ua_hint     => { data_type => 'varchar', size => 100, is_nullable => 1 },
    push_endpoint_enc => { data_type => 'text', is_nullable => 1 },
    push_key_enc      => { data_type => 'text', is_nullable => 1 },
    last_seen_at => { data_type => 'datetime', is_nullable => 1 },
    created_at   => { data_type => 'datetime', is_nullable => 1 },
    updated_at   => { data_type => 'datetime', is_nullable => 1 },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(user => 'Comserv::Model::Schema::Ency::Result::User', 'user_id', { on_delete => 'CASCADE' });

our @CLIENT_TYPES = qw(system thunderbird gmail sms android grokbot other);
our %DEFAULT_ORDER = (system => 10, thunderbird => 20, gmail => 30, sms => 40, android => 50, other => 60, grokbot => 90);

1;

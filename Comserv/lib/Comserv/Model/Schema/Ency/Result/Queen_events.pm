package Comserv::Model::Schema::Ency::Result::Queen_events;
use base 'DBIx::Class::Core';

__PACKAGE__->table('queen_events');
__PACKAGE__->add_columns(
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    created_by => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    event_date => {
        data_type => 'date',
    },
    event_type => {
        data_type => 'enum',
        extra => { list => ['grafted','emerged','mated','introduced','superseded','replaced','dead','sold','treated','moved','marked','clipped','inspected'] },
    },
    hive_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    inspector => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    queen_id => {
        data_type => 'int',
        size => 11,
    },
    yard_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;

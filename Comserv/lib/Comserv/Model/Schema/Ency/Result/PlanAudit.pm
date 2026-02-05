package Comserv::Model::Schema::Ency::Result::PlanAudit;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('plan_audit');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    entity_type => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
    },
    entity_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    action => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
    },
    user_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    username => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    changed_fields => {
        data_type => 'json',
        is_nullable => 1,
    },
    ip_address => {
        data_type => 'varchar',
        size => 45,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_columns(
    'entity_type',
    'entity_id'
);

__PACKAGE__->belongs_to(
    'user' => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id',
    { join_type => 'left', on_delete => 'set null' }
);

sub get_changed_fields {
    my $self = shift;
    my $fields = $self->changed_fields;
    return $fields ? (ref $fields eq 'HASH' ? $fields : {}) : {};
}

sub get_field_change {
    my ($self, $field_name) = @_;
    my $fields = $self->get_changed_fields();
    return $fields->{$field_name};
}

1;

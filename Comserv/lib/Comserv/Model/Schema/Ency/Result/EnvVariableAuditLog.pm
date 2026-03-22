package Comserv::Model::Schema::Ency::Result::EnvVariableAuditLog;

use base 'DBIx::Class::Core';

__PACKAGE__->table('env_variable_audit_logs');

__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    env_variable_id => {
        data_type => 'int',
        is_nullable => 0,
    },
    user_id => {
        data_type => 'int',
        is_nullable => 1,
    },
    action => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
    },
    old_value => {
        data_type => 'longtext',
        is_nullable => 1,
    },
    new_value => {
        data_type => 'longtext',
        is_nullable => 1,
    },
    status => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
        default_value => 'pending',
    },
    ip_address => {
        data_type => 'varchar',
        size => 45,
        is_nullable => 1,
    },
    affected_services => {
        data_type => 'json',
        is_nullable => 1,
    },
    error_message => {
        data_type => 'text',
        is_nullable => 1,
    },
    docker_restart_output => {
        data_type => 'longtext',
        is_nullable => 1,
    },
    rollback_details => {
        data_type => 'json',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'datetime',
        is_nullable => 0,
        default_value => \'NOW()',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'env_variable' => 'Comserv::Model::Schema::Ency::Result::EnvVariable',
    { 'foreign.id' => 'self.env_variable_id' },
);

__PACKAGE__->belongs_to(
    'user' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.user_id' },
    { join_type => 'left' }
);

sub masked_old_value {
    my ($self) = @_;
    return '(masked)' if $self->env_variable && $self->env_variable->is_secret;
    return $self->old_value;
}

sub masked_new_value {
    my ($self) = @_;
    return '(masked)' if $self->env_variable && $self->env_variable->is_secret;
    return $self->new_value;
}

1;

package Comserv::Model::Schema::Ency::Result::EnvVariable;

use base 'DBIx::Class::Core';

__PACKAGE__->table('env_variables');

__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    key => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    value => {
        data_type => 'longtext',
        is_nullable => 1,
    },
    var_type => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
        default_value => 'string',
    },
    is_secret => {
        data_type => 'boolean',
        is_nullable => 0,
        default_value => 0,
    },
    is_editable => {
        data_type => 'boolean',
        is_nullable => 0,
        default_value => 1,
    },
    editable_by_roles => {
        data_type => 'json',
        is_nullable => 0,
        default_value => '["admin"]',
    },
    affected_services => {
        data_type => 'json',
        is_nullable => 1,
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'datetime',
        is_nullable => 0,
        default_value => \'NOW()',
    },
    updated_at => {
        data_type => 'datetime',
        is_nullable => 0,
        default_value => \'NOW()',
        set_on_create => 1,
        set_on_update => 1,
    },
    created_by => {
        data_type => 'int',
        is_nullable => 1,
    },
    updated_by => {
        data_type => 'int',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('key_unique' => ['key']);

__PACKAGE__->has_many(
    'audit_logs' => 'Comserv::Model::Schema::Ency::Result::EnvVariableAuditLog',
    { 'foreign.env_variable_id' => 'self.id' },
    { cascade_delete => 1 }
);

__PACKAGE__->belongs_to(
    'created_by_user' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.created_by' },
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    'updated_by_user' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.updated_by' },
    { join_type => 'left' }
);

sub is_user_editable {
    my ($self, $user_roles) = @_;
    return 0 unless $self->is_editable;
    
    my $editable_roles = $self->editable_by_roles;
    return 1 if !$editable_roles;
    
    if (ref($editable_roles) eq 'ARRAY') {
        return grep { $_ eq 'admin' } @$user_roles;
    }
    return 0;
}

sub display_value {
    my ($self) = @_;
    return $self->is_secret ? '(masked)' : ($self->value // '(empty)');
}

1;

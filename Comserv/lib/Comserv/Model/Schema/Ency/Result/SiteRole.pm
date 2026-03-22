package Comserv::Model::Schema::Ency::Result::SiteRole;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('site_roles');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    role_name => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    is_system_role => {
        data_type => 'boolean',
        default_value => 0,
        is_nullable => 0,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['sitename', 'role_name']);


sub is_admin_role {
    my $self = shift;
    return $self->role_name eq 'admin';
}

sub is_developer_role {
    my $self = shift;
    return $self->role_name eq 'developer';
}

1;

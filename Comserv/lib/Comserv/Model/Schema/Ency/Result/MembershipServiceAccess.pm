package Comserv::Model::Schema::Ency::Result::MembershipServiceAccess;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('membership_service_access');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    user_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    site_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    service_name => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
        documentation => 'beekeeping, planning, ai_models, email, hosting, currency, subdomain, custom_domain',
    },
    granted_by => {
        data_type     => 'enum',
        default_value => 'membership',
        extra         => { list => ['membership', 'manual', 'admin'] },
        is_nullable   => 0,
    },
    membership_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
    },
    is_active => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 1,
        is_nullable   => 0,
    },
    granted_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
    expires_at => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['user_id', 'site_id', 'service_name']);

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id'
);

__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    'site_id'
);

__PACKAGE__->belongs_to(
    membership => 'Comserv::Model::Schema::Ency::Result::UserMembership',
    'membership_id',
    { join_type => 'left' }
);

sub is_expired {
    my $self = shift;
    return 0 unless $self->expires_at;
    use DateTime;
    return DateTime->now > $self->expires_at;
}

sub is_accessible {
    my $self = shift;
    return $self->is_active && !$self->is_expired;
}

1;

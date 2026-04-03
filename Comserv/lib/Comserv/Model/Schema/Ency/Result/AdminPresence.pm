package Comserv::Model::Schema::Ency::Result::AdminPresence;
use base 'DBIx::Class::Core';
__PACKAGE__->load_components("InflateColumn::DateTime");
use warnings FATAL => 'all';

__PACKAGE__->table('admin_presence');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    user_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    username => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    status => {
        data_type     => 'enum',
        extra         => { list => ['available', 'busy', 'away', 'offline'] },
        default_value => 'available',
        is_nullable   => 0,
    },
    session_id => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    last_seen => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(['user_id']);

__PACKAGE__->belongs_to(
    'user' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.user_id' }
);

sub is_online {
    my $self = shift;
    return 0 unless $self->last_seen;
    my $dt = $self->last_seen;
    my $last = ref $dt ? $dt->epoch : do {
        require POSIX; POSIX::strptime($dt, '%Y-%m-%d %H:%M:%S') ? time() : 0;
    };
    return (time() - $last) < 90;
}

1;

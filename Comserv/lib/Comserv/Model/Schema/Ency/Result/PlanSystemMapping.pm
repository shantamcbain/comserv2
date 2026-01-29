package Comserv::Model::Schema::Ency::Result::PlanSystemMapping;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('plan_system_mapping');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    plan_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    system_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    system_path => {
        data_type => 'varchar',
        size => 512,
        is_nullable => 1,
    },
    status => {
        data_type => 'enum',
        extra => { list => ['exists', 'needs_creation', 'needs_removal', 'in_sync'] },
        default_value => 'in_sync',
        is_nullable => 0,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    last_checked => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'plan' => 'Comserv::Model::Schema::Ency::Result::DailyPlan',
    'plan_id',
    { on_delete => 'cascade' }
);

sub needs_attention {
    my $self = shift;
    return $self->status eq 'needs_creation' || $self->status eq 'needs_removal';
}

sub mark_in_sync {
    my $self = shift;
    $self->update({ status => 'in_sync' });
}

sub mark_out_of_sync {
    my ($self, $new_status, $notes) = @_;
    $self->update({
        status => $new_status,
        notes => $notes || $self->notes,
    });
}

1;

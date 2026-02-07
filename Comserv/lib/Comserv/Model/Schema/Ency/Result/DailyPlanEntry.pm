package Comserv::Model::Schema::Ency::Result::DailyPlanEntry;
use base 'DBIx::Class::Core';
__PACKAGE__->load_components("InflateColumn::DateTime");
use warnings FATAL => 'all';
use JSON;

__PACKAGE__->table('daily_plan_entries');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    plan_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    entry_type => {
        data_type => 'enum',
        extra => { list => ['task', 'note', 'meeting', 'ai_action'] },
        default_value => 'task',
        is_nullable => 0,
    },
    entry_time => {
        data_type => 'time',
        is_nullable => 1,
    },
    title => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    zenflow_task_id => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    ai_conversation_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    status => {
        data_type => 'enum',
        extra => { list => ['pending', 'in_progress', 'completed', 'cancelled'] },
        default_value => 'pending',
        is_nullable => 0,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    created_by => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    metadata => {
        data_type => 'text',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'plan' => 'Comserv::Model::Schema::Ency::Result::DailyPlan',
    { 'foreign.id' => 'self.plan_id' },
    { on_delete => 'cascade' }
);

__PACKAGE__->belongs_to(
    'ai_conversation' => 'Comserv::Model::Schema::Ency::Result::AiConversation',
    { 'foreign.id' => 'self.ai_conversation_id' },
    { join_type => 'left', on_delete => 'set null' }
);

sub get_metadata {
    my $self = shift;
    my $metadata = $self->metadata;
    return {} unless $metadata;
    eval {
        return decode_json($metadata);
    };
    return {};
}

sub set_metadata {
    my ($self, $metadata_hash) = @_;
    return unless ref($metadata_hash) eq 'HASH';
    $self->metadata(encode_json($metadata_hash));
}

sub is_ai_generated {
    my $self = shift;
    return $self->entry_type eq 'ai_action';
}

sub is_completed {
    my $self = shift;
    return $self->status eq 'completed';
}

sub mark_completed {
    my $self = shift;
    $self->update({ status => 'completed' });
}

sub mark_in_progress {
    my $self = shift;
    $self->update({ status => 'in_progress' });
}

sub mark_cancelled {
    my $self = shift;
    $self->update({ status => 'cancelled' });
}

1;

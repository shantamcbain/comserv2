package Comserv::Model::Schema::Ency::Result::AiUsageLog;
use base 'DBIx::Class::Core';
__PACKAGE__->load_components("InflateColumn::DateTime");
use warnings FATAL => 'all';

__PACKAGE__->table('ai_usage_logs');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    user_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    site_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    guest_session_id => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 1,
    },
    provider => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
        default_value => 'ollama',
    },
    model => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
        default_value => 'unknown',
    },
    prompt_tokens => {
        data_type => 'integer',
        is_nullable => 1,
        default_value => 0,
    },
    completion_tokens => {
        data_type => 'integer',
        is_nullable => 1,
        default_value => 0,
    },
    total_tokens => {
        data_type => 'integer',
        is_nullable => 1,
        default_value => 0,
    },
    estimated_cost_usd => {
        data_type => 'decimal',
        size => [10, 6],
        is_nullable => 1,
        default_value => 0,
    },
    currency => {
        data_type => 'varchar',
        size => 10,
        is_nullable => 1,
        default_value => 'USD',
    },
    duration_ms => {
        data_type => 'integer',
        is_nullable => 1,
    },
    request_type => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
        default_value => 'chat',
    },
    conversation_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    status => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 0,
        default_value => 'success',
    },
    error_message => {
        data_type => 'text',
        is_nullable => 1,
    },
    ip_address => {
        data_type => 'varchar',
        size => 45,
        is_nullable => 1,
    },
    ollama_host => {
        data_type => 'varchar',
        size => 128,
        is_nullable => 1,
    },
    metadata => {
        data_type => 'json',
        is_nullable => 1,
    },
    # Quota / billing harmony fields (wired to membership plan ai_requests_per_day)
    plan_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    plan_ai_requests_per_day => {
        data_type => 'integer',
        is_nullable => 1,
    },
    within_free_quota => {
        data_type => 'tinyint',
        size => 1,
        default_value => 1,
        is_nullable => 1,
        documentation => '1 = counted against the plan free daily allowance (local AI mostly), 0 = overage / billable',
    },
    billing_status => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 1,
        documentation => 'free, overage, billable, or paid_provider',
    },
);

__PACKAGE__->set_primary_key('id');

# Indexes for common queries (billing, monitoring)
# Note: added via ensure/create or migrations; here for documentation

# Relationships (optional, left joins safe)
__PACKAGE__->belongs_to(
    'user' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.user_id' },
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    'conversation' => 'Comserv::Model::Schema::Ency::Result::AiConversation',
    { 'foreign.id' => 'self.conversation_id' },
    { join_type => 'left' }
);

# Helper
sub get_cost_display {
    my $self = shift;
    return sprintf('%.6f %s', $self->estimated_cost_usd || 0, $self->currency || 'USD');
}

sub is_local_provider {
    my $self = shift;
    return lc($self->provider || '') eq 'ollama';
}

1;

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
    # Ledger grounding fields (Golden Data / Anti-Hallucination, 2026-09-24).
    # Added to the DB by an admin via schema-compare (field sync) — never hand DDL.
    # Until then Comserv::Util::AI::Ledger skips them and mirrors the values
    # into metadata.grounding instead.
    grounded => {
        data_type => 'tinyint',
        size => 1,
        is_nullable => 1,
        documentation => '1 = Grounding Context attached to the model call, 0 = Ungrounded Generation, NULL = not recorded',
    },
    golden_hit_count => {
        data_type => 'integer',
        is_nullable => 1,
        documentation => 'Golden Data snippets (status=golden) in the Grounding Context',
    },
    candidate_hit_count => {
        data_type => 'integer',
        is_nullable => 1,
        documentation => 'Candidate Data snippets (unverified, incl. web hits) in the Grounding Context',
    },
    snippet_ids => {
        data_type => 'varchar',
        size => 1000,
        is_nullable => 1,
        documentation => 'Comma list of Grounding Context ids, e.g. G:12,C:web-3',
    },
    flagged_count => {
        data_type => 'integer',
        is_nullable => 1,
        documentation => 'Uncited factual sentences flagged/stripped by the grounding post-check',
    },
    feature => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
        documentation => 'Calling feature, e.g. ai2_chat',
    },
);

__PACKAGE__->set_primary_key('id');

# Default SELECT = the pre-2026-09-24 columns only, so existing pages keep
# working while the Ledger grounding columns above are not yet in the DB.
# Readers that need them ask explicitly (columns => [...]) after
# Comserv::Util::AI::Ledger->columns_present confirms they exist.
__PACKAGE__->resultset_attributes({
    columns => [qw(
        id created_at user_id site_id guest_session_id provider model
        prompt_tokens completion_tokens total_tokens estimated_cost_usd currency
        duration_ms request_type conversation_id status error_message ip_address
        ollama_host metadata plan_id plan_ai_requests_per_day within_free_quota
        billing_status
    )],
});

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

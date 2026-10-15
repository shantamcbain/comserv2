package Comserv::Model::Schema::Ency::Result::AiModelPolicy;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

# Per-model usage policy — how a model is ALLOWED to be used in future.
#
# This table holds IDENTITY and STATE only (which model, is it usable, what did
# admins conclude, who decided). The actual CRITERIA live in
# ai_model_policy_rule (Result::AiModelPolicyRule) as one row per criterion.
#
# WHY THE CRITERIA ARE NOT COLUMNS HERE — future-proofing.
# "Use only for herbs", "never for evaluation", "good at code" are criteria, and
# criteria change. As fixed columns (use_for / never_for) every new criterion
# would mean ALTER TABLE + a code change. As ROWS in a rule table, a new
# criterion ("only for site CSC", "max $0.02 per 1k tokens", "weekdays only") is
# just another row — no schema change, no migration, no code change.
#
# NOTE ON CREATION: this file is the source of truth; the TABLE is created by an
# admin via in-app schema-compare (/admin/schema_compare -> "Result files
# without tables" -> AiModelPolicy -> Create Table). No hand-written DDL.
# Timestamps are stored in UTC (Comserv::Util::AppTime->now_utc) by the model.
#
# notes: admin free text. NEVER log it and NEVER feed it into an AI prompt —
# notes routinely collect pasted keys/URLs/customer detail, and a judge model
# reading prior notes would ship them to a third-party provider.

__PACKAGE__->table('ai_model_policy');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    provider => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
        documentation => 'Billing/provider slug as used by the Router, e.g. openrouter, supergrok, ollama',
    },
    model => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
        documentation => 'BARE model slug (Router _bare_model form), e.g. deepseek/deepseek-v4-flash. Never a credential.',
    },
    status => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 0,
        default_value => 'active',
        documentation => 'active | watch | killed | retired. killed/retired are excluded from routing.',
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'Admin free text. Never logged, never sent to a model.',
    },
    evaluated_by_model => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        documentation => 'Which model produced the evaluation this decision rests on (the judge). NULL = human assessment only.',
    },
    decided_by => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        documentation => 'Human admin who last set the policy.',
    },
    decided_at => {
        data_type => 'timestamp',
        is_nullable => 1,
        documentation => 'When the policy was last decided (UTC).',
    },
    created_at => {
        data_type => 'timestamp',
        is_nullable => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# One policy per model. The Router looks up by (provider, model).
__PACKAGE__->add_unique_constraint('ai_model_policy_provider_model' => ['provider', 'model']);

__PACKAGE__->has_many(
    'rules' => 'Comserv::Model::Schema::Ency::Result::AiModelPolicyRule',
    { 'foreign.policy_id' => 'self.id' },
    { cascade_delete => 0, cascade_copy => 0 }
);

__PACKAGE__->has_many(
    'history' => 'Comserv::Model::Schema::Ency::Result::AiModelPolicyHistory',
    { 'foreign.policy_id' => 'self.id' },
    { cascade_delete => 0, cascade_copy => 0 }
);

1;
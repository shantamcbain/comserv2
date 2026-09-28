package Comserv::Model::Schema::Ency::Result::AiModelPolicyRule;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

# One CRITERION of a model's usage policy. This is the extensible half of the
# design: a new criterion is a new ROW, never a schema change.
#
# Examples:
#   use only for herbs        -> dimension=task,   operator=allow,  value=ency
#   never use for evaluation  -> dimension=task,   operator=deny,   value=evaluation
#   good at creating code     -> dimension=task,   operator=prefer, value=code
#   only on site CSC          -> dimension=site,   operator=allow,  value=3
#   max $0.02 per 1k tokens   -> dimension=cost,   operator=max,    value=0.02
#   must answer under 2s      -> dimension=latency,operator=max,    value=2000
#
# `task` values MUST be Router context keys so the rule actually gates routing:
#   chat, helpdesk, ency, bmaster, csc, general, navigation, simple, code,
#   developer, docker  (Model::AI2::Router $CONTEXT_PREFS / _context_for)
# plus 'evaluation', which needs adding to _context_for to become enforceable.
# The dimension/operator vocabulary is validated in ONE place
# (Comserv::Model::AI2::ModelPolicy), so adding a dimension is a one-line change
# there and needs no migration.
#
# NOTE ON CREATION: this file is the source of truth; the TABLE is created by an
# admin via in-app schema-compare (/admin/schema_compare -> "Result files
# without tables" -> AiModelPolicyRule -> Create Table). No hand-written DDL.

__PACKAGE__->table('ai_model_policy_rule');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    policy_id => {
        data_type => 'integer',
        is_nullable => 0,
        documentation => 'FK -> ai_model_policy.id',
    },
    dimension => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
        documentation => 'What the criterion is about: task | site | role | cost | latency | quality | time_window | provider',
    },
    operator => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 0,
        documentation => 'allow | deny | prefer | avoid | require | max | min',
    },
    value => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
        documentation => 'Task slug, site id, threshold, etc. Interpretation depends on dimension+operator.',
    },
    note => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
        documentation => 'Why this criterion exists (short). Never logged, never sent to a model.',
    },
    created_by => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        is_nullable => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

# A criterion is stated once per model; duplicates are meaningless.
__PACKAGE__->add_unique_constraint(
    'ai_model_policy_rule_unique' => ['policy_id', 'dimension', 'operator', 'value']
);

__PACKAGE__->belongs_to(
    'policy' => 'Comserv::Model::Schema::Ency::Result::AiModelPolicy',
    { 'foreign.id' => 'self.policy_id' },
    { join_type => 'left' }
);

1;
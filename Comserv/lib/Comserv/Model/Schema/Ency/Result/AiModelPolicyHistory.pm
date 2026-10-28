package Comserv::Model::Schema::Ency::Result::AiModelPolicyHistory;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

# Append-only audit of every model-policy change.
#
# Integrity matters more than secrecy here: once a policy gates routing, "who
# changed this, when, and what was it before" is the thing you need. Rows are
# never updated or deleted — a revert is a NEW row that restates the old value,
# so the trail stays complete. This mirrors the append-only `result` lines on
# ai_eval_proposal.
#
# before_json/after_json carry the smallest useful snapshot, e.g.
#   {"status":"active"} or {"rules":[{"dimension":"task","operator":"deny","value":"evaluation"}]}
# They must never contain credentials.
#
# NOTE ON CREATION: this file is the source of truth; the TABLE is created by an
# admin via in-app schema-compare (/admin/schema_compare -> "Result files
# without tables" -> AiModelPolicyHistory -> Create Table). No hand-written DDL.

__PACKAGE__->table('ai_model_policy_history');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    policy_id => {
        data_type => 'integer',
        is_nullable => 1,
        documentation => 'FK -> ai_model_policy.id. NULL only for events with no surviving policy row.',
    },
    actor => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        documentation => 'Admin username, or a system actor name for automated changes.',
    },
    action => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
        documentation => 'create | note | status | rule_add | rule_remove | rule_change | apply | revert',
    },
    before_json => {
        data_type => 'text',
        is_nullable => 1,
    },
    after_json => {
        data_type => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        is_nullable => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'policy' => 'Comserv::Model::Schema::Ency::Result::AiModelPolicy',
    { 'foreign.id' => 'self.policy_id' },
    { join_type => 'left' }
);

1;
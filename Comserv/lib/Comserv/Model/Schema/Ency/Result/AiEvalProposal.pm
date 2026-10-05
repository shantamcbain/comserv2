package Comserv::Model::Schema::Ency::Result::AiEvalProposal;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

# A change proposed by a Daily AI Eval Report (AISYSTEM plan §5d).
#
# LIFECYCLE (human-gated — nothing auto-applies):
#   proposed -> approved | rejected          (admin, POST on /ai/eval)
#   approved -> applied                      (config only, allow-listed target,
#                                             admin presses Apply)
#   applied  -> reverted                     (restores before_value exactly)
#   rejected / reverted -> approved          (admin may re-approve)
# change_type: config | code | workstation | other. Only `config` can ever be
#   applied, and only for targets in Comserv::Util::AI::EvalAllowList.
#   Approving code / workstation / other creates a Todo (project AISYSTEM) and
#   stores its record id in todo_id.
#
# NOTE ON CREATION: the TABLE is created by an admin via in-app schema-compare
# (/admin/schema_compare -> "Result files without tables" -> AiEvalProposal ->
# Create Table). No hand-written DDL.

__PACKAGE__->table('ai_eval_proposal');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    report_id => {
        data_type => 'integer',
        is_nullable => 0,
        is_foreign_key => 1,
    },
    title => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
        documentation => 'Dedupe key within a report (case/space-insensitive)',
    },
    rationale => {
        data_type => 'text',
        is_nullable => 1,
    },
    change_type => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 0,
        default_value => 'other',
        documentation => 'config | code | workstation | other',
    },
    target => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
        documentation => 'e.g. ai_grounding.json:mode (config targets must be allow-listed)',
    },
    payload_json => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'JSON; config proposals use {"value": ...}',
    },
    status => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 0,
        default_value => 'proposed',
        documentation => 'proposed, approved, rejected, applied, reverted',
    },
    approved_by => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    approved_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    applied_by => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    applied_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    before_value => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'JSON {"present":0|1,"value":...} captured at apply time; revert restores it',
    },
    result => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'Append-only audit lines for approve/reject/apply/revert/todo',
    },
    todo_id => {
        data_type => 'integer',
        is_nullable => 1,
        documentation => 'Todo record_id created when a non-config proposal is approved',
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'report' => 'Comserv::Model::Schema::Ency::Result::AiEvalReport',
    { 'foreign.id' => 'self.report_id' },
);

1;

package Comserv::Model::Schema::Ency::Result::AiEvalReport;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

# Daily AI Eval Report (AISYSTEM plan §5d). One row per (report_date, source),
# e.g. the "AI usage monitor" daily routine. Written ONLY through
# Comserv::Model::AI2::EvalReports::ingest (upsert). Admins review it on
# /ai/eval and add tuning notes (admin_notes). Proposals live in
# ai_eval_proposal (Result::AiEvalProposal) and are never auto-applied.
#
# NOTE ON CREATION: this file is the source of truth; the TABLE is created by
# an admin via in-app schema-compare (/admin/schema_compare -> "Result files
# without tables" -> AiEvalReport -> Create Table). No hand-written DDL.
# Timestamps are stored in UTC (Comserv::Util::AppTime->now_utc) by the model.

__PACKAGE__->table('ai_eval_report');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    report_date => {
        data_type => 'date',
        is_nullable => 0,
        documentation => 'Day the report covers (YYYY-MM-DD); unique with source',
    },
    source => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
        default_value => 'AI usage monitor',
        documentation => 'Who produced the report, e.g. "AI usage monitor"',
    },
    summary => {
        data_type => 'text',
        is_nullable => 1,
    },
    markdown => {
        data_type => 'longtext',
        is_nullable => 1,
        documentation => 'Full report body (Markdown); rendered escaped on /ai/eval',
    },
    metrics_json => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'JSON object: bot, openrouter, supergrok, hermes, chat, helpdesk',
    },
    admin_notes => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'Admin review / tuning notes (never overwritten by ingest)',
    },
    created_by => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('ai_eval_report_date_source' => ['report_date', 'source']);

__PACKAGE__->has_many(
    'proposals' => 'Comserv::Model::Schema::Ency::Result::AiEvalProposal',
    { 'foreign.report_id' => 'self.id' },
    { cascade_delete => 0, cascade_copy => 0 }
);

1;

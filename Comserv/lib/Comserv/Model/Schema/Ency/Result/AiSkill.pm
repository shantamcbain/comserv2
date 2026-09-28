package Comserv::Model::Schema::Ency::Result::AiSkill;
use base 'DBIx::Class::Core';
__PACKAGE__->load_components("InflateColumn::DateTime");
use warnings FATAL => 'all';

# Reusable, reviewable AI skills — the Comserv-side equivalent of a Hermes
# skill. A skill is a remembered, approved way of doing a recurring AI task
# (diagnosis pattern, doc template, query recipe) so the system does not
# re-derive it every turn.
#
# LIFECYCLE (approval-gated — never auto-live):
#   pending  -> written by a user or by the AI; NOT injected into any prompt
#   approved -> injected as Example/Constraint context when its trigger matches
#   rejected -> kept for audit, never injected
# Only `approved` rows are ever used, so an AI-generated skill cannot change
# behaviour without a human decision. Non-admins have their submissions queued
# (a todo is raised for admin attention); admins may approve in-chat.
#
# NOTE ON CREATION: this file is the source of truth but the TABLE is created
# by an admin via the in-app schema-compare workflow
# (/admin/schema_compare -> "Result files without tables" -> Create Table).
# No hand-written DDL, per project policy.

__PACKAGE__->table('ai_skills');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    skill_key => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
        documentation => 'Stable machine name, e.g. quota_403_vs_auth_403',
    },
    name => {
        data_type => 'varchar',
        size => 200,
        is_nullable => 0,
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'One-line human summary of when this skill applies',
    },
    trigger_pattern => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'Regex or phrase list matched against the incoming prompt',
    },
    steps => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'Ordered procedure the AI should follow',
    },
    examples_good => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'What a correct answer looks like',
    },
    examples_bad => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'What to avoid — per the Claude 101 pack this carries most of the weight',
    },
    min_role => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 0,
        default_value => 'member',
        documentation => 'guest, member, editor, developer, admin',
    },
    status => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 0,
        default_value => 'pending',
        documentation => 'pending, approved, rejected',
    },
    source => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'Provenance: who/when/evidence — makes every skill auditable',
    },
    created_by => {
        data_type => 'integer',
        is_nullable => 1,
    },
    approved_by => {
        data_type => 'integer',
        is_nullable => 1,
    },
    approved_at => {
        data_type => 'datetime',
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
    usage_count => {
        data_type => 'integer',
        is_nullable => 1,
        default_value => 0,
    },
    last_used_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    site_id => {
        data_type => 'integer',
        is_nullable => 1,
        documentation => 'NULL = global to all sites',
    },
);

__PACKAGE__->set_primary_key('id');

# This DBIx::Class build has NO add_index (it crashes on reload), so the
# uniqueness of skill_key is declared as a unique constraint instead.
__PACKAGE__->add_unique_constraint('ai_skills_key_unique' => ['skill_key']);

__PACKAGE__->belongs_to(
    'creator' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.created_by' },
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    'approver' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.approved_by' },
    { join_type => 'left' }
);

# ---- helpers -------------------------------------------------------------

sub is_approved {
    my $self = shift;
    return lc($self->status || '') eq 'approved' ? 1 : 0;
}

# Only approved skills may ever be injected into a prompt.
sub injectable {
    my $self = shift;
    return $self->is_approved;
}

1;

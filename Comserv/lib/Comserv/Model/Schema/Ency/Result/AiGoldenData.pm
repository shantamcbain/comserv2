package Comserv::Model::Schema::Ency::Result::AiGoldenData;
use base 'DBIx::Class::Core';
__PACKAGE__->load_components("InflateColumn::DateTime");
use warnings FATAL => 'all';

# Golden Data contract (see Comserv::Util::AI::Glossary).
#
# Golden Data = organization-agreed truth fed to AI models: corporate policy,
# verified research in our databases, verified documentation of how the app
# runs. A row is golden ONLY when a human sets status=golden. Existing in this
# table is not enough. Status today: EMPTY / NOT YET QUALIFIED.
#
# LIFECYCLE (human-gated — never auto-promoted):
#   candidate  -> default for every insert (Candidate Data, unverified)
#   in_review  -> a human is reviewing it
#   golden     -> human-agreed truth; the only rows labelled [GOLDEN]
#   rejected   -> kept for audit, never used as Golden Data
#   stale      -> superseded / outdated (see supersedes_id on the newer row)
#
# domain (varchar, other values accepted): policy, research, app_docs, todo, customer
# source_ref convention "<type>:<locator>": policy:<doc>, research:ency_herb_tb:4,
#   app_docs:Documentation/X, web:searxng:<url>
#
# NOTE ON CREATION: this file is the source of truth; the TABLE is created by
# an admin via in-app schema-compare (/admin/schema_compare -> "Result files
# without tables" -> Create Table). No hand-written DDL, per project policy.
# No embedding_id column: there is no existing embedding setup to reference.

__PACKAGE__->table('ai_golden_data');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    domain => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
        default_value => 'app_docs',
        documentation => 'Known: policy, research, app_docs, todo, customer (others accepted)',
    },
    title => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    canonical_text => {
        data_type => 'text',
        is_nullable => 0,
        documentation => 'The exact text used as Grounding Context',
    },
    source_ref => {
        data_type => 'text',
        is_nullable => 1,
        documentation => 'type:locator e.g. research:ency_herb_tb:4, app_docs:Documentation/X, web:searxng:URL',
    },
    status => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 0,
        default_value => 'candidate',
        documentation => 'candidate, in_review, golden, rejected, stale (only a human sets golden)',
    },
    reviewed_by => {
        data_type => 'integer',
        is_nullable => 1,
        documentation => 'user id of the human reviewer',
    },
    reviewed_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    version => {
        data_type => 'integer',
        is_nullable => 0,
        default_value => 1,
    },
    supersedes_id => {
        data_type => 'integer',
        is_nullable => 1,
        documentation => 'id of the older ai_golden_data row this version replaces',
    },
    content_hash => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 1,
        documentation => 'sha256 hex of canonical_text (dedup / change detection)',
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

__PACKAGE__->belongs_to(
    'supersedes' => 'Comserv::Model::Schema::Ency::Result::AiGoldenData',
    { 'foreign.id' => 'self.supersedes_id' },
    { join_type => 'left' }
);

sub is_golden { my $self = shift; return (($self->status // '') eq 'golden') ? 1 : 0 }

1;

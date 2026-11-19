package Comserv::Model::Schema::Ency::Result::TranslationCache;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime');
__PACKAGE__->table('translation_cache');

# Display-time catalog translation cache, shared by every process, host and
# worktree. Replaces the per-machine var/translate_cache files: one row per
# (source_lang, target_lang, text_hash), so a second worker INSERTing the same
# string loses the race on uq_tr_cache instead of translating it again.
#
# text_hash = md5(source_lang \0 text). The hash is what makes a lookup a
# primary-ish probe; the plaintext source is not stored, so a purge of one
# product's strings is done by collecting hashes and deleting by text_hash.

__PACKAGE__->add_columns(
    id              => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    source_lang     => {
        data_type     => 'varchar',
        size          => 8,
        is_nullable   => 0,
        documentation => 'Catalog language the text was in when translated (ISO-ish code, e.g. en, fr)',
    },
    target_lang     => {
        data_type     => 'varchar',
        size          => 8,
        is_nullable   => 0,
        documentation => 'Language the text was translated into',
    },
    text_hash       => {
        data_type     => 'char',
        size          => 32,
        is_nullable   => 0,
        documentation => 'md5(source_lang \0 source_text) — hex, lower case',
    },
    translated_text => {
        data_type     => 'mediumtext',
        is_nullable   => 0,
        documentation => 'The cached translation body',
    },
    model           => {
        data_type     => 'varchar',
        size          => 64,
        is_nullable   => 1,
        documentation => 'Ollama model that produced this translation',
    },
    hit_count       => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
        documentation => 'Cache hits served from this row',
    },
    created_at      => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at      => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

# The concurrency guard: INSERT ... ON DUPLICATE KEY UPDATE can never
# double-translate the same string for the same language pair.
# (This DBIC version has no add_index — keys are expressed as unique constraints.)
__PACKAGE__->add_unique_constraint(
    'uq_tr_cache' => [qw(source_lang target_lang text_hash)],
);

1;

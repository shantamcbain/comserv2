package Comserv::Model::Schema::Ency::Result::TranslationGlossary;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime');
__PACKAGE__->table('translation_glossary');

# Shared term list used to keep catalog translation consistent: a product or
# material name translates the same way in every table, page and language.
# One row per (source_lang, target_lang, term); the unique constraint makes
# re-importing a glossary file idempotent.

__PACKAGE__->add_columns(
    id          => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    source_lang => {
        data_type     => 'varchar',
        size          => 8,
        is_nullable   => 0,
        documentation => 'Language of the term being defined',
    },
    target_lang => {
        data_type     => 'varchar',
        size          => 8,
        is_nullable   => 0,
        documentation => 'Language the term is translated into',
    },
    term        => {
        data_type     => 'varchar',
        size          => 191,
        is_nullable   => 0,
        documentation => 'Source term as it appears in catalog text',
    },
    translation => {
        data_type     => 'varchar',
        size          => 191,
        is_nullable   => 0,
        documentation => 'Agreed translation for the term',
    },
    notes       => {
        data_type     => 'varchar',
        size          => 255,
        is_nullable   => 1,
        documentation => 'Why this wording was chosen (case, plural, brand)',
    },
    created_at  => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(
    'uq_tr_glossary' => [qw(source_lang target_lang term)],
);

1;

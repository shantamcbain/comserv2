package Comserv::Model::Schema::Ency::Result::Ency::CommonName;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('ency_common_name_tb');

__PACKAGE__->add_columns(
    record_id => {
        data_type         => 'int',
        size              => 11,
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    organism_id => {
        data_type   => 'int',
        size        => 11,
        is_nullable => 0,
        comment     => 'FK to ency_organism_tb',
    },
    name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
        comment     => 'The common name e.g. Okra, Bhindi, Bamia',
    },
    language => {
        data_type     => 'varchar',
        size          => 10,
        is_nullable   => 1,
        default_value => 'en',
        comment       => 'ISO 639-1 language code e.g. en, fr, hi, ar',
    },
    region => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'Geographic region e.g. West Africa, Southern US, India',
    },
    is_historical => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 0,
        comment       => '1 = historical or archaic name no longer in common use',
    },
    is_preferred => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 0,
        comment       => '1 = preferred display name for this language/region',
    },
    source => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'Where this name comes from e.g. NCBI, local, traditional',
    },
    reference_id => {
        data_type   => 'int',
        size        => 11,
        is_nullable => 1,
        comment     => 'FK to ency_reference_tb',
    },
    date_time_posted => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    username_of_poster => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->add_unique_constraint(
    unique_organism_name_lang_region => [qw(organism_id name language region)],
);

__PACKAGE__->belongs_to(
    organism => 'Comserv::Model::Schema::Ency::Result::Ency::Organism',
    'organism_id',
);

__PACKAGE__->belongs_to(
    reference => 'Comserv::Model::Schema::Ency::Result::Ency::Reference',
    'reference_id',
    { join_type => 'LEFT' },
);

1;

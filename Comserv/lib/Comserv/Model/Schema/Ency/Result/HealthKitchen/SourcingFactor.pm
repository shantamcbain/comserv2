package Comserv::Model::Schema::Ency::Result::HealthKitchen::SourcingFactor;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_sourcing_factor');

# Reference data: how a sourcing attribute changes a food category's nutrition
# (percent adjustments, applied as an *estimate* on top of base values, never stored
# over them), contamination risk and an ethics score (0-5). Every row cites a source.
__PACKAGE__->add_columns(
    id                => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    food_category     => { data_type => 'varchar', size => 30, is_nullable => 0 },
    attribute         => { data_type => 'varchar', size => 30, is_nullable => 0 },  # production|animal_raising|catch_method|gmo|local
    attr_value        => { data_type => 'varchar', size => 30, is_nullable => 0 },
    nutrient_adj_json => { data_type => 'text', is_nullable => 1 },  # {"fat_g":-30,...} percent
    pesticide_risk    => { data_type => 'varchar', size => 4, is_nullable => 1 },  # low|med|high
    antibiotic_risk   => { data_type => 'varchar', size => 4, is_nullable => 1 },
    hormone_risk      => { data_type => 'varchar', size => 4, is_nullable => 1 },
    heavy_metal_risk  => { data_type => 'varchar', size => 4, is_nullable => 1 },
    ethics_score      => { data_type => 'tinyint', is_nullable => 1 },
    notes             => { data_type => 'text', is_nullable => 1 },
    citation          => { data_type => 'text', is_nullable => 0 },
    created_at        => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at        => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint( hk_factor_key => [qw/food_category attribute attr_value/] );
1;

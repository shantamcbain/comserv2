package Comserv::Model::Schema::Accounting::Result::Tax;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('tax');

__PACKAGE__->add_columns(
    chart_id     => { data_type => 'integer',      is_nullable => 0, is_foreign_key => 1 },
    rate         => { data_type => 'numeric', size => [10,7], is_nullable => 0, default_value => 0 },
    minvalue     => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    maxvalue     => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    taxnumber    => { data_type => 'varchar', size => 255, is_nullable => 1 },
    pass         => { data_type => 'integer',      is_nullable => 1, default_value => 0 },
    taxmodule_id => { data_type => 'integer',      is_nullable => 1, is_foreign_key => 1 },
);

__PACKAGE__->set_primary_key('chart_id');

__PACKAGE__->belongs_to('chart',     'Comserv::Model::Schema::Accounting::Result::Chart',
    { 'foreign.id' => 'self.chart_id' });
__PACKAGE__->belongs_to('taxmodule', 'Comserv::Model::Schema::Accounting::Result::Taxmodule',
    { 'foreign.taxmodule_id' => 'self.taxmodule_id' }, { join_type => 'LEFT' });

sub rate_percent { my $self = shift; return ($self->rate || 0) * 100 }

1;

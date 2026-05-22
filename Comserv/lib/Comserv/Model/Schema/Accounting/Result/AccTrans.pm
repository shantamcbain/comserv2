package Comserv::Model::Schema::Accounting::Result::AccTrans;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('acc_trans');

__PACKAGE__->add_columns(
    id             => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    trans_id       => { data_type => 'integer',     is_nullable => 0 },
    chart_id       => { data_type => 'integer',     is_nullable => 0, is_foreign_key => 1 },
    amount         => { data_type => 'numeric', size => [15,5], is_nullable => 0, default_value => 0 },
    transdate      => { data_type => 'date',        is_nullable => 0 },
    source         => { data_type => 'varchar', size => 255, is_nullable => 1 },
    cleared        => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    fx_transaction => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    memo           => { data_type => 'text',        is_nullable => 1 },
    invoice_id     => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    entry_id       => { data_type => 'integer',     is_nullable => 1 },
    created_at     => { data_type => 'timestamptz', is_nullable => 1, set_on_create => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'chart' => 'Comserv::Model::Schema::Accounting::Result::Chart',
    { 'foreign.id' => 'self.chart_id' }
);

__PACKAGE__->belongs_to(
    'invoice' => 'Comserv::Model::Schema::Accounting::Result::Invoice',
    { 'foreign.id' => 'self.invoice_id' },
    { join_type => 'LEFT' }
);

1;

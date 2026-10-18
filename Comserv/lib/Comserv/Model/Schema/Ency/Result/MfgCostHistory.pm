package Comserv::Model::Schema::Ency::Result::MfgCostHistory;
use base 'DBIx::Class::Core';
# Cost/price change log for manufactured items (Util::Manufacturing::Costing).
__PACKAGE__->table('mfg_cost_history');
__PACKAGE__->add_columns(
    id         => { data_type => 'integer', is_auto_increment => 1 },
    sitename   => { data_type => 'varchar', size => 100, is_nullable => 1 },
    item_id    => { data_type => 'integer' },
    job_id     => { data_type => 'integer', is_nullable => 1 },
    event      => { data_type => 'varchar', size => 30 },
    old_cost   => { data_type => 'decimal', size => [12, 4], is_nullable => 1 },
    new_cost   => { data_type => 'decimal', size => [12, 4], is_nullable => 1 },
    old_price  => { data_type => 'decimal', size => [12, 2], is_nullable => 1 },
    new_price  => { data_type => 'decimal', size => [12, 2], is_nullable => 1 },
    detail     => { data_type => 'text', is_nullable => 1 },
    created_by => { data_type => 'varchar', size => 100, is_nullable => 1 },
    created_at => { data_type => 'datetime' },
);
__PACKAGE__->set_primary_key('id');
1;

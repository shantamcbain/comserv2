package Comserv::Model::Schema::Ency::Result::Accounting::InventoryRecurringInvoice;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_recurring_invoices');

# Recurring supplier invoice / subscription (AP). INV-R1 #2190.
#
# This is the SCHEDULE, not the bill. Each time recurrence_next_date is
# reached, Comserv::Util::Accounting::RecurringInvoice clones this row (and its
# lines) into a real DRAFT row on inventory_supplier_invoices, then advances
# recurrence_next_date. Keeping the schedule in its own table means the live
# invoice table and every page that reads it are untouched by this feature.
#
# payment_account_id is the CoA account the charge is actually paid FROM
# (bank / credit-card asset account) - a real account, not a free-text note.
# ap_account_id is the Accounts Payable account the liability posts to.
#
# recurrence_unit is a plain short string ('day','week','month','year') rather
# than an enum: the schema-compare tool reads a quoted-string data_type
# reliably, and the interval carries the "every N" part (month + 1 = monthly,
# month + 3 = quarterly, year + 1 = annual).

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    supplier_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
        comment     => 'Schedule label, e.g. "CC3D monthly support"',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    expense_account_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'CoA expense account used when a line has none',
    },
    ap_account_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'CoA Accounts Payable account for the generated invoice',
    },
    payment_account_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'CoA account the recurring charge is PAID FROM (bank / credit card)',
    },
    tax_account_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    tax_amount => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 1,
        default_value => '0.00',
    },
    shipping_amount => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 1,
        default_value => '0.00',
    },
    currency => {
        data_type     => 'char',
        size          => 3,
        is_nullable   => 0,
        default_value => 'CAD',
    },
    recurrence_unit => {
        data_type     => 'varchar',
        size          => 10,
        is_nullable   => 0,
        default_value => 'month',
        comment       => 'day | week | month | year',
    },
    recurrence_interval => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 1,
        comment       => 'Every N units, e.g. month + 3 = quarterly',
    },
    recurrence_start_date => {
        data_type        => 'date',
        is_nullable      => 1,
        inflate_datetime => 0,
    },
    recurrence_next_date => {
        data_type        => 'date',
        is_nullable      => 1,
        inflate_datetime => 0,
        comment          => 'Next date a draft invoice is generated for',
    },
    recurrence_end_date => {
        data_type        => 'date',
        is_nullable      => 1,
        inflate_datetime => 0,
        comment          => 'Stop generating after this date (NULL = open ended)',
    },
    is_active => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 1,
        comment       => '0 = paused',
    },
    auto_pay => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 0,
    },
    auto_pay_method => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    next_amount => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 1,
        default_value => '0.00',
        comment       => 'Expected charge per period (lines + tax + shipping), for the list view',
    },
    last_invoice_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'Last generated inventory_supplier_invoices.id',
    },
    last_run_date => {
        data_type        => 'date',
        is_nullable      => 1,
        inflate_datetime => 0,
    },
    created_by => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
    },
    updated_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'supplier',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventorySupplier',
    { 'foreign.id' => 'self.supplier_id' },
    { join_type => 'LEFT' }
);

# NOTE: belongs_to never carries cascade_delete - deleting a schedule must not
# delete the AP, expense, payment or invoice rows it points at.
__PACKAGE__->belongs_to(
    'ap_account',
    'Comserv::Model::Schema::Ency::Result::Accounting::CoaAccount',
    { 'foreign.id' => 'self.ap_account_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'payment_account',
    'Comserv::Model::Schema::Ency::Result::Accounting::CoaAccount',
    { 'foreign.id' => 'self.payment_account_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'expense_account',
    'Comserv::Model::Schema::Ency::Result::Accounting::CoaAccount',
    { 'foreign.id' => 'self.expense_account_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'tax_account',
    'Comserv::Model::Schema::Ency::Result::Accounting::CoaAccount',
    { 'foreign.id' => 'self.tax_account_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'last_invoice',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventorySupplierInvoice',
    { 'foreign.id' => 'self.last_invoice_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->has_many(
    'lines',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryRecurringInvoiceLine',
    { 'foreign.recurring_invoice_id' => 'self.id' },
    { cascade_delete => 1 }
);

# Human-readable cadence, e.g. "Monthly", "Every 3 months".
sub cadence_label {
    my $self = shift;
    my $unit = $self->recurrence_unit || 'month';
    my $n    = $self->recurrence_interval || 1;
    my %singular = (day => 'day', week => 'week', month => 'month', year => 'year');

    return 'n/a' unless $singular{$unit};
    return 'Monthly' if $unit eq 'month' && $n == 1;
    return 'Quarterly' if $unit eq 'month' && $n == 3;
    return 'Annually' if $unit eq 'year' && $n == 1;
    return 'Weekly' if $unit eq 'week' && $n == 1;
    return 'Daily' if $unit eq 'day' && $n == 1;
    return "Every $n $unit" . ($n == 1 ? '' : 's');
}

1;

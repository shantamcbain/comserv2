#!/usr/bin/env perl
# Backfill Square receipts (plan JSON from square_receipt_backfill_dryrun.py --json) into
# inventory_supplier_invoices/_lines for a site + supplier. Idempotent: skips invoice_number
# SQ-<code> that already exists. Creates missing items; sets unit_cost from the latest price.
# Never touches stock (history only).
#   perl script/square_receipt_backfill.pl --plan F --sitename Shanta --supplier-id 21 [--apply]
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Getopt::Long; use JSON qw(decode_json);
use Comserv;
my ( $plan, $site, $sup, $apply ) = ( undef, 'Shanta', 21, 0 );
GetOptions( 'plan=s' => \$plan, 'sitename=s' => \$site, 'supplier-id=i' => \$sup, 'apply' => \$apply ) && $plan
    or die "usage: $0 --plan F [--sitename S] [--supplier-id N] [--apply]\n";
my $recs = decode_json( do { local ( @ARGV, $/ ) = $plan; <> } );
my $s  = Comserv->model('DBEncy')->schema;
my $ir = $s->resultset('Accounting::InventoryItem');
sub norm { my $n = lc shift; $n =~ s/\s*\((till)\)\s*$//i; $n =~ s/\s+/ /g; $n =~ s/^\s+|\s+$//g; $n }
sub sku  { my $n = uc shift; $n =~ s/\s*\(TILL\)\s*$//; $n =~ s/[^A-Z0-9]+/-/g; $n =~ s/^-|-$//g; 'COOP-' . substr( $n, 0, 40 ) }
my %item = map { norm( $_->name ) => $_ } $ir->search( { sitename => $site } )->all;
my %have = map { $_ => 1 } $s->resultset('Accounting::InventorySupplierInvoice')
    ->search( { supplier_id => $sup }, { columns => ['invoice_number'] } )->get_column('invoice_number')->all;
my %latest;    # norm name => [date, unit_price]
for my $r (@$recs) { for my $it ( @{ $r->{items} } ) {
    my $k = norm( $it->{name} );
    $latest{$k} = [ $r->{date}, $it->{unit_price} ] if !$latest{$k} || $r->{date} gt $latest{$k}[0];
} }
my %n = ( invoices => 0, lines => 0, items_created => 0, unit_cost_set => 0, skipped_existing => 0 );
my $run = sub {
    for my $k ( sort keys %latest ) {
        next if $item{$k};
        my ($orig) = map { $_->{name} } grep { norm( $_->{name} ) eq $k } map { @{ $_->{items} } } @$recs;
        $orig =~ s/\s*\((?:till|TILL)\)\s*$//;
        $item{$k} = $ir->create( { sitename => $site, name => $orig, sku => sku($orig), category => 'food',
            description => 'Monashee Community Co-op (Square receipts)', unit_of_measure => 'each',
            item_origin => 'purchased', is_consumable => 1, is_assemblable => 0, is_reusable => 0,
            hide_stock_count => 0, show_in_shop => 0, accepts_points => 0, requires_printing => 0,
            list_in_marketplace => 0, reorder_point => 0, reorder_quantity => 0, discount_percent => 0, status => 'active', created_by => 'system',
            notes => 'Created by square_receipt_backfill from emailed receipts.' } );
        $n{items_created}++;
    }
    for my $r ( sort { $a->{date} cmp $b->{date} } @$recs ) {
        my $num = "SQ-$r->{code}";
        if ( $have{$num} ) { $n{skipped_existing}++; next }
        my $inv = $s->resultset('Accounting::InventorySupplierInvoice')->create( {
            sitename => $site, supplier_id => $sup, invoice_number => $num, invoice_date => substr( $r->{date}, 0, 10 ),
            total_amount => $r->{total} // $r->{line_sum}, tax_amount => $r->{gst} // 0, shipping_amount => 0,
            discount_amount => 0, status => 'posted', created_by => 'system',
            notes => "Historical Square receipt from emailed receipts (backfill).\nPurchase history for diet cycles. "
                   . "Do not receive into stock. This food was already bought and mostly eaten outside recipes.\nreceipt=$r->{code}" } );
        $have{$num} = 1; $n{invoices}++;
        for my $it ( @{ $r->{items} } ) {
            $s->resultset('Accounting::InventorySupplierInvoiceLine')->create( {
                invoice_id => $inv->id, item_id => $item{ norm( $it->{name} ) }->id, description => $it->{name},
                quantity => $it->{qty}, unit_cost => $it->{unit_price}, line_total => $it->{line_total} } );
            $n{lines}++;
        }
    }
    for my $k ( keys %latest ) {
        my $i = $item{$k} or next;
        my $p = $latest{$k}[1];
        next unless defined $p && ( !defined $i->unit_cost || abs( $i->unit_cost - $p ) >= 0.005 );
        $i->update( { unit_cost => $p } ); $n{unit_cost_set}++;
    }
    die "DRY RUN rollback\n" unless $apply;
};
eval { $s->txn_do($run); 1 } or do { die $@ unless $@ =~ /DRY RUN rollback/ };
print STDERR ( $apply ? 'APPLIED' : 'DRY RUN (rolled back)' ), ': ', join( ', ', map {"$_=$n{$_}"} sort keys %n ), "\n";

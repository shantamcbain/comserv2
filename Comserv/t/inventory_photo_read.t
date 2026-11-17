#!/usr/bin/env perl
# Shared photo / barcode reader (Comserv::Util::Inventory::PhotoRead) and the
# Chat-with-AI front door (Comserv::Model::AI2::PhotoIntent): one code path.
# VisionRead and the text AI are mocked: no network, no model.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use MIME::Base64 qw(encode_base64);

BEGIN {
    eval { require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite not installed';
}

use Comserv::Util::Logging;
{
    no warnings 'redefine';
    *Comserv::Util::Logging::log_with_details = sub { 1 };
}

# ---- minimal schema with the real source names --------------------------
{
    package PR::Schema; use base 'DBIx::Class::Schema';
    package PR::Item; use base 'DBIx::Class::Core';
    __PACKAGE__->table('inventory_items');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            sitename sku name description category item_origin is_assemblable is_consumable
            is_reusable unit_of_measure unit_cost status notes show_in_shop hide_stock_count
            accepts_points list_in_marketplace created_by created_at updated_at barcode barcode_type
            image_path inventory_accno_id expense_accno_id));
    __PACKAGE__->set_primary_key('id');
    package PR::Supplier; use base 'DBIx::Class::Core';
    __PACKAGE__->table('inventory_suppliers');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            sitename name contact_name email phone address website status notes created_by created_at updated_at));
    __PACKAGE__->set_primary_key('id');
    package PR::ItemSupplier; use base 'DBIx::Class::Core';
    __PACKAGE__->table('inventory_item_suppliers');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(item_id supplier_id supplier_sku unit_cost));
    __PACKAGE__->set_primary_key('id');
    package PR::Invoice; use base 'DBIx::Class::Core';
    __PACKAGE__->table('inventory_supplier_invoices');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            sitename supplier_id invoice_number invoice_date total_amount tax_amount shipping_amount
            status notes created_by created_at updated_at));
    __PACKAGE__->set_primary_key('id');
    __PACKAGE__->has_many(lines => 'PR::Line', 'invoice_id');
    package PR::Line; use base 'DBIx::Class::Core';
    __PACKAGE__->table('inventory_supplier_invoice_lines');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            invoice_id item_id description quantity unit_cost line_total));
    __PACKAGE__->set_primary_key('id');
    package PR::Location; use base 'DBIx::Class::Core';
    __PACKAGE__->table('inventory_locations');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(sitename name status));
    __PACKAGE__->set_primary_key('id');
    package PR::Stock; use base 'DBIx::Class::Core';
    __PACKAGE__->table('inventory_stock_levels');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 },
        item_id => { data_type => 'integer' }, location_id => { data_type => 'integer', is_nullable => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            quantity_on_hand quantity_reserved quantity_on_order last_count_date updated_at));
    __PACKAGE__->set_primary_key('id');
    __PACKAGE__->add_unique_constraint(item_loc => [qw(item_id location_id)]);
    package PR::Txn; use base 'DBIx::Class::Core';
    __PACKAGE__->table('inventory_transactions');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            item_id location_id transaction_type quantity unit_cost reference_number todo_id
            sitename notes performed_by transaction_date created_at));
    __PACKAGE__->set_primary_key('id');
}
my %SRC = ('Accounting::InventoryItem' => 'PR::Item', 'Accounting::InventorySupplier' => 'PR::Supplier',
           'Accounting::InventoryItemSupplier' => 'PR::ItemSupplier',
           'Accounting::InventorySupplierInvoice' => 'PR::Invoice',
           'Accounting::InventorySupplierInvoiceLine' => 'PR::Line',
           'Accounting::InventoryLocation' => 'PR::Location', 'Accounting::InventoryStockLevel' => 'PR::Stock',
           'Accounting::InventoryTransaction' => 'PR::Txn');
PR::Schema->register_class($_ => $SRC{$_}) for keys %SRC;
my $schema = PR::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 });
$schema->deploy;
my $RS = sub { $schema->resultset($_[0]) };

my $SITE = 'Shanta';   # deliberately not 3d
my $nuts = $RS->('Accounting::InventoryItem')->create(
    { sitename => $SITE, sku => 'NUT-500', name => 'Cashews 500g', status => 'active', barcode => '0123456789012' });
$RS->('Accounting::InventoryItem')->create({ sitename => '3d', sku => 'TEA-1', name => 'Green tea', status => 'active' });
my $sup = $RS->('Accounting::InventorySupplier')->create({ sitename => $SITE, name => 'Nature Foods', status => 'active' });
my $locA = $RS->('Accounting::InventoryLocation')->create({ sitename => $SITE, name => 'Pantry', status => 'active' });
my $locB = $RS->('Accounting::InventoryLocation')->create({ sitename => $SITE, name => 'Freezer', status => 'active' });

my $root = tempdir(CLEANUP => 1);

# ---- mock Catalyst context ------------------------------------------------
{
    package PR::Api;   sub new { bless {}, shift } sub inventory_allowed { 1 }
    package PR::Inv;   sub new { bless {}, shift }
    sub _find_item_by_barcode {
        my ($s, $c, $site, $bc) = @_;
        return $schema->resultset('Accounting::InventoryItem')->search({ sitename => $site, barcode => $bc })->first;
    }
    package PR::C;
    sub new { my ($cl, %a) = @_; bless { session => $a{session}, stash => $a{stash} || {} }, $cl }
    sub session { $_[0]{session} }
    sub stash   { $_[0]{stash} }
    sub model   { $schema }
    sub controller { return $_[1] eq 'Api' ? PR::Api->new : $_[1] eq 'Inventory' ? PR::Inv->new : undef }
}
my $c = PR::C->new(session => { user_id => 7, username => 'tester', roles => ['admin'], SiteName => $SITE },
                   stash   => { SiteName => $SITE, inventory_image_root => "$root/static_images" });

# ---- mocked vision ----------------------------------------------------------
my @VISION_CALLS;
{
    package PR::Vision;
    sub new { bless { text => $_[1] }, $_[0] }
    sub read { my ($s, $c, %a) = @_; push @VISION_CALLS, \%a; return { ok => 1, text => $s->{text}, engine => 'mock' } }
    sub _downscale { my ($s, $p, $m) = @_; return ($p, $m || 'image/jpeg') }
}

use_ok('Comserv::Util::VisionRead');
use_ok('Comserv::Util::Inventory::PhotoRead');
use_ok('Comserv::Util::ConsignmentCountVision');
use_ok('Comserv::Util::Inventory::StockTxn');
use_ok('Comserv::Model::AI2::PhotoIntent');
require Comserv::Model::AI2::InvoiceCreate;
{
    no warnings 'redefine';
    *Comserv::Model::AI2::InvoiceCreate::_web_lookup_supplier = sub { {} };   # no network
    require Comserv::Util::InventoryBarcode;
    no warnings "once";
    *Comserv::Util::InventoryBarcode::item_payload = sub { my ($cl, $c, $item) = @_; return { item => { id => $item->id }, missing => [] } };
}

my $photo = "$root/in.jpg";
{ open my $fh, '>:raw', $photo or die; print {$fh} "\xFF\xD8\xFFfakejpeg"; close $fh }
sub reader { my $pr = Comserv::Util::Inventory::PhotoRead->new(root => $root, vision => PR::Vision->new($_[0]), @_[1..$#_]); $pr->{no_spawn} = 1; $pr }
sub ready_read {
    my ($pr, $mode) = @_;
    my $q = $pr->queue($c, sitename => $SITE, user_id => 7, username => 'tester', mode => $mode, image_path => $photo, mime => 'image/jpeg');
    $pr->finish(undef, $SITE, $q->{read_id});
    return $q->{read_id};
}
sub view { my ($pr, $id) = @_; return $pr->view($c, $schema, sitename => $SITE, user_id => 7, read_id => $id)->{read} }

# ---- the consignment count still runs through the shared engine ----------
{
    my $v = Comserv::Util::ConsignmentCountVision->new(cpu_retry => 0, attempt_grok => 0);
    isa_ok($v, 'Comserv::Util::VisionRead', 'ConsignmentCountVision');
    is($v->{num_predict}, 300, 'count keeps its answer length');
    no warnings 'redefine';
    local *Comserv::Util::VisionRead::_ollama_vision = sub {
        return { ok => 1, text => '{"counts":{"blue":2,"red":1,"yellow":0,"green":0},"confidence":0.9}', engine => 'ollama:mock' };
    };
    my $r = $v->analyse(undef, image_path => $photo, colours => [qw(blue yellow red green)]);
    ok($r->{ok} && $r->{counts}{blue} == 2, 'count analyse unchanged through VisionRead');
}

# ---- items mode, matching, 404s -------------------------------------------
my $pr = reader('{"raw_text":"CASHEWS 500g / Almond butter AB-250","lines":[{"name":"Cashews 500g","sku_or_label_text":"","qty":3},'
              . '{"name":"Almond butter","sku_or_label_text":"AB-250","qty":1}]}');
my $q = $pr->queue($c, sitename => $c->session->{SiteName}, user_id => 7, username => 'tester',
                   mode => 'items', image_path => $photo, mime => 'image/jpeg');
ok($q->{ok} && $q->{status} eq 'reading', 'queue -> reading');
is(view($pr, $q->{read_id})->{status}, 'reading', 'view while reading');
ok($pr->finish(undef, $SITE, $q->{read_id})->{ok}, 'worker finish ok');
my $v = view($pr, $q->{read_id});
is($v->{sitename}, $SITE, 'sitename from the session, not 3d');
like($v->{raw_text}, qr/CASHEWS/, 'raw_text kept');
is($v->{lines}[0]{match}{item_id}, $nuts->id, 'matched line');
is($v->{lines}[1]{proposed_sku}{sku}, 'AB-250', 'unmatched line gets proposed_sku');
is($pr->view($c, $schema, sitename => '3d', user_id => 7, read_id => $q->{read_id})->{status}, 404, "other site's read is 404");
is($pr->view($c, $schema, sitename => $SITE, user_id => 8, read_id => $q->{read_id})->{status}, 404, "other user's read is 404");

# attach_photo + items photo removed after confirm
my $cf = $pr->confirm($c, $schema, sitename => $SITE, user_id => 7, username => 'tester', read_id => $q->{read_id},
    lines => [ { index => 0, action => 'match', item_id => $nuts->id, attach_photo => 1 },
               { index => 1, action => 'skip' } ]);
ok($cf->{ok}, 'items confirm ok') or diag explain $cf;
like($cf->{photos_attached}[0]{image_path} // '', qr{^/static/inventory_images/Shanta/\d+-\d+\.jpg$}, 'photo attached through ItemImage');
like($nuts->discard_changes->image_path // '', qr{inventory_images/Shanta}, 'item image_path set (item page renders it)');
ok(!view($pr, $q->{read_id})->{has_photo}, 'items photo deleted from photo_reads after confirm');

# ---- invoice mode: totals mismatch, draft totals, auto-delete ----------------
my $inv_json = '{"raw_text":"Nature Foods\nINV NF-1001","supplier":"Nature Foods","invoice_number":"NF-1001","date":"2026-11-15",'
             . '"subtotal":36.00,"tax":1.80,"shipping":5.00,"total":42.80,'
             . '"lines":[{"name":"Cashews","sku":"NUT-500","qty":2,"unit_price":7.50},'
             . '{"name":"Dates 1kg","sku":"DT-1","qty":4,"unit_price":"$5.25"}]}';
$pr = reader($inv_json);
my $rid = ready_read($pr, 'invoice');
$v = view($pr, $rid);
is($v->{supplier}{match_id}, $sup->id, 'supplier matched through InvoiceCreate::match_supplier');
is($v->{invoice}{lines_sum}, 36, 'lines_sum');
is($v->{invoice}{mismatch}, 0, 'totals add up');
is($v->{lines}[0]{match}{sku}, 'NUT-500', 'invoice line matched by sku');

my $n_items = $RS->('Accounting::InventoryItem')->count;
my $guest = PR::C->new(session => { user_id => 9, username => 'guest' });
is($pr->confirm($guest, $schema, sitename => $SITE, user_id => 9, read_id => $rid,
    lines => [{ index => 0, action => 'skip' }])->{status}, 403, 'confirm needs invoice write permission');
$cf = $pr->confirm($c, $schema, sitename => $SITE, user_id => 7, username => 'tester', read_id => $rid, create_invoice => 1,
    lines => [ { index => 0, action => 'match', item_id => $nuts->id, qty => 3 },
               { index => 1, action => 'create', name => 'Medjool dates 1kg', sku => 'DT-1' } ]);
ok($cf->{ok}, 'invoice confirm ok') or diag explain $cf;
is($RS->('Accounting::InventoryItem')->count, $n_items + 1, 'one item created');
my $inv = $RS->('Accounting::InventorySupplierInvoice')->find($cf->{invoice_id});
is($inv->status, 'draft', 'invoice is a draft');
is($inv->total_amount, '42.80', 'printed total stored on the draft');
is($inv->tax_amount, '1.80', 'tax stored');
is($inv->shipping_amount, '5.00', 'shipping stored');
my ($l0) = $inv->lines->search({ item_id => $nuts->id })->all;
is($l0->quantity, 3, 'edited qty on the attached line');
ok(!view($pr, $rid)->{has_photo}, 'invoice photo auto-deleted after confirm');
is($pr->confirm($c, $schema, sitename => $SITE, user_id => 7, read_id => $rid,
    lines => [{ index => 0, action => 'skip' }])->{status}, 409, 'second confirm is 409');

# mismatch + keep_photo
$pr = reader('{"supplier":"Nature Foods","invoice_number":"NF-2","total":30.00,"lines":[{"name":"Cashews","sku":"NUT-500","qty":2,"unit_price":7.50}]}');
$rid = ready_read($pr, 'invoice');
is(view($pr, $rid)->{invoice}{mismatch}, 1, 'totals mismatch flagged');
$cf = $pr->confirm($c, $schema, sitename => $SITE, user_id => 7, read_id => $rid, create_invoice => 1, keep_photo => 1,
    lines => [{ index => 0, action => 'match', item_id => $nuts->id }]);
ok($cf->{ok} && view($pr, $rid)->{has_photo}, 'keep_photo keeps the invoice photo');

# ---- supplier_create on confirm ----------------------------------------------
$pr = reader('{"supplier":"Fresh Farms","supplier_contact":{"phone":"250-555-0100","email":"orders@freshfarms.example"},'
           . '"invoice_number":"FF-9","lines":[{"name":"Kale","qty":5,"unit_price":2}]}');
$rid = ready_read($pr, 'invoice');
$v = view($pr, $rid);
is($v->{supplier}{match_id}, undef, 'unknown supplier not matched');
is($v->{supplier}{proposed}{phone}, '250-555-0100', 'supplier proposed from the invoice');
ok(ref $v->{supplier}{candidates} eq 'ARRAY', 'supplier candidates offered');
$cf = $pr->confirm($c, $schema, sitename => $SITE, user_id => 7, username => 'tester', read_id => $rid, create_invoice => 1,
    supplier_create => { name => 'Fresh Farms', phone => '250-555-0100' },
    lines => [{ index => 0, action => 'create' }]);
ok($cf->{ok} && $cf->{supplier_created}, 'supplier_create on confirm') or diag explain $cf;
my $ff = $RS->('Accounting::InventorySupplier')->find($cf->{supplier_created});
is($ff->name, 'Fresh Farms', 'supplier row created');
is($ff->phone, '250-555-0100', 'contact from the invoice filled');
is($RS->('Accounting::InventorySupplierInvoice')->find($cf->{invoice_id})->supplier_id, $ff->id, 'invoice uses the new supplier');

# ---- failed read keeps text; reparse ------------------------------------------
$pr = reader('I could not find a table here, sorry.');
$rid = ready_read($pr, 'invoice');
$v = view($pr, $rid);
is($v->{status}, 'failed', 'unreadable answer -> failed');
like($v->{raw_text}, qr/could not find/, 'failed read keeps its text');
my $vc0 = @VISION_CALLS;
my $rp = $pr->reparse($c, sitename => $SITE, user_id => 7, read_id => $rid,
    raw_text => "2 x Cashews 500g @ 7.50\nSubtotal 15.00\nTotal 15.00");
ok($rp->{ok} && $rp->{engine} eq 'text:parser', 'reparse falls back to the plain parser') or diag explain $rp;
$v = view($pr, $rid);
is($v->{status}, 'ready', 'ready after reparse');
is($v->{lines}[0]{qty}, 2, 'qty from edited text');
is($v->{invoice}{total}, 15, 'total from edited text');
is($v->{invoice}{mismatch}, 0, 'edited text adds up');
my $pr_ai = reader('x', text_ai => sub { '{"lines":[{"name":"Dates","qty":4,"unit_price":5.25}],"total":21.00}' });
$rp = $pr_ai->reparse($c, sitename => $SITE, user_id => 7, read_id => $rid, raw_text => 'Dates four at 5.25');
is($rp->{engine}, 'text:ai', 'reparse uses the text AI when it answers');
is(scalar @VISION_CALLS, $vc0, 'reparse made no vision call');

# ---- rerun / delete -------------------------------------------------------------
my $rr = $pr->rerun($c, sitename => $SITE, user_id => 7, read_id => $rid);
is($rr->{status}, 'reading', 'rerun -> reading');
$pr->finish(undef, $SITE, $rid);
ok($pr->delete_photo($c, sitename => $SITE, user_id => 7, read_id => $rid)->{photo_deleted}, 'delete photo');
ok(-f $pr->_file($SITE, $rid), 'JSON kept after delete');
is($pr->rerun($c, sitename => $SITE, user_id => 7, read_id => $rid)->{status}, 409, 'rerun after delete is 409');
is($pr->list_reads($c, is_admin => 0)->{status}, 403, 'admin list denied for non-admins');
ok(scalar @{ $pr->list_reads($c, is_admin => 1)->{reads} } >= 5, 'admin list shows reads');

# ---- barcode scan + apply -------------------------------------------------------
my $sc = $pr->scan($c, $schema, sitename => $SITE, barcode => '0123456789012', inv => PR::Inv->new);
ok($sc->{found} && $sc->{matched_by} eq 'barcode', 'scan found by barcode');
is_deeply($sc->{actions}, [qw(receive count use move)], 'four actions offered');
ok(scalar @{ $sc->{locations} } == 2, 'site locations offered');
$sc = $pr->scan($c, $schema, sitename => $SITE, description => 'cashews');
ok($sc->{found} && $sc->{matched_by} eq 'description' && $sc->{item}{item_id} == $nuts->id, 'scan found by description');
$sc = $pr->scan($c, $schema, sitename => $SITE, barcode => '999', description => 'zzz unknown');
ok(!$sc->{found} && $sc->{proposed_sku}{barcode} eq '999', 'unknown scan proposes a new item');

my $qoh = sub { my $s = $RS->('Accounting::InventoryStockLevel')->find({ item_id => $nuts->id, location_id => $_[0]->id }); $s ? 0 + $s->quantity_on_hand : 0 };
my %ap = (sitename => $SITE, user_id => 7, username => 'tester', item_id => $nuts->id);
ok($pr->scan_apply($c, $schema, %ap, action => 'receive', qty => 10, location_id => $locA->id, unit_cost => 7.5)->{ok}, 'receive');
is($qoh->($locA), 10, 'receive adds stock');
$pr->scan_apply($c, $schema, %ap, action => 'use', qty => 3, location_id => $locA->id);
is($qoh->($locA), 7, 'use takes stock');
$pr->scan_apply($c, $schema, %ap, action => 'count', qty => 5, location_id => $locA->id);
is($qoh->($locA), 5, 'count sets stock');
my $cnt = $RS->('Accounting::InventoryTransaction')->search({ transaction_type => 'count_adjust' })->first;
is($cnt->quantity, -2, 'count_adjust stores the signed difference');
my $mv = $pr->scan_apply($c, $schema, %ap, action => 'move', qty => 2, location_id => $locA->id, to_location_id => $locB->id);
is(scalar @{ $mv->{transactions} }, 2, 'move writes two transfer rows');
is($qoh->($locA), 3, 'move takes from the source');
is($qoh->($locB), 2, 'move adds to the destination');
is($RS->('Accounting::InventoryTransaction')->search({ transaction_type => 'transfer' })->count, 2, 'transfer type used');
is($pr->scan_apply($c, $schema, %ap, action => 'move', qty => 1, location_id => $locA->id, to_location_id => $locA->id)->{status},
   400, 'move to the same location refused');
my $mk = $pr->scan_apply($c, $schema, sitename => $SITE, user_id => 7, username => 'tester', action => 'receive', qty => 4,
    location_id => $locB->id, create => { name => 'Rolled oats 1kg', sku => 'OAT-1', barcode => '5550001112223' });
ok($mk->{ok} && $mk->{created}, 'scan_apply creates the item then receives');
is($RS->('Accounting::InventoryItem')->find($mk->{item_id})->barcode, '5550001112223', 'barcode saved on the new item');

# ---- Chat-with-AI reaches the same subs -----------------------------------------
{
    my $hits = {};
    no warnings 'redefine';
    my $orig_scan = \&Comserv::Util::Inventory::PhotoRead::scan;
    local *Comserv::Util::Inventory::PhotoRead::scan = sub { $hits->{scan}++; $orig_scan->(@_) };
    my $chat_pr = reader('{"lines":[{"name":"Cashews 500g","qty":1}]}');
    my $intent = Comserv::Model::AI2::PhotoIntent->new(reader => $chat_pr);
    my $r = $intent->try_chat($c, prompt => 'scan 0123456789012');
    ok($r->{handled} && $hits->{scan} && $r->{photo_action}{scan}{found}, 'chat "scan <barcode>" -> PhotoRead::scan');
    $r = $intent->try_chat($c, prompt => 'Here is the invoice from Nature Foods',
        image_data => 'data:image/jpeg;base64,' . encode_base64("\xFF\xD8\xFFfake", ''));
    ok($r->{handled} && $r->{photo_action}{kind} eq 'read' && $chat_pr->valid_id($r->{photo_action}{read_id}),
       'chat invoice image -> PhotoRead::queue');
    is($intent->try_chat($c, prompt => 'what is the weather'), undef, 'ordinary chat untouched');

    my $vis = PR::Vision->new('A jar of honey. Label: Wildflower Honey 500g');
    my $before = @VISION_CALLS;
    my $di = Comserv::Model::AI2::PhotoIntent->new(vision => $vis)->describe_image($c,
        image_data => encode_base64("\xFF\xD8\xFFfake", ''), image_mime => 'image/jpeg', prompt => 'what is this?');
    ok($di->{ok} && @VISION_CALLS == $before + 1, 'chat image_data reaches VisionRead');
    like(Comserv::Model::AI2::PhotoIntent->new->prompt_with('what is this?', $di), qr/Wildflower Honey.*what is this\?/s,
         'vision text goes into the chat prompt');

    open my $fh, '<', "$FindBin::Bin/../lib/Comserv/Controller/AI2.pm" or die;
    my $src = do { local $/; <$fh> };
    like($src, qr/!\$is_guest_chat && defined \$json_data->\{image_data\}/, 'AI2::chat reads image_data for signed-in users only');
    like($src, qr/PhotoIntent->new->try_chat/, 'AI2::chat calls the shared PhotoIntent');
}

# ---- mail path still drafts through the shared half (refactor guard) -------
{
    package PR::Classifier;
    sub new { bless {}, shift }
    sub message_body { 'body' }
    sub _parse_invoice_line_items {
        return ({ name => 'Cashews 500g', sku => 'NUT-500', quantity => 1, price => 7 },
                { name => 'Unknown thing', quantity => 2, price => 1 },
                { name => 'Zero qty', quantity => 0, price => 1 });
    }
}
{
    require Comserv::Util::Inventory::MailInvoiceStock;
    my $ms = Comserv::Util::Inventory::MailInvoiceStock->new;
    my ($minv, $merr) = $ms->_create_draft_invoice($c, $schema, sitename => $SITE, supplier_id => $sup->id,
        invoice_number => 'MAIL-abc', invoice_date => '2026-11-16', total_amount => 9, notes => 'n', created_by => 'mail-invoice');
    ok($minv && !$merr, 'mail header via _create_draft_invoice');
    my $done = $ms->_finish_invoice($c, $schema, PR::Classifier->new, $minv, {}, $SITE, $sup);
    is($done->{reason}, 'unmatched_lines', 'mail invoice with an unknown line stays a draft');
    is(scalar($minv->lines->all), 2, 'qty 0 line dropped');
}

# ---- parse guards ---------------------------------------------------------------
is(Comserv::Util::Inventory::PhotoRead->new->parse_text('items', 'no json here'), undef, 'prose is not lines');
is($pr->queue($c, sitename => $SITE, user_id => 7, mode => 'bogus', image_path => $photo)->{status}, 400, 'bad mode is 400');
is($pr->view($c, $schema, sitename => $SITE, user_id => 7, read_id => '../../etc')->{status}, 404, 'non-id read_id is 404');

done_testing;

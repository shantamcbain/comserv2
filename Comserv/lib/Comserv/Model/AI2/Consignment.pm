package Comserv::Model::AI2::Consignment;
# ONE brain for consignment work from Chat-with-AI (widget + editor).
#
# Reuses the existing Inventory consignment tables -- NO new schema:
#   Accounting::InventoryConsignment       (batch: partner, date_sent, status)
#   Accounting::InventoryConsignmentLine   (item, qty sent/sold/returned, retail)
#   Accounting::InventoryConsignmentPartner(partner, commission_percent)
#   Accounting::InventoryTransaction       (consignment_out / consignment_return)
#   Printing3dJob                          (replacement print jobs)
#
# Why this exists: the free/cheap chat models kept asking the user for an item
# SKU and a price that the server can look up itself, and did not know Shanta's
# consignment rules (retail less commission, cash applied to AP oldest first,
# no supplier invoice, replacement consignment per sale). Same intercept pattern
# as AI2::TodoCreate / AI2::InvoiceCreate: the SERVER resolves parties and priced
# items, so a small model can never invent them.

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON qw(encode_json decode_json);
use Comserv::Util::Logging;
use Comserv::Util::AppTime;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# Words that mean nothing when matching an inventory item name.
my %STOP = map { $_ => 1 } qw(
    the a an and or of for to on in at from with please add update
    coop co-op customer consign consignment consigned sold sale sales
    two three four five six seven eight nine ten one
    need needs needed replaced replace replacement new item items
    that they them their this these those was were has have had
    i we you it is are be was been do does did
);

my @SALE_WORDS = qw(sold sale sales sell sells bought purchased taken);

sub sitename {
    my ($self, $c) = @_;
    for my $cand (
        $c->stash->{SiteName},
        $c->session->{SiteName},
        $c->session->{site_name},
        $c->stash->{site_name},
    ) {
        next unless defined $cand && $cand =~ /\S/;
        $cand =~ s/^\s+|\s+$//g;
        return $cand if length $cand;
    }
    return 'CSC';
}

sub _is_guest {
    my ($self, $c) = @_;
    my $u = $c->session->{username} || '';
    return 1 if !$u || lc($u) eq 'guest';
    return 0;
}

sub _roles {
    my ($self, $c) = @_;
    my $r = $c->session->{roles} || [];
    $r = [ split(/\s*,\s*/, $r) ] unless ref($r);
    return [ map { lc($_) } @$r ];
}

sub _can_write {
    my ($self, $c) = @_;
    return 0 if $self->_is_guest($c);
    my $roles = $self->_roles($c);
    return 1 if grep { /^(admin|developer|accounting|site_admin|editor)$/ } @$roles;
    return 0;
}

sub _today {
    my ($self) = @_;
    my @t = localtime;
    return sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
}

# ---------------------------------------------------------------- intent ----
# True for consignment talk and for "the coop sold N <items>" style reports.
# Deliberately narrow: a plain product/navigation question must NOT match.
sub detect_intent {
    my ($self, $text) = @_;
    my $t = lc($text // '');
    return 0 unless length $t;
    # A question is not a write. "How does consignment work?" / "What partners do
    # we have?" must reach the LLM, not create rows.
    return 0 if $t =~ /^\s*(how|what|where|why|who|when|which|is|are|do|does|did|can|could|should|would)\b/;
    return 1 if $t =~ /\bconsign(ment|ed|or)?\b/;
    return 0 if $t =~ /\b(how|what|where|why|explain|tell me about)\b.*\bconsign/;
    if ($t =~ /\b(co-?op|monashee)\b/) {
        return 1 if $t =~ /\b(sold|sale|sell|took|bought)\b/;
        return 1 if $t =~ /\breplace(ment|d)?\b/;
        return 1 if $t =~ /\b(record|add|update|settle)\b/;
    }
    return 0;
}

# Partner name mentioned in the text ("coop", "monashee coop", ...).
sub partner_hint {
    my ($self, $text) = @_;
    my $t = lc($text // '');
    return 'coop'   if $t =~ /\bco-?op\b/;
    return 'monashee' if $t =~ /\bmonashee\b/;
    return '';
}

# Quantities: "two lids", "2 lids", "sold 3". Returns the first small integer
# that is not part of a date/price.
sub parse_qty {
    my ($self, $text) = @_;
    my $t = lc($text // '');
    my %word = (one => 1, two => 2, three => 3, four => 4, five => 5,
                six => 6, seven => 7, eight => 8, nine => 9, ten => 10,
                a => 1, an => 1, single => 1, pair => 2);
    if ($t =~ /\b(one|two|three|four|five|six|seven|eight|nine|ten|single|pair|a|an)\b\s+[a-z]/) {
        return $word{$1} if $word{$1};
    }
    if ($t =~ /\b(\d{1,3})\b(?!\s*(?:st|nd|rd|th|am|pm|:|\.|%))/) {
        my $n = $1;
        return $n if $n > 0 && $n < 500;
    }
    return 1;
}

# ------------------------------------------------------- inventory lookup ----
# Tokens worth searching for, longest first.
sub _tokens {
    my ($self, $text) = @_;
    my $t = lc($text // '');
    $t =~ s/[^a-z0-9 ]+/ /g;
    my @tok = grep { length($_) > 2 && !$STOP{$_} } split /\s+/, $t;
    # "lids" must match an item stored as "Lid": try the singular as well.
    for my $w (@tok) {
        (my $s = $w) =~ s/s$//;
        push @tok, $s if length($s) >= 3 && $s ne $w;
    }
    my %seen;
    @tok = grep { !$seen{$_}++ } @tok;
    return [ sort { length($b) <=> length($a) } @tok ];
}

# Match inventory items on this site by the words in the prompt.
# Returns [ { id, name, sku, unit_price, on_hand, show_in_shop, matched } ].
sub item_matches {
    my ($self, $c, $text) = @_;
    my $sites    = $self->_site_candidates($c);
    my $tokens   = $self->_tokens($text);
    return [] unless @$tokens;

    my $schema = eval { $c->model('DBEncy') };
    return [] unless $schema;

    my @cols = qw(id sitename name sku unit_price unit_cost category item_origin show_in_shop status);
    my @want = @$tokens[0 .. ($#$tokens > 3 ? 3 : $#$tokens)];

    my $rs = eval {
        my @or = map { { name => { 'like', "%$_%" } } } @want;
        $schema->resultset('Accounting::InventoryItem')->search(
            { sitename => { -in => $sites }, status => 'active', '-or' => \@or },
            { columns => \@cols, order_by => 'name' }
        );
    };
    return [] unless $rs;

    my %stock;
    eval {
        my $dbh = $schema->storage->dbh;
        my $rows = $dbh->selectall_arrayref(
            'SELECT item_id,
                    COALESCE(SUM(quantity_on_hand),0) - COALESCE(SUM(quantity_reserved),0) AS avail
               FROM inventory_stock_levels
              GROUP BY item_id', { Slice => {} });
        %stock = map { $_->{item_id} => $_->{avail} } @$rows if $rows;
    };

    my @out;
    my $n = 0;
    while (my $item = $rs->next) {
        last if $n++ >= 12;
        my $name = lc($item->name // '');
        my $matched = 0;
        $matched++ for grep { $name =~ /\Q$_\E/ } @want;
        push @out, {
            id          => $item->id,
            sitename    => $item->sitename // '',
            name        => $item->name // '',
            sku         => $item->sku // '',
            unit_price  => defined $item->unit_price ? $item->unit_price + 0 : 0,
            on_hand     => $stock{ $item->id } // 0,
            show_in_shop => $item->show_in_shop ? 1 : 0,
            category    => $item->category // '',
            matched     => $matched,
        };
    }
    return [ sort { $b->{matched} <=> $a->{matched} || $a->{name} cmp $b->{name} } @out ];
}

# Sites worth looking at. The session site comes first, then every site that
# actually has consignment partners -- the 3d stock and partners live under
# sitename '3d', so chatting from another site must still find them.
sub _site_candidates {
    my ($self, $c) = @_;
    my @sites = ($self->sitename($c));
    my $schema = eval { $c->model('DBEncy') };
    if ($schema) {
        my $rows = eval {
            $schema->storage->dbh->selectcol_arrayref(
                "SELECT DISTINCT sitename FROM inventory_consignment_partners WHERE status='active'")
        } || [];
        push @sites, @$rows;
    }
    my %seen;
    return [ grep { defined($_) && length($_) && !$seen{lc $_}++ } @sites ];
}

# Partner rows ("coop" -> Monashee Coop), across the candidate sites.
sub partners {
    my ($self, $c) = @_;
    my $schema = eval { $c->model('DBEncy') } or return [];
    my $sites  = $self->_site_candidates($c);
    my @rows = eval {
        $schema->resultset('Accounting::InventoryConsignmentPartner')->search(
            { sitename => { -in => $sites } }, { order_by => 'name' })->all;
    };
    return [ map { {
        id                 => $_->id,
        sitename           => $_->sitename // '',
        name               => $_->name // '',
        commission_percent => defined $_->commission_percent ? $_->commission_percent + 0 : 0,
        status             => $_->status // '',
    } } @rows ];
}

sub match_partner {
    my ($self, $c, $hint) = @_;
    my $list = $self->partners($c);
    return undef unless @$list;
    $hint = lc($hint // '');
    if (length $hint) {
        for my $p (@$list) {
            return $p if index(lc($p->{name}), $hint) >= 0;
        }
        # "coop" also covers "Co-op" spellings.
        my $squashed = $hint;
        $squashed =~ s/[-_ ]//g;
        for my $p (@$list) {
            my $n = lc($p->{name});
            $n =~ s/[-_ ]//g;
            return $p if index($n, $squashed) >= 0;
        }
    }
    return $list->[0] if @$list == 1;
    return undef;
}

# ------------------------------------------------------------- prompting ----
# The business rules. Shanta's consignment model, stated once so small models
# stop re-deriving it (and stop asking for data the server already has).
sub chat_contract {
    my ($self, $c) = @_;
    return '' if $self->_is_guest($c);
    my $sitename = $self->sitename($c);

    my $block = <<"END";
CONSIGNMENT (SiteName=$sitename) - the rules are FIXED, do not ask the user to explain them:
- A consignment partner takes our goods and sells them for us. Shanta's partner is Monashee Coop (30% commission).
- The partner's cut is deducted from retail: we receive retail LESS 30%. Retail price is the item's unit_price in inventory.
- The partner does NOT issue an invoice. A consignment is not a supplier bill - never create a supplier/AP invoice for it.
- When the partner reports a sale, we create a REPLACEMENT consignment (a new consignment number) for the sold quantities.
- The sale itself reaches accounting as a sale in accounts payable; payment arrives in cash and is applied to accounts payable OLDEST FIRST.
- Existing stock covers the replacement; only the shortfall is queued as 3D print jobs (Printing3dJob, status=queued).

NEVER ask the user for an SKU, item id or price: look it up. The items and partners for this site are already injected below when relevant.
Ask only when the item genuinely does not exist (no match at all) or when two different items match equally well.
END
    return $block;
}

# Live data: partners + the inventory rows that match what the user said.
sub context_block {
    my ($self, $c, %args) = @_;
    return '' if $self->_is_guest($c);
    my $prompt = $args{prompt} // '';
    return '' unless $self->detect_intent($prompt) || $prompt =~ /\b(replacement|restock|sprout)/i;

    my $sitename = $self->sitename($c);
    my $parts = $self->partners($c);
    my $items = $self->item_matches($c, $prompt);
    my $qty   = $self->parse_qty($prompt);

    my $out = "LIVE CONSIGNMENT DATA (from the database - authoritative, use it, do not ask for it):\n";
    if (@$parts) {
        $out .= "Partners on $sitename:\n";
        for my $p (@$parts) {
            $out .= sprintf("  #%d %s (commission %s%%)\n",
                $p->{id}, $p->{name}, $p->{commission_percent});
        }
    }
    else {
        $out .= "No consignment partners are set up on $sitename yet "
              . "(/Inventory/consignment/partners).\n";
    }

    if (@$items) {
        $out .= "Inventory items matching the user's words (id | name | sku | retail | on hand):\n";
        for my $i (@$items[0 .. ($#$items > 7 ? 7 : $#$items)]) {
            my $net = sprintf('%.2f', $i->{unit_price} * 0.70);
            $out .= sprintf("  #%d %s | sku=%s | retail=%.2f | net_after_30%%=%s | on_hand=%s\n",
                $i->{id}, $i->{name}, ($i->{sku} || '-'), $i->{unit_price}, $net, $i->{on_hand});
        }
        my $top = $items->[0];
        $out .= "Best match for this turn: #$top->{id} $top->{name} at retail $top->{unit_price}";
        $out .= " (qty in the request: $qty)" if $qty;
        $out .= "\n";
    }
    else {
        $out .= "No inventory item on $sitename matches the user's words. "
              . "If the request needs an item, ask which product they mean - otherwise answer normally.\n";
    }
    return $out;
}

# --------------------------------------------------------------- writes ----
# Create a consignment (new stock out, or the replacement for a sale).
# params: partner_id|partner_name, date_sent, notes, kind, lines => [ {item_id, quantity, retail_price, note} ]
# Returns { ok, consignment_id, lines, message } or { ok=>0, error=>... }
sub create_from_params {
    my ($self, $c, $params) = @_;
    $params ||= {};
    return { ok => 0, error => 'Not allowed' } unless $self->_can_write($c);

    my $schema = eval { $c->model('DBEncy') };
    return { ok => 0, error => 'Database not available' } unless $schema;

    my $sitename = $self->sitename($c);
    my $user     = $c->session->{username} || 'ai';

    my $partner;
    if (my $pid = $params->{partner_id}) {
        my $row = eval { $schema->resultset('Accounting::InventoryConsignmentPartner')->find({ id => $pid }) };
        if ($row) {
            $partner = {
                id                 => $row->id,
                sitename           => $row->sitename // '',
                name               => $row->name // '',
                commission_percent => defined $row->commission_percent ? $row->commission_percent + 0 : 0,
            };
        }
    }
    $partner ||= $self->match_partner($c, $params->{partner_name} // '');
    unless ($partner && $partner->{id}) {
        my $list = $self->partners($c);
        return { ok => 0, need => 'partner',
                 error => 'Which consignment partner? ' .
                          (@$list ? join(', ', map { $_->{name} } @$list) : 'none are set up yet') };
    }

    my @lines = @{ $params->{lines} || [] };
    unless (@lines) {
        return { ok => 0, need => 'item', error => 'Which item(s) and how many?' };
    }

    # Consignment data lives with the partner's site (3d), not necessarily the
    # site the chat was opened on.
    $sitename = $partner->{sitename} if $partner->{sitename};

    my $date = $params->{date_sent} // '';
    $date = $self->_today unless $date =~ /^\d{4}-\d{2}-\d{2}$/;

    my ($id, @made, @queued);
    my $err;
    try {
        $schema->txn_do(sub {
            my $cons = $schema->resultset('Accounting::InventoryConsignment')->create({
                sitename         => $sitename,
                partner_id       => $partner->{id},
                reference_number => $params->{reference_number} || undef,
                date_sent        => $date,
                status           => 'open',
                notes            => $params->{notes}
                                    || (($params->{kind} // '') eq 'replacement'
                                        ? 'Replacement for consignment sale' : undef),
                created_by       => $user,
            });
            $id = $cons->id;

            for my $l (@lines) {
                my $item_id = $l->{item_id} or next;
                my $qty     = $l->{quantity} || 0;
                next unless $qty > 0;
                my $item = $schema->resultset('Accounting::InventoryItem')->find({ id => $item_id, sitename => $sitename });
                next unless $item;
                my $retail = $l->{retail_price};
                $retail = $item->unit_price unless defined $retail && $retail =~ /^\d+(\.\d{1,2})?$/;

                $schema->resultset('Accounting::InventoryConsignmentLine')->create({
                    consignment_id    => $id,
                    item_id           => $item_id,
                    quantity_sent     => $qty,
                    quantity_sold     => 0,
                    quantity_returned => 0,
                    retail_price      => $retail || undef,
                    notes             => $l->{note} || undef,
                });
                $schema->resultset('Accounting::InventoryTransaction')->create({
                    sitename         => $sitename,
                    item_id          => $item_id,
                    transaction_type => 'consignment_out',
                    quantity         => -$qty,
                    reference_number => 'CONSIGN-' . $id,
                    notes            => 'Consigned to ' . ($partner->{name} // ''),
                    performed_by     => $user,
                    transaction_date => Comserv::Util::AppTime->now_utc,
                });
                push @made, { item_id => $item_id, name => $item->name, qty => $qty, retail => $retail };
            }
        });
    }
    catch {
        $err = $_;
    };
    return { ok => 0, error => "Consignment create failed: $err" } if $err;
    return { ok => 0, error => 'No valid lines (item + quantity)' } unless @made;

    return {
        ok             => 1,
        consignment_id => $id,
        partner        => $partner->{name},
        date_sent      => $date,
        lines          => \@made,
        message        => sprintf('Consignment #%d created for %s (%s) with %d line(s).',
                                  $id, $partner->{name}, $date, scalar(@made)),
    };
}

# Queue print jobs for a consignment line (the replacement shortfall).
# Only the quantity NOT already on hand is queued, so existing stock is used
# first (the traveller picks it, the print queue makes the rest).
sub queue_prints {
    my ($self, $c, %args) = @_;
    return { ok => 0, error => 'Not allowed' } unless $self->_can_write($c);
    my $schema = eval { $c->model('DBEncy') };
    return { ok => 0, error => 'Database not available' } unless $schema;
    my $sitename = $self->sitename($c);
    my $user     = $c->session->{username} || 'ai';
    my $cid      = $args{consignment_id} or return { ok => 0, error => 'consignment_id required' };

    my $cons = eval {
        $schema->resultset('Accounting::InventoryConsignment')->find(
            { 'me.id' => $cid },
            { prefetch => ['partner', { 'lines' => 'item' }] });
    };
    return { ok => 0, error => "Consignment #$cid not found" } unless $cons;
    $sitename = $cons->sitename if $cons->sitename;

    my @queued;
    my @errors;
    for my $line ($cons->lines->all) {
        my $item = $line->item or next;
        my $want = $line->quantity_sent || 0;
        next unless $want > 0;
        my $have = eval { $self->_on_hand($c, $item->id) } // 0;
        my $short = $want - $have;
        next unless $short > 0;
        my $fil_col = $args{filament_color} // '';
        if (!$fil_col && ($line->notes // '') =~ /\[FIL:[^,]*,\s*([^\]]+)\]/) { $fil_col = $1; }
        try {
            $schema->resultset('Printing3dJob')->create({
                sitename            => $sitename,
                model_id            => undef,
                consignment_id      => $cid,
                consignment_line_id => $line->id,
                item_name           => $item->name // 'Unknown',
                user_id             => $c->session->{user_id} || 0,
                username            => $user,
                status              => 'queued',
                quantity            => $short,
                filament_type       => $args{filament_type} || undef,
                filament_color      => $fil_col || undef,
                notes               => 'Replacement for consignment #' . $cid
                                       . ($cons->partner ? ' (' . $cons->partner->name . ')' : ''),
                inventory_reserved  => 0,
                created_at          => Comserv::Util::AppTime->now_utc,
            });
            push @queued, { item => $item->name, qty => $short, on_hand => $have };
        }
        catch { push @errors, $_ };
    }
    return { ok => 1, queued => \@queued, errors => \@errors,
             message => @queued ? scalar(@queued) . ' print job(s) queued' : 'Nothing to print - stock covers it' };
}

sub _on_hand {
    my ($self, $c, $item_id) = @_;
    my $schema = $c->model('DBEncy');
    my $dbh = $schema->storage->dbh;
    my $row = $dbh->selectrow_arrayref(
        'SELECT COALESCE(SUM(quantity_on_hand),0) - COALESCE(SUM(quantity_reserved),0)
           FROM inventory_stock_levels WHERE item_id = ?', undef, $item_id);
    return $row ? $row->[0] + 0 : 0;
}

# ------------------------------------------------------------ turn entry ----
# Deterministic handling for a consignment report. Returns undef when the turn
# is not a consignment write (so the caller falls through to the LLM).
sub try_chat_create {
    my ($self, $c, $prompt) = @_;
    return undef unless $self->detect_intent($prompt);
    return undef unless $self->_can_write($c);

    my $partner = $self->match_partner($c, $self->partner_hint($prompt));
    my $items   = $self->item_matches($c, $prompt);
    my $qty     = $self->parse_qty($prompt);

    unless ($partner) {
        my $list = $self->partners($c);
        return {
            response => 'I can record that as consignment activity, but I need the partner first. '
                      . (@$list ? 'Known partners: ' . join(', ', map { $_->{name} } @$list)
                                : 'No consignment partners are set up yet - add one at /Inventory/consignment/partners.'),
            handled => 1,
            consignment_action => { need => 'partner' },
        };
    }
    unless (@$items) {
        my $pname = $partner->{name};
        return {
            response => "I can create a replacement consignment for $pname, "
                      . "but no inventory item matches those words. Which product is it?",
            handled => 1,
            consignment_action => { need => 'item' },
        };
    }

    # Ambiguous only when the two best matches score the same AND differ in name.
    if (@$items > 1 && $items->[0]{matched} == $items->[1]{matched}
        && lc($items->[0]{name}) ne lc($items->[1]{name})
        && $items->[0]{matched} < 2) {
        my @pick = map { sprintf('#%d %s ($%.2f)', $_->{id}, $_->{name}, $_->{unit_price}) }
                   @$items[0 .. ($#$items > 2 ? 2 : $#$items)];
        return {
            response => "More than one item matches: " . join('; ', @pick) . '. Which one?',
            handled => 1,
            consignment_action => { need => 'pick', candidates => $items },
        };
    }

    my $item = $items->[0];
    my $res  = $self->create_from_params($c, {
        partner_id   => $partner->{id},
        date_sent    => $self->_today,
        kind         => 'replacement',
        lines        => [ {
            item_id      => $item->{id},
            quantity     => $qty,
            retail_price => $item->{unit_price},
            note         => 'Reported sold at ' . $partner->{name},
        } ],
    });
    return {
        response => 'Could not create the consignment: ' . ($res->{error} // 'unknown error'),
        handled => 1,
        consignment_action => { ok => 0, error => $res->{error} },
    } unless $res->{ok};

    my $q = $self->queue_prints($c, consignment_id => $res->{consignment_id});
    my $print_note = ($q && $q->{queued} && @{ $q->{queued} })
        ? sprintf(' Print queue: %s.', join('; ', map { "$_->{qty} x $_->{item}" } @{ $q->{queued} }))
        : ' Stock already covers the replacement, so nothing was queued to print.';

    return {
        response => sprintf('%s Item: %s x%d at retail $%.2f (net after %s%% commission: $%.2f).%s View: /Inventory/consignment/view/%d',
            $res->{message}, $item->{name}, $qty, $item->{unit_price},
            ($partner->{commission_percent} || 0),
            ($item->{unit_price} * (1 - ($partner->{commission_percent} || 0) / 100)),
            $print_note, $res->{consignment_id}),
        handled => 1,
        consignment_action => {
            ok             => 1,
            consignment_id => $res->{consignment_id},
            item           => $item->{name},
            quantity       => $qty,
            queued         => $q->{queued} || [],
        },
    };
}

__PACKAGE__->meta->make_immutable;
1;

package Comserv::Util::Manufacturing::Traveler;

use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::AppTime;
use URI::Escape qw(uri_escape uri_unescape);

# HDRY system master assembly (in-house / product):
#   51 INT-HDRY-001 — order line target; wheel kit is a nested BOM under base (52).

use constant HDRY_SYSTEM_ID  => 51;
use constant HDRY_SYSTEM_SKU => 'INT-HDRY-001';

# Base and Add-on sub-assemblies for separate in-house orders:
use constant HDRY_BASE_ID  => 52;
use constant HDRY_BASE_SKU => 'INT-HDRY-001-P36787';
use constant HDRY_ADDON_ID  => 53;
use constant HDRY_ADDON_SKU => 'INT-HDRY-001-P36788';

# Order statuses that still need manufacturing / picking
use constant OPEN_ORDER_STATUSES => qw(
    pending open processing in_progress confirmed accepted
    picking manufacturing partial
);

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

sub _sitename {
    my ($self, $c) = @_;
    return $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
}

sub _today {
    return Comserv::Util::AppTime->today_utc_ymd;
}

sub _fmt_date {
    my ($self, $dt) = @_;
    return $self->_today unless defined $dt;
    if (ref($dt) && $dt->can('ymd')) {
        return $dt->ymd;
    }
    my $s = "$dt";
    $s =~ s/ .*$//;
    return $s || $self->_today;
}

sub get_dryer_modules {
    my ($self, $c) = @_;
    my @modules;
    eval {
        my $schema = $c->model('DBEncy');
        my $rs = $schema->resultset('Accounting::InventoryItem')->search(
            {
                sitename => $self->_sitename($c),
                -or => [
                    { sku => { -like => 'INT-HDRY-001%' } },
                    { sku => 'HW-WHEEL-KIT' },
                    { id  => { -in => [51, 52, 53, 54, 55, 56, 57, 99] } },
                ],
            },
            { order_by => ['sku', 'id'] },
        );
        while (my $it = $rs->next) {
            push @modules, {
                id             => $it->id,
                sku            => $it->sku,
                name           => $it->name,
                item_origin    => eval { $it->item_origin } // '',
                is_assemblable => eval { $it->is_assemblable } ? 1 : 0,
            };
        }
    };
    return \@modules;
}

sub _stock_map {
    my ($self, $c) = @_;
    my %avail;
    eval {
        my $schema   = $c->model('DBEncy');
        my $sitename = $self->_sitename($c);
        my $rs = $schema->resultset('Accounting::InventoryStockLevel')->search(
            { 'item.sitename' => $sitename },
            { join => ['item'] },
        );
        while (my $row = $rs->next) {
            my $on  = $row->quantity_on_hand  // 0;
            my $res = $row->quantity_reserved // 0;
            $avail{ $row->item_id } += ($on - $res);
        }
    };
    return \%avail;
}

sub _job_item_id {
    my ($self, $job) = @_;
    return undef unless $job;
    my $model = eval { $job->model };
    my $iid = $model ? eval { $model->item_id } : undef;
    return $iid if $iid;
    # Traveler-queued jobs set source_item_id to the inventory part
    $iid = eval { $job->source_item_id };
    return $iid if $iid;
    return undef;
}

# Only credit a completed job to an item when the model/job name agrees with the item
# SKU/code — stops FL01/FLS01 mis-links from painting the wrong traveler row blue.
sub _job_matches_item {
    my ($self, $job, $item_id, $item_sku, $item_name) = @_;
    my $jid = $self->_job_item_id($job);
    return 0 unless $jid && $item_id && $jid == $item_id;

    my $model = eval { $job->model };
    my $mname = $model ? (eval { $model->name } // '') : '';
    my $jname = eval { $job->item_name } // '';
    my $blob  = lc("$mname $jname");
    my $sku   = $item_sku // '';
    my $code  = '';
    if ($sku =~ /(?:INT-HDRY-|HW-)?([A-Z0-9]+)$/i) {
        $code = uc($1);
    }
    if ($item_name && $item_name =~ /\(([A-Z0-9]+)\)/) {
        $code = uc($1);
    }
    return 1 unless $code; # no code to check
    # Require code token in model or job name when present
    return 1 if $blob =~ /\b\Q$code\E\b/i;
    return 1 if $blob =~ /\Q$code\E/i;
    # Model linked by item_id only, name empty — allow but prefer stock for green
    return 1 if $mname eq '' && $jname eq '';
    return 0;
}

sub _printed_qty_map {
    my ($self, $c) = @_;
    my %printed;
    my %sku_by_id;
    eval {
        my $schema   = $c->model('DBEncy');
        my $sitename = $self->_sitename($c);
        my $items = $schema->resultset('Accounting::InventoryItem')->search(
            { sitename => $sitename },
            { columns => [qw(id sku name)] },
        );
        while (my $it = $items->next) {
            $sku_by_id{ $it->id } = { sku => $it->sku, name => $it->name };
        }
        my $rs = $schema->resultset('Printing3dJob')->search(
            { 'me.sitename' => $sitename, 'me.status' => 'completed' },
            { prefetch => 'model' },
        );
        while (my $job = $rs->next) {
            my $iid = $self->_job_item_id($job);
            next unless $iid;
            my $meta = $sku_by_id{$iid} || {};
            next unless $self->_job_matches_item($job, $iid, $meta->{sku}, $meta->{name});
            $printed{$iid} += ($job->quantity || 1);
        }
    };
    return \%printed;
}

# Qty still on the print farm queue (queued / assigned / printing).
sub _queue_qty_map {
    my ($self, $c) = @_;
    my %queued;
    eval {
        my $schema   = $c->model('DBEncy');
        my $sitename = $self->_sitename($c);
        my $rs = $schema->resultset('Printing3dJob')->search(
            {
                'me.sitename' => $sitename,
                'me.status'   => { -in => [qw(queued assigned printing)] },
            },
            { prefetch => 'model' },
        );
        while (my $job = $rs->next) {
            my $iid = $self->_job_item_id($job);
            next unless $iid;
            $queued{$iid} += ($job->quantity || 1);
        }
    };
    return \%queued;
}

sub _list_bom {
    my ($self, $c, $parent_id, $parent_sku) = @_;

    my $inv = eval { $c->controller('Inventory') };
    if ($inv && $inv->can('_list_bom_lines')) {
        my $res = eval {
            $inv->_list_bom_lines($c, {
                sitename       => $self->_sitename($c),
                parent_item_id => $parent_id,
                parent_sku     => $parent_sku,
            });
        };
        return $res if $res && $res->{ok};
    }

    my ($psku, $pname, @lines) = ($parent_sku, '', ());
    eval {
        my $schema = $c->model('DBEncy');
        my $parent = $parent_id
            ? $schema->resultset('Accounting::InventoryItem')->find($parent_id)
            : undef;
        $parent ||= $schema->resultset('Accounting::InventoryItem')->find({
            sitename => $self->_sitename($c),
            sku      => $parent_sku,
        }) if $parent_sku;
        return unless $parent;
        $psku  = $parent->sku;
        $pname = $parent->name;
        my $rs = $schema->resultset('Accounting::InventoryItemBOM')->search(
            { parent_item_id => $parent->id },
        );
        while (my $bom = $rs->next) {
            my $comp = eval {
                $schema->resultset('Accounting::InventoryItem')->find($bom->component_item_id)
            };
            push @lines, {
                component_item_id => $bom->component_item_id,
                sku               => $comp ? $comp->sku  : '',
                name              => $comp ? $comp->name : '',
                quantity          => $bom->quantity,
                item_origin       => $comp ? (eval { $comp->item_origin } // '') : '',
                available         => 0,
                on_hand           => 0,
            };
        }
    };
    return {
        ok          => 1,
        parent_id   => $parent_id,
        parent_sku  => $psku,
        parent_name => $pname,
        lines       => \@lines,
    };
}

sub _explode_to_leaves {
    my ($self, $c, $parent_id, $parent_sku, $mult, $seen_parents) = @_;
    $mult         = 1 unless defined $mult;
    $seen_parents ||= {};
    return () if $parent_id && $seen_parents->{$parent_id}++;

    my $res   = $self->_list_bom($c, $parent_id, $parent_sku);
    my $lines = $res->{lines} || [];
    return () unless @$lines;

    my @nested;
    my @flat;
    for my $ln (@$lines) {
        my $cid = $ln->{component_item_id} // next;
        my $child = $self->_list_bom($c, $cid, $ln->{sku});
        my $child_lines = $child->{lines} || [];
        if (@$child_lines) {
            push @nested, { line => $ln, child_id => $cid, child_sku => $ln->{sku} };
        } else {
            push @flat, $ln;
        }
    }

    my @leaves;
    if (@nested) {
        for my $n (@nested) {
            my $q = 0 + ($n->{line}{quantity} // 1);
            push @leaves, $self->_explode_to_leaves(
                $c, $n->{child_id}, $n->{child_sku}, $mult * $q, $seen_parents
            );
        }
        for my $ln (@flat) {
            my $sku = $ln->{sku} // '';
            push @leaves, $self->_leaf_from_line($ln, $mult);
        }
    } else {
        for my $ln (@flat) {
            push @leaves, $self->_leaf_from_line($ln, $mult);
        }
    }
    return @leaves;
}

sub _leaf_from_line {
    my ($self, $ln, $mult) = @_;
    my $qty = (0 + ($ln->{quantity} // 0)) * $mult;
    return {
        component_item_id => $ln->{component_item_id},
        sku               => $ln->{sku} // $ln->{component_sku} // '',
        name              => $ln->{name} // $ln->{component_name} // '',
        quantity          => $qty,
        item_origin       => $ln->{item_origin} // '',
        available         => $ln->{available},
        on_hand           => $ln->{on_hand},
    };
}

sub _merge_leaves {
    my ($self, @leaves) = @_;
    my %by;
    for my $L (@leaves) {
        my $key = $L->{component_item_id} || $L->{sku} || next;
        if ($by{$key}) {
            $by{$key}{quantity} += $L->{quantity};
        } else {
            $by{$key} = { %$L };
        }
    }
    return map { $by{$_} } sort {
        ($by{$a}{sku} // '') cmp ($by{$b}{sku} // '')
    } keys %by;
}

# Does the linked STL basename belong to this part code?
# Design files often omit inventory codes (Roller__1_.stl, gasket_150_*, FL03 for FL01 L1).
# Returns (ok, warn_message). ok=1 means safe to queue/print.
sub _stl_matches_part_code {
    my ($self, $code, $basename) = @_;
    $code     = uc($code     // '');
    $basename = $basename    // '';
    return (0, 'No STL linked') unless length $basename;
    return (1, '') unless length $code;

    # Exact / contains full code (SBR01__1_.stl, INT-HDRY-SBR01.stl)
    return (1, '') if $basename =~ /\Q$code\E/i;

    my ($letters, $digits) = $code =~ /^([A-Z]+?)(\d+)$/i;
    $letters = uc($letters // '');
    $digits  = $digits // '';

    # Gaskets: GSK150 ↔ gasket_150_straight.stl (digits + gasket token)
    if ($letters eq 'GSK' && $digits ne '') {
        return (1, '') if $basename =~ /gasket/i && $basename =~ /(?:^|_|-)$digits(?:_|\.|-|$)/;
        return (1, '') if $basename =~ /(?:^|_|-)$digits(?:_|\.|-|$)/ && $basename =~ /gasket|gsk/i;
    }

    # Known design-export aliases (Hydra rollers + HDRY L1 corner extract *03 → *01 SKU)
    my %alias = (
        SRC01 => [qr/Roller__1_/i, qr/^Roller(?!_Bar)/i, qr/SRC01/i],
        SRL01 => [qr/Roller_Bar_S2/i, qr/SRL01/i, qr/BSX_Bar|FSX_Bar/i],
        SRR01 => [qr/Roller_Bar_D3/i, qr/SRR01/i, qr/BDX_Bar|FDX_Bar/i],
        # L1 corners extracted as *03 geometry for *01 inventory codes
        FL01  => [qr/FL0?3/i, qr/FL01/i],
        FR01  => [qr/FR0?3/i, qr/FR01/i],
        BL01  => [qr/BL0?3/i, qr/BL01/i],
        BR01  => [qr/BR0?3/i, qr/BR01/i],
        BBL01 => [qr/BBL0?3/i, qr/BBL01/i],
        BBR01 => [qr/BBR0?3/i, qr/BBR01/i],
        FLS01 => [qr/FLS0?3/i, qr/FLS01/i],
        FRS01 => [qr/FRS0?3/i, qr/FRS01/i],
        BLS01 => [qr/BLS0?3/i, qr/BLS01/i],
        BRS01 => [qr/BRS0?3/i, qr/BRS01/i],
        # Spool brackets — exact codes only (SBR01 ≠ SBR03)
        SBR01 => [qr/SBR01/i],
        SBR02 => [qr/SBR02/i],
        SBR03 => [qr/SBR03/i, qr/Reinforcement_small/i],
        SBL01 => [qr/SBL01/i],
        SBL02 => [qr/SBL02/i],
    );
    if (my $pats = $alias{$code}) {
        for my $re (@$pats) {
            return (1, '') if $basename =~ $re;
        }
    }

    # L1 corner extract only: *01 inventory often ships as *03 STL. Never apply to SBR/SBL/SRC.
    my %l1_swap = map { $_ => 1 } qw(FL FR BL BR BBL BBR FLS FRS BLS BRS);
    if ($l1_swap{$letters} && $digits ne '' && $basename =~ /(?:^|[^A-Z])\Q$letters\E0*(\d+)/i) {
        my $file_n = 0 + $1;
        my $code_n = 0 + $digits;
        if (($code_n == 1 && $file_n == 3) || ($code_n == 3 && $file_n == 1) || abs($file_n - $code_n) <= 1) {
            return (1, '');
        }
    }

    # Hard mismatch: basename names a different known HDRY part code
    if ($basename =~ /\b((?:BBL|BBR|BLS|BRS|FLS|FRS|SBR|SBL|SRC|SRL|SRR|GSK|FFL|FFR|FL|FR|BL|BR)[A-Z]*\d+)\b/i
        || $basename =~ /\b((?:BBL|BBR|BLS|BRS|FLS|FRS|SBR|SBL|SRC|SRL|SRR|GSK|FFL|FFR|FL|FR|BL|BR)\d+)\b/i) {
        my $other = uc($1);
        if ($other ne $code) {
            return (0, "File $basename is labeled $other, not $code");
        }
    }
    # Same-letter different number (SBR01.stl on SBR03)
    if ($letters && $basename =~ /(?:^|[^A-Z])(\Q$letters\E\d+)/i) {
        my $other = uc($1);
        if ($other ne $code) {
            return (0, "File $basename is labeled $other, not $code");
        }
    }

    # Soft: unknown export name — allow queue but warn so staff download-check
    return (1, "Filename $basename does not include $code — download and verify before print");
}

sub _parts_from_leaves {
    my ($self, $c, @leaves) = @_;
    my $stock   = $self->_stock_map($c);
    my $printed = $self->_printed_qty_map($c);
    my $queued  = $self->_queue_qty_map($c);
    my $schema  = eval { $c->model('DBEncy') };

    # Fresh origin from inventory_items (BOM leaf can be stale in-process)
    my %origin_by_id;
    eval {
        my @ids = grep { $_ } map { $_->{component_item_id} } @leaves;
        if ($schema && @ids) {
            my $rs = $schema->resultset('Accounting::InventoryItem')->search(
                { id => { -in => \@ids } },
                { columns => [qw(id item_origin sku name)] },
            );
            while (my $it = $rs->next) {
                $origin_by_id{ $it->id } = {
                    item_origin => $it->item_origin // '',
                    sku         => $it->sku // '',
                    name        => $it->name // '',
                };
            }
        }
    };

    # Model file links for download + code/file integrity flag (mis-map detector)
    my %model_by_item;
    eval {
        my @ids = grep { $_ } map { $_->{component_item_id} } @leaves;
        if ($schema && @ids) {
            my $sitename = $self->_sitename($c);
            my $mrs = $schema->resultset('Printing3dModel')->search(
                {
                    item_id  => { -in => \@ids },
                    sitename => $sitename,
                    -or      => [ { is_active => 1 }, { is_active => undef } ],
                },
                { order_by => { -asc => 'id' } },
            );
            while (my $m = $mrs->next) {
                my $iid = $m->item_id or next;
                next if $model_by_item{$iid};  # first/lowest id wins
                my $path = $m->nfs_path // '';
                my $base = $path;
                $base =~ s{.*/}{};
                my $code = '';
                if (my $sku = $origin_by_id{$iid}{sku} || '') {
                    ($code) = $sku =~ /(?:INT-HDRY-)?([A-Z]+\d+)/i;
                }
                if (!$code && ($m->name // '') =~ /\(([A-Za-z0-9]+)\)\s*$/) {
                    $code = $1;
                }
                my ($file_ok, $file_warn) = $self->_stl_matches_part_code($code, $base);
                # Missing path is always hard fail
                if (!$path) {
                    $file_ok = 0;
                    $file_warn = 'No STL linked';
                }
                $model_by_item{$iid} = {
                    model_id       => $m->id,
                    model_name     => $m->name // '',
                    nfs_path       => $path,
                    file_basename  => $base,
                    file_ok        => $file_ok ? 1 : 0,
                    file_warn      => $file_warn,
                    part_code      => $code || '',
                };
            }
        }
    };

    my @parts;
    for my $ln (@leaves) {
        my $cid = $ln->{component_item_id};
        my $qty = 0 + ($ln->{quantity} // 0);

        # Prefer live stock map; BOM "available: 0" is often "no stock row yet", not truth.
        my $from_stock = defined $cid ? (0 + ($stock->{$cid} // 0)) : 0;
        my $from_bom   = defined $ln->{on_hand} ? (0 + $ln->{on_hand})
                       : defined $ln->{available} ? (0 + $ln->{available})
                       : undef;
        my $on_hand = $from_stock;
        if (defined $from_bom && $from_bom > $on_hand) {
            $on_hand = $from_bom;
        }

        my $from_queue = defined $cid ? (0 + ($printed->{$cid} // 0)) : 0;
        my $in_queue   = defined $cid ? (0 + ($queued->{$cid} // 0)) : 0;
        # Pick box = inventory on hand (physical box). Printed-but-not-received is blue, not green.
        my $pick_box   = $on_hand;
        my $effective  = $from_queue > $on_hand ? $from_queue : $on_hand;
        my $short      = $qty - $effective;
        $short = 0 if $short < 0;

        my $meta   = ($cid && $origin_by_id{$cid}) ? $origin_by_id{$cid} : {};
        my $origin = $meta->{item_origin} // $ln->{item_origin} // '';
        my $sku    = $meta->{sku}  || $ln->{sku}  || '';
        my $name   = $meta->{name} || $ln->{name} || '';

        my $is_print = ($origin eq '3d_printed' || $origin =~ /print/i) ? 1 : 0;
        my $model    = ($cid && $model_by_item{$cid}) ? $model_by_item{$cid} : {};

        # Browser colors:
        # green = in pick box, blue = printed ready to pick,
        # red = already in print queue, purple = need print but NOT queued yet
        my ($row_state, $status_display, $status);
                # Priority order for traveler display (user requested):
                # 1. need_buy (amber) — items to be ordered
                # 2. need_print (purple) — items to add to queue / need to print
                # 3. in_queue (red) — picked items / already in queue / need to be picked
                # 4. printed_ready (blue) — printed items that needs picking
                # Priority order for traveler display (user requested):
                # 1. need_buy (amber) — items to be ordered
                # 2. need_print (purple) — items to add to queue / need to print
                # 3. in_queue (red) — picked items / already in queue / need to be picked
                # 4. printed_ready (blue) — printed items that needs picking
                #    Now also includes items that have arrived into stock (on_hand > 0)
                #    but have not yet been picked/allocated into the pick box for this build.
                # 5. in_box (green) — items in the pick box / picked items — LAST group
                #
                # Stock truth wins: if recorded on_hand already covers the need, the part is
                # IN THE BOX (green) even if more are still printing.
                if (!$is_print && $short > 0 && $on_hand < $qty) {
                    $row_state       = 'need_buy';         # amber — items to be ordered
                    $status          = 'pending';
                    $status_display  = 'Need purchase';
                } elsif ($on_hand >= $qty && $qty > 0) {
                    # Already satisfied from stock — it is in the pick box.
                    $row_state       = 'in_box';          # green — items in the pick box / picked items
                    $status          = 'in_stock';
                    $status_display  = 'In pick box';
                    if ($in_queue > 0) {
                        # Some extra qty still printing — note it, but do NOT override green.
                        $status_display .= " (+$in_queue printing)";
                    }
                } elsif ($is_print && $short > 0 && $in_queue <= 0 && $from_queue <= $on_hand) {
                    $row_state       = 'need_print';       # purple — items to add to queue
                    $status          = 'pending';
                    # Label must never claim "not queued" when something IS queued/printing.
                    $status_display  = ($in_queue > 0 || $from_queue > $on_hand)
                        ? 'Need print (queued: ' . ($in_queue || 0) . ')'
                        : 'Need print (not queued)';
                } elsif ($is_print && $short > 0 && $in_queue > 0) {
                    $row_state       = 'in_queue';         # red — picked items / already in queue
                    $status          = 'pending';
                    $status_display  = "In print queue ($in_queue)";
                } elsif ($is_print && $short > 0 && ($from_queue > $on_hand || $on_hand > 0)) {
                    # Printed arrived: includes completed prints not yet in stock,
                    # AND items that are in stock (on_hand > 0) but not yet picked for this build.
                    $row_state       = 'printed_ready';   # blue — printed / arrived items
                    $status          = 'printed';
                    if ($on_hand > 0) {
                        $status_display  = 'Printed — arrived (in stock, not picked)';
                    } else {
                        $status_display  = 'Printed — needs picking';
                    }
                } elsif ($is_print && $qty > 0 && $on_hand == 0 && $in_queue == 0 && $from_queue == 0) {
                    # Zero-stock needed printed item must never appear as satisfied "OK" or in in_box.
                    # It belongs in need_print until a job is queued or stock appears.
                    $row_state       = 'need_print';
                    $status          = 'pending';
                    $status_display  = 'Need print (no stock / no credit)';
                } elsif ($on_hand > 0) {
                    $row_state       = 'in_box';
                    $status          = 'in_stock';
                    $status_display  = 'In pick box / partial stock';
                } else {
                    $row_state       = 'in_box';
                    $status          = 'in_stock';
                    $status_display  = 'OK';
                }

        if ($is_print && $model->{file_warn}) {
            $status_display = ($status_display ? "$status_display — " : '') . $model->{file_warn};
        }

        push @parts, {
            id               => $cid,
            sku              => $sku,
            name             => $name,
            qty_needed       => $qty,
            in_stock         => $on_hand,
            in_pick_box      => $pick_box,
            qty_printed_jobs => $from_queue,
            qty_in_queue     => $in_queue,
            effective_stock  => $effective,
            qty_short        => $short,
            qty_printed      => $from_queue,
            item_origin      => $origin,
            need_print       => ($is_print && $short > 0 && $in_queue <= 0) ? 1 : 0,
            need_pick_box    => ($from_queue > $on_hand && $on_hand < $qty) ? 1 : 0,
            is_print         => $is_print ? 1 : 0,
            can_queue        => ($is_print && $short > 0 && $model->{model_id} && $model->{file_ok}) ? 1 : 0,
            queue_qty        => $short > 0 ? $short : 1,
            row_state        => $row_state,
            status           => $status,
            status_display   => $status_display,
            model_id         => $model->{model_id},
            model_name       => $model->{model_name},
            file_basename    => $model->{file_basename},
            file_ok          => defined $model->{file_ok} ? $model->{file_ok} : 1,
            file_warn        => $model->{file_warn} // '',
            has_download     => ($model->{model_id} && $model->{nfs_path}) ? 1 : 0,
        };
    }
    return \@parts;
}

# Receive completed-print lag into inventory so "In Stock" / pick box matches shop floor.
# Accepts optional location_name: 'Print Farm Pick Box', 'Print Farm Stock', 'On Printer'
# Defaults to 'Print Farm Pick Box' for backward compat.
# Returns { ok, received, on_hand, error }
#
# Error audit (2026-09-03, item=84, site 3d): location_id NULL on INSERT to inventory_stock_levels.
# Fixed by guaranteeing InventoryLocation (active or created "Print Farm Pick Box" per sitename)
# before any stock create. See changelog 2026-09-04-traveler-location-null.
# Verified perl -c + code review 2026-09-05. CODER_READY (no re-plan needed for similar location issues).
sub put_part_in_pick_box {
    my ($self, $c, $item_id, $qty_hint, $location_name) = @_;
    $item_id = 0 + ($item_id // 0);
    return { ok => 0, error => 'item_id required' } unless $item_id;
    $location_name ||= 'Print Farm Pick Box';

    my $schema = eval { $c->model('DBEncy') };
    return { ok => 0, error => 'no schema' } unless $schema;

    my $stock_map = $self->_stock_map($c);
    my $printed   = $self->_printed_qty_map($c);
    my $on_hand   = 0 + ($stock_map->{$item_id} // 0);
    my $from_q    = 0 + ($printed->{$item_id} // 0);
    my $need      = defined $qty_hint && $qty_hint > 0
        ? (0 + $qty_hint)
        : ($from_q > $on_hand ? $from_q - $on_hand : 0);

    # At least 1 if caller pressed the button with no lag math
    $need = 1 if $need <= 0 && defined $qty_hint && $qty_hint == 0 && $from_q == 0;
    if ($need <= 0 && $from_q <= $on_hand) {
        # Still allow explicit receive of 1 for manual pick-box tick
        $need = 1 if !defined $qty_hint;
    }
    return { ok => 1, received => 0, on_hand => $on_hand, message => 'already in stock' }
        if $need <= 0 && $from_q <= $on_hand && $on_hand > 0;

    $need = 1 if $need <= 0;

    my $err;
    my $new_hand = $on_hand;
    eval {
        $schema->txn_do(sub {
            my $now = eval {
                require Comserv::Util::AppTime;
                Comserv::Util::AppTime->now_utc;
            } || do {
                my @t = gmtime();
                sprintf('%04d-%02d-%02d %02d:%02d:%02d', $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]);
            };

            my $sitename = $self->_sitename($c);
            # Look up or create the requested location
            my $loc = $schema->resultset('Accounting::InventoryLocation')->search(
                { sitename => $sitename, name => $location_name, status => 'active' },
                { order_by => 'id', rows => 1 },
            )->first;
            unless ($loc) {
                $loc = $schema->resultset('Accounting::InventoryLocation')->search(
                    { sitename => $sitename, name => $location_name },
                    { order_by => 'id', rows => 1 },
                )->first;
            }
            unless ($loc) {
                $loc = $schema->resultset('Accounting::InventoryLocation')->create({
                    sitename      => $sitename,
                    name          => $location_name,
                    location_type => 'warehouse',
                    status        => 'active',
                    notes         => 'Auto-created for traveler receives',
                    created_by    => $c->session->{username} || 'system',
                    created_at    => $now,
                    updated_at    => $now,
                });
            }
            my $loc_id = $loc->id;

            my $stock = $schema->resultset('Accounting::InventoryStockLevel')->search(
                { item_id => $item_id, location_id => $loc_id }
            )->first;
            $stock ||= $schema->resultset('Accounting::InventoryStockLevel')->search(
                { item_id => $item_id }
            )->first;
            unless ($stock) {
                $stock = $schema->resultset('Accounting::InventoryStockLevel')->create({
                    item_id            => $item_id,
                    location_id        => $loc_id,
                    quantity_on_hand   => 0,
                    quantity_reserved  => 0,
                    quantity_on_order  => 0,
                    updated_at         => $now,
                });
            }

            my $hand = 0 + ($stock->quantity_on_hand // 0);
            $hand += $need;
            $stock->update({ quantity_on_hand => $hand, updated_at => $now });
            $new_hand = $hand;

            eval {
                $schema->resultset('Accounting::InventoryTransaction')->create({
                    item_id          => $item_id,
                    location_id      => eval { $stock->location_id } || $loc_id,
                    transaction_type => 'receive',
                    quantity         => $need,
                    reference_number => 'TRAVELER-PICK-' . $item_id,
                    sitename         => $sitename,
                    notes            => 'Traveler: put printed part in pick box',
                    performed_by     => $c->session->{username} || 'system',
                    transaction_date => $now,
                    created_at       => $now,
                });
            };
        });
    };
    $err = $@ if $@;
    if ($err) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'put_part_in_pick_box', "item=$item_id failed: $err");
        return { ok => 0, error => "$err" };
    }
    return { ok => 1, received => $need, on_hand => $new_hand };
}

# Queue shortfall of a printed inventory part onto /3d/queue.
# quantity defaults to remaining shortfall (need - stock - already queued - completed covering).
# Returns { ok, job_id, quantity, model_id, error }
sub queue_part_print {
    my ($self, $c, $item_id, $qty) = @_;
    $item_id = 0 + ($item_id // 0);
    return { ok => 0, error => 'item_id required' } unless $item_id;

    my $schema = eval { $c->model('DBEncy') };
    return { ok => 0, error => 'no schema' } unless $schema;

    my $sitename = $self->_sitename($c);
    my $item = eval { $schema->resultset('Accounting::InventoryItem')->find($item_id) };
    return { ok => 0, error => 'item not found' } unless $item;

    my $stock   = $self->_stock_map($c);
    my $printed = $self->_printed_qty_map($c);
    my $queued  = $self->_queue_qty_map($c);
    my $on_hand = 0 + ($stock->{$item_id} // 0);
    my $from_q  = 0 + ($printed->{$item_id} // 0);
    my $in_q    = 0 + ($queued->{$item_id} // 0);
    my $have    = $from_q > $on_hand ? $from_q : $on_hand;

    # $qty (if passed) is the traveler's qty_needed for this part in the build.
    # Queue ONLY the true remainder so a second click never double-queues:
    #   remainder = qty_needed - on_hand - already_queued
    # If the caller passed an explicit qty we treat it as qty_needed; otherwise fall
    # back to (on_hand already satisfied -> at least 1) for direct/standalone calls.
    my $qty_needed = (defined $qty && $qty > 0) ? (0 + $qty) : 0;
    my $need;
    if ($qty_needed > 0) {
        $need = $qty_needed - $on_hand - $in_q;
    } else {
        # No qty context (e.g. standalone API call): queue 1 unless already covered.
        $need = $have >= 1 ? 0 : 1;
    }
    $need = 0 + int($need);
    if ($need <= 0) {
        # Nothing left to queue — already satisfied by stock + what's in the queue.
        return {
            ok         => 1,
            queued     => 0,
            item_id    => $item_id,
            sku        => $item ? $item->sku : undef,
            message    => 'No remainder to queue (stock + existing queue already covers need)',
        };
    }

    my $model = eval {
        $schema->resultset('Printing3dModel')->search(
            {
                item_id  => $item_id,
                sitename => $sitename,
                -or      => [ { is_active => 1 }, { is_active => undef } ],
            },
            { order_by => { -asc => 'id' }, rows => 1 },
        )->first;
    };
    $model ||= eval {
        $schema->resultset('Printing3dModel')->search(
            { item_id => $item_id },
            { order_by => { -asc => 'id' }, rows => 1 },
        )->first;
    };

    my $now = eval {
        require Comserv::Util::AppTime;
        Comserv::Util::AppTime->now_utc;
    } || do {
        my @t = gmtime();
        sprintf('%04d-%02d-%02d %02d:%02d:%02d', $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]);
    };

    my $job;
    my $err;
    eval {
        my %row = (
            sitename           => $sitename,
            model_id           => $model ? $model->id : undef,
            source_type        => 'manufacturing',
            source_item_id     => $item_id,
            item_name          => $item->name || $item->sku || "item $item_id",
            user_id            => $c->session->{user_id} || 0,
            username           => $c->session->{username} || 'system',
            status             => 'queued',
            quantity           => $need,
            notes              => sprintf('Traveler queue: %s x%d (shortfall print)', $item->sku || $item_id, $need),
            inventory_reserved => 0,
            created_at         => $now,
        );
        $job = $schema->resultset('Printing3dJob')->create(\%row);
    };
    $err = $@ if $@;
    if ($err || !$job) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'queue_part_print', "item=$item_id failed: $err");
        return { ok => 0, error => $err || 'create failed' };
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'queue_part_print',
        "queued job=" . $job->id . " item=$item_id qty=$need model=" . ($model ? $model->id : 'none'));

    return {
        ok       => 1,
        job_id   => $job->id,
        quantity => $need,
        model_id => $model ? $model->id : undef,
        item_id  => $item_id,
        sku      => $item->sku,
    };
}

# -------------------------------------------------------------------------
# Clean-labour timer stop: duration → inventory unit_cost + user point credit
# No new tables — AppTime for duration, PointSystem for pay, item unit_cost.
# JSON args: item_id, started_at (UTC), ended_at? (UTC), duration_seconds?,
#            category (clean|pick|pack|qc|other), notes?
# -------------------------------------------------------------------------
sub record_clean_labour {
    my ($self, $c, $args) = @_;
    $args = {} unless ref($args) eq 'HASH';

    my $item_id = 0 + ($args->{item_id} // $args->{part_id} // 0);
    return { ok => 0, error => 'item_id required' } unless $item_id;

    require Comserv::Util::AppTime;
    my $now = Comserv::Util::AppTime->now_utc;
    my $started = $args->{started_at} // $args->{start_at} // '';
    my $ended   = $args->{ended_at}   // $args->{end_at}   // $now;
    $started =~ s/T/ / if $started;
    $ended   =~ s/T/ / if $ended;
    $started =~ s/Z$// if $started;
    $ended   =~ s/Z$// if $ended;

    my $secs;
    if ($started && length $started >= 16) {
        my $parts = Comserv::Util::AppTime->duration_parts($started, $ended);
        if ($parts && !$parts->{negative}) {
            $secs = 0 + ($parts->{total_seconds} // 0);
        }
    }
    if (!defined $secs || $secs <= 0) {
        $secs = 0 + ($args->{duration_seconds} // $args->{seconds} // 0);
    }
    # Floor 5s so a fat-finger stop still records; cap 8h for one clean session
    return { ok => 0, error => 'timer too short (need at least 5 seconds)' }
        if $secs < 5;
    $secs = 8 * 3600 if $secs > 8 * 3600;

    my $mins  = int(($secs + 30) / 60);  # nearest minute for cost (min 1)
    $mins = 1 if $mins < 1;
    my $hours = sprintf('%.4f', $secs / 3600);

    my $category = lc($args->{category} // 'clean');
    $category = 'clean' unless $category =~ /^(clean|pick|pack|qc|other)$/;

    my $schema = eval { $c->model('DBEncy') };
    return { ok => 0, error => 'no schema' } unless $schema;

    my $item = eval { $schema->resultset('Accounting::InventoryItem')->find($item_id) };
    return { ok => 0, error => 'item not found' } unless $item;

    my $username = $c->session->{username}
        || $args->{username}
        || 'system';
    my $user_id = $c->session->{user_id};
    if (!$user_id && $username && $username ne 'system') {
        my $u = eval { $schema->resultset('User')->search({ username => $username })->first };
        $user_id = $u ? $u->id : undef;
    }

    my $sitename = $self->_sitename($c);
    my $rate = 60;  # pts/hr = CAD/hr default (PointSystem::DEFAULT_POINT_RATE)
    eval {
        require Comserv::Util::PointSystem;
        my $ps = Comserv::Util::PointSystem->new(c => $c);
        $rate = 0 + ($ps->resolve_rate(
            rule_type => 'hourly_rate',
            sitename  => $sitename,
        ) // 60);
    };
    $rate = 60 if !$rate || $rate <= 0;

    my $labour_cost = sprintf('%.4f', ($secs / 3600) * $rate);
    my $points      = sprintf('%.4f', ($secs / 3600) * $rate);
    return { ok => 0, error => 'zero labour cost' } if $labour_cost + 0 <= 0;

    my $old_cost = 0 + ($item->unit_cost // 0);
    my $new_cost = sprintf('%.4f', $old_cost + $labour_cost);
    my $human = Comserv::Util::AppTime->duration_human($started, $ended)
        if $started && length $started >= 16;
    $human ||= sprintf('%dh %dm', int($secs / 3600), int(($secs % 3600) / 60));

    my $sku  = $item->sku || $item_id;
    my $note_line = sprintf(
        '[%s] %s labour %s (%.0fs) by %s — +$%s cost @ %s pts/hr',
        $now, $category, $human, $secs, $username, $labour_cost, $rate
    );
    my $notes = $item->notes // '';
    $notes = length($notes) ? ($notes . "\n" . $note_line) : $note_line;
    # Keep notes from growing without bound
    if (length($notes) > 8000) {
        $notes = substr($notes, -7500);
        $notes = "…\n" . $notes;
    }

    my $err;
    my $ledger_id;
    eval {
        $schema->txn_do(sub {
            $item->update({
                unit_cost  => $new_cost,
                notes      => $notes,
                updated_at => $now,
                updated_by => $username,
            });

            # Audit movement (qty 0) so cost history is visible next to stock moves
            eval {
                my $loc = $schema->resultset('Accounting::InventoryLocation')->search(
                    { sitename => $sitename },
                    { order_by => 'id', rows => 1 },
                )->first;
                $schema->resultset('Accounting::InventoryTransaction')->create({
                    item_id          => $item_id,
                    location_id      => $loc ? $loc->id : undef,
                    transaction_type => 'adjust',
                    quantity         => 0,
                    unit_cost        => $labour_cost + 0,
                    reference_number => sprintf('LABOUR-%s-%s', uc($category), $item_id),
                    sitename         => $sitename,
                    notes            => $note_line,
                    performed_by     => $username,
                    transaction_date => $now,
                    created_at       => $now,
                });
            };

            if ($user_id) {
                require Comserv::Util::PointSystem;
                my $ps = Comserv::Util::PointSystem->new(c => $c);
                my $led = $ps->credit(
                    user_id          => $user_id,
                    amount           => $points + 0,
                    transaction_type => 'time_log_earn',
                    description      => sprintf(
                        'Traveler %s labour on %s — %s @ %.2f pts/hr',
                        $category, $sku, $human, $rate
                    ),
                    reference_type   => 'inventory_item',
                    reference_id     => $item_id,
                );
                $ledger_id = $led ? $led->id : undef;
            }
        });
    };
    $err = $@ if $@;
    if ($err) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'record_clean_labour', "item=$item_id failed: $err");
        return { ok => 0, error => "$err" };
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'record_clean_labour',
        "item=$item_id cat=$category secs=$secs cost=$labour_cost pts=$points user=$username ledger=" . ($ledger_id // 'none'));

    return {
        ok            => 1,
        item_id       => $item_id,
        sku           => $sku,
        category      => $category,
        duration_secs => $secs,
        duration_mins => $mins,
        duration_human=> $human,
        hourly_rate   => $rate + 0,
        labour_cost   => $labour_cost + 0,
        unit_cost_old => $old_cost,
        unit_cost_new => $new_cost + 0,
        points_credited => $points + 0,
        username      => $username,
        ledger_id     => $ledger_id,
        credited      => $user_id ? 1 : 0,
        message       => $user_id
            ? sprintf('Logged %s; +$%s on item; +%s pts to %s', $human, $labour_cost, $points, $username)
            : sprintf('Logged %s; +$%s on item (no user session for points)', $human, $labour_cost),
    };
}

# -------------------------------------------------------------------------
# Open orders from inventory_customer_orders (real work)
# -------------------------------------------------------------------------

sub _order_rs {
    my ($self, $c, $extra) = @_;
    my $schema   = $c->model('DBEncy');
    my $sitename = $self->_sitename($c);
    my $where = {
        %{ $extra || {} },
    };
    # Qualify sitename — join to inventory_items also has sitename (ambiguous otherwise).
    $where->{'me.sitename'} = $sitename unless exists $where->{'me.sitename'}
        || exists $where->{sitename};
    # If caller passed bare sitename, rewrite to me.sitename
    if (exists $where->{sitename} && !exists $where->{'me.sitename'}) {
        $where->{'me.sitename'} = delete $where->{sitename};
    }
    if (exists $where->{customer_name} && !exists $where->{'me.customer_name'}) {
        $where->{'me.customer_name'} = delete $where->{customer_name};
    }
    return $schema->resultset('Accounting::InventoryCustomerOrder')->search(
        $where,
        {
            order_by => [
                { -asc  => 'me.customer_name' },
                { -desc => 'me.id' },
            ],
            prefetch => { lines => 'item' },
        },
    );
}

sub _is_open_status {
    my ($self, $status) = @_;
    # Manufacturing list: hide only cancelled/void. Keep pending, open, paid,
    # processing, etc. so every live customer order (e.g. Nome) still appears.
    my $st = lc($status // 'pending');
    $st =~ s/^\s+|\s+$//g;
    return 0 if $st =~ /^(cancel|canceled|cancelled|void)$/;
    return 1;
}

sub _order_line_summary {
    my ($self, $order) = @_;
    my @bits;
    my $has_hdry = 0;
    eval {
        for my $line ($order->lines->all) {
            my $item = eval { $line->item };
            my $desc = ($item && $item->name)
                || $line->description
                || ($item && $item->sku)
                || 'line';
            my $sku = $item ? ($item->sku || '') : '';
            my $qty = $line->quantity || 1;
            push @bits, ($qty > 1 ? "${qty}x " : '') . $desc . ($sku ? " ($sku)" : '');
            $has_hdry = 1 if $sku eq HDRY_SYSTEM_SKU
                || ($item && $item->id && $item->id == HDRY_SYSTEM_ID)
                || ($desc =~ /HDRY/i);
        }
    };
    my $items = @bits ? join('; ', @bits) : ($order->notes || 'Order (no lines)');
    return ($items, $has_hdry);
}

sub _order_row {
    my ($self, $c, $order) = @_;
    my $oid = $order->id;
    my ($items, $has_hdry) = $self->_order_line_summary($order);
    my $cust = $order->customer_name || 'Customer';
    return {
        customer     => $cust,
        order_id     => $oid,
        order_date   => $self->_fmt_date($order->created_at),
        items        => $items,
        status       => $order->status || 'pending',
        scope_note   => $has_hdry
            ? 'Includes INT-HDRY-001 (wheel kit is nested under base BOM)'
            : 'Customer order',
        source       => 'customer',
        has_hdry     => $has_hdry ? 1 : 0,
        link         => $c->uri_for('/Accounting/manufacturing/view', $oid),
        print_link   => $c->uri_for('/Accounting/manufacturing/print', $oid),
        customer_link => $c->uri_for('/Accounting/manufacturing/customer', uri_escape($cust)),
    };
}

# First page: customers that have open orders (incl. In-House)
sub get_customers_with_open_orders {
    my ($self, $c) = @_;

    my %by_customer;
    my $err;
    eval {
        my $rs = $self->_order_rs($c);
        my $count = 0;
        while (my $o = $rs->next) {
            next unless $self->_is_open_status($o->status);
            $count++;
            my $row = $self->_order_row($c, $o);
            my $name = $row->{customer};
            $by_customer{$name} ||= {
                customer       => $name,
                order_count    => 0,
                open_orders    => [],
                items_preview  => [],
                customer_link  => $row->{customer_link},
                latest_date    => $row->{order_date},
            };
            $by_customer{$name}{order_count}++;
            push @{ $by_customer{$name}{open_orders} }, $row;
            push @{ $by_customer{$name}{items_preview} }, $row->{items}
                if @{ $by_customer{$name}{items_preview} } < 3;
            $by_customer{$name}{latest_date} = $row->{order_date}
                if ($row->{order_date} || '') gt ($by_customer{$name}{latest_date} || '');
        }
        # Also include other-site open orders not already listed (CSC vs 3d).
        my %seen_oid = map {
            my $list = $by_customer{$_}{open_orders} || [];
            map { $_->{order_id} => 1 } @$list;
        } keys %by_customer;
        my $all = $c->model('DBEncy')->resultset('Accounting::InventoryCustomerOrder')->search(
            {},
            {
                order_by => [ { -asc => 'me.customer_name' }, { -desc => 'me.id' } ],
                prefetch => { lines => 'item' },
                rows     => 200,
            },
        );
        while (my $o = $all->next) {
            next unless $self->_is_open_status($o->status);
            next if $seen_oid{ $o->id };
            my $sn = $o->sitename // '';
            next if $sn eq $self->_sitename($c); # already considered above
            my $row = $self->_order_row($c, $o);
            $row->{scope_note} = ($row->{scope_note} || '')
                . ' [sitename=' . ($sn || '?') . ']';
            my $name = $row->{customer};
            $by_customer{$name} ||= {
                customer       => $name,
                order_count    => 0,
                open_orders    => [],
                items_preview  => [],
                customer_link  => $row->{customer_link},
                latest_date    => $row->{order_date},
            };
            $by_customer{$name}{order_count}++;
            push @{ $by_customer{$name}{open_orders} }, $row;
            push @{ $by_customer{$name}{items_preview} }, $row->{items}
                if @{ $by_customer{$name}{items_preview} } < 3;
            $seen_oid{ $o->id } = 1;
        }
        $count = scalar keys %seen_oid;
    };
    $err = $@ if $@;
    if ($err) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'get_customers_with_open_orders', "customer order load failed: $err");
    }

    # Ensure In-House appears when there is an INT-HDRY-001 build to pick/print,
    # even if no inventory_customer_orders row exists yet.
    # Only add synthetic if there are *no* In-House records at all (open or cancelled).
    my $has_inhouse = $c->model('DBEncy')->resultset('Accounting::InventoryCustomerOrder')->search({
        sitename => $self->_sitename($c),
        customer_name => { -ilike => 'in-house' },
    })->count > 0;
    unless ($has_inhouse) {
        my $hdry = eval {
            $c->model('DBEncy')->resultset('Accounting::InventoryItem')->find({
                sitename => $self->_sitename($c),
                sku      => HDRY_SYSTEM_SKU,
            });
        };
        if ($hdry || 1) {
            my $hid = $hdry ? $hdry->id : HDRY_SYSTEM_ID;
            my $hname = $hdry ? $hdry->name : 'HDRY System V3';
            my $synthetic = {
                customer      => 'In-House',
                order_id      => 'item-' . $hid,
                order_date    => $self->_today,
                items         => "$hname (" . HDRY_SYSTEM_SKU . ')',
                status        => 'open',
                scope_note    => 'In-house system build — traveler explodes full BOM (wheels nested)',
                source        => 'in_house_item',
                has_hdry      => 1,
                link          => $c->uri_for('/Accounting/manufacturing/view/item', $hid),
                print_link    => $c->uri_for('/Accounting/manufacturing/print/item', $hid),
                customer_link => $c->uri_for('/Accounting/manufacturing/customer', uri_escape('In-House')),
            };
            $by_customer{'In-House'} = {
                customer      => 'In-House',
                order_count   => 1,
                open_orders   => [$synthetic],
                items_preview => [$synthetic->{items}],
                customer_link => $synthetic->{customer_link},
                latest_date   => $synthetic->{order_date},
            };
        }

        # Also add synthetic In-House entries for base and addon sub-units
        # so separate orders for base unit and top/addon appear in the list.
        foreach my $sub ( 
            { id => HDRY_BASE_ID, sku => HDRY_BASE_SKU, name => 'HDRY Base unit (bottom, top, wheels)' },
            { id => HDRY_ADDON_ID, sku => HDRY_ADDON_SKU, name => 'HDRY Add-on module (stacks, no bottom/top)' }
        ) {
            my $sub_item = eval {
                $c->model('DBEncy')->resultset('Accounting::InventoryItem')->find({
                    sitename => $self->_sitename($c),
                    sku      => $sub->{sku},
                });
            };
            my $sid = $sub_item ? $sub_item->id : $sub->{id};
            my $sname = $sub_item ? $sub_item->name : $sub->{name};
            my $sub_synthetic = {
                customer      => 'In-House',
                order_id      => 'item-' . $sid,
                order_date    => $self->_today,
                items         => "$sname (" . $sub->{sku} . ')',
                status        => 'open',
                scope_note    => 'In-house ' . ($sub->{id} == HDRY_BASE_ID ? 'base' : 'addon') . ' build',
                source        => 'in_house_item',
                link          => $c->uri_for('/Accounting/manufacturing/view/item', $sid),
                print_link    => $c->uri_for('/Accounting/manufacturing/print/item', $sid),
                customer_link => $c->uri_for('/Accounting/manufacturing/customer', uri_escape('In-House')),
            };
            # Add as additional open order under In-House (don't overwrite the main)
            push @{ $by_customer{'In-House'}{open_orders} || [] }, $sub_synthetic;
            push @{ $by_customer{'In-House'}{items_preview} || [] }, $sub_synthetic->{items};
            $by_customer{'In-House'}{order_count} = ($by_customer{'In-House'}{order_count} || 0) + 1;
        }
    }

    # Always add synthetic In-House entries for base and addon sub-assemblies
    # if there is no real open customer order for that specific item.
    # This makes in-house builds for base and top appear as separate orders
    # under the "In-House" customer, just like a regular customer order.
    foreach my $sub (
        { id => HDRY_BASE_ID,  sku => HDRY_BASE_SKU,  name => 'HDRY Base unit (bottom, top, wheels)' },
        { id => HDRY_ADDON_ID, sku => HDRY_ADDON_SKU, name => 'HDRY Add-on module (stacks, no bottom/top)' }
    ) {
        my $has_real_open_for_item = $c->model('DBEncy')->resultset('Accounting::InventoryCustomerOrder')->search({
            sitename => $self->_sitename($c),
            customer_name => { -ilike => 'in-house' },
            status => { -in => [qw(pending open processing in_progress confirmed accepted picking manufacturing partial)] },
        }, { join => 'lines' })->search({
            'lines.item_id' => $sub->{id},
        })->count > 0;

        unless ($has_real_open_for_item) {
            my $sub_item = eval {
                $c->model('DBEncy')->resultset('Accounting::InventoryItem')->find({
                    sitename => $self->_sitename($c),
                    sku      => $sub->{sku},
                });
            };
            my $sid = $sub_item ? $sub_item->id : $sub->{id};
            my $sname = $sub_item ? $sub_item->name : $sub->{name};
            my $sub_synthetic = {
                customer      => 'In-House',
                order_id      => 'item-' . $sid,
                order_date    => $self->_today,
                items         => "$sname (" . $sub->{sku} . ')',
                status        => 'open',
                scope_note    => 'In-house ' . ($sub->{id} == HDRY_BASE_ID ? 'base unit' : 'addon/top') . ' build',
                source        => 'in_house_item',
                link          => $c->uri_for('/Accounting/manufacturing/view/item', $sid),
                print_link    => $c->uri_for('/Accounting/manufacturing/print/item', $sid),
                customer_link => $c->uri_for('/Accounting/manufacturing/customer', uri_escape('In-House')),
            };
            push @{ $by_customer{'In-House'}{open_orders} || [] }, $sub_synthetic;
            push @{ $by_customer{'In-House'}{items_preview} || [] }, $sub_synthetic->{items};
            $by_customer{'In-House'}{order_count} = ($by_customer{'In-House'}{order_count} || 0) + 1;
            $by_customer{'In-House'}{customer} ||= 'In-House';
            $by_customer{'In-House'}{customer_link} ||= $c->uri_for('/Accounting/manufacturing/customer', uri_escape('In-House'));
            $by_customer{'In-House'}{latest_date} ||= $sub_synthetic->{order_date};
        }
    }

    my @customers = map { $by_customer{$_} } sort {
        (lc($a) eq 'in-house') ? -1
      : (lc($b) eq 'in-house') ? 1
      : lc($a) cmp lc($b)
    } keys %by_customer;

    return {
        customers => \@customers,
        error     => $err,
        # Flat order list for templates that still want one table
        open_orders => [ map { @{ $_->{open_orders} || [] } } @customers ],
    };
}

# Second page: orders for one customer
sub get_orders_for_customer {
    my ($self, $c, $customer_name) = @_;
    $customer_name = uri_unescape($customer_name // '');
    $customer_name =~ s/\+/ /g;

    my @orders;
    eval {
        my $rs = $self->_order_rs($c, { customer_name => $customer_name });
        while (my $o = $rs->next) {
            next unless $self->_is_open_status($o->status);
            push @orders, $self->_order_row($c, $o);
        }
        # Fallback: match customer name across sitenames
        if (!@orders) {
            my $all = $c->model('DBEncy')->resultset('Accounting::InventoryCustomerOrder')->search(
                { 'me.customer_name' => $customer_name },
                { order_by => { -desc => 'me.id' }, prefetch => { lines => 'item' }, rows => 50 },
            );
            while (my $o = $all->next) {
                next unless $self->_is_open_status($o->status);
                my $row = $self->_order_row($c, $o);
                $row->{scope_note} = ($row->{scope_note} || '')
                    . ' [sitename=' . ($o->sitename || '?') . ']';
                push @orders, $row;
            }
        }
    };

    # Synthetic in-house INT-HDRY-001 if customer is In-House and no rows
    if (!@orders && $customer_name =~ /^in-?house$/i) {
        my $hdry = eval {
            $c->model('DBEncy')->resultset('Accounting::InventoryItem')->find({
                sitename => $self->_sitename($c),
                sku      => HDRY_SYSTEM_SKU,
            });
        };
        my $hid = $hdry ? $hdry->id : HDRY_SYSTEM_ID;
        my $hname = $hdry ? $hdry->name : 'HDRY System V3';
        push @orders, {
            customer   => 'In-House',
            order_id   => 'item-' . $hid,
            order_date => $self->_today,
            items      => "$hname (" . HDRY_SYSTEM_SKU . ')',
            status     => 'open',
            scope_note => 'Full INT-HDRY-001 BOM (wheel kit subset under base)',
            source     => 'in_house_item',
            has_hdry   => 1,
            link       => $c->uri_for('/Accounting/manufacturing/view/item', $hid),
            print_link => $c->uri_for('/Accounting/manufacturing/print/item', $hid),
        };

        # Synthetic for base and addon when viewing In-House customer
        foreach my $sub (
            { id => HDRY_BASE_ID, sku => HDRY_BASE_SKU, name => 'HDRY Base unit (bottom, top, wheels)' },
            { id => HDRY_ADDON_ID, sku => HDRY_ADDON_SKU, name => 'HDRY Add-on module (stacks, no bottom/top)' }
        ) {
            my $sub_item = eval {
                $c->model('DBEncy')->resultset('Accounting::InventoryItem')->find({
                    sitename => $self->_sitename($c),
                    sku      => $sub->{sku},
                });
            };
            my $sid = $sub_item ? $sub_item->id : $sub->{id};
            my $sname = $sub_item ? $sub_item->name : $sub->{name};
            push @orders, {
                customer   => 'In-House',
                order_id   => 'item-' . $sid,
                order_date => $self->_today,
                items      => "$sname (" . $sub->{sku} . ')',
                status     => 'open',
                scope_note => 'In-house ' . ($sub->{id} == HDRY_BASE_ID ? 'base unit' : 'addon/top') . ' build',
                source     => 'in_house_item',
                link       => $c->uri_for('/Accounting/manufacturing/view/item', $sid),
                print_link => $c->uri_for('/Accounting/manufacturing/print/item', $sid),
            };
        }
    }

    return {
        customer    => $customer_name,
        open_orders => \@orders,
    };
}

# Back-compat name used by controller
sub get_open_manufacturing_orders {
    my ($self, $c) = @_;
    my $pack = $self->get_customers_with_open_orders($c);
    return $pack->{open_orders} || [];
}

# -------------------------------------------------------------------------
# Traveler data: customer order id OR item-<id> / bare inventory item id
# -------------------------------------------------------------------------

sub get_traveler_data {
    my ($self, $c, $order_id) = @_;
    $order_id = '' unless defined $order_id;

    # Explicit inventory-item traveler: item-51 or path view/item/51
    if ($order_id =~ /^item-(\d+)$/i) {
        return $self->_traveler_for_item($c, 0 + $1);
    }

    # Numeric: prefer real customer order, else inventory item
    if ($order_id =~ /^\d+$/) {
        my $co = eval {
            $c->model('DBEncy')->resultset('Accounting::InventoryCustomerOrder')->find(
                { id => 0 + $order_id },
                { prefetch => { lines => 'item' } },
            );
        };
        if ($co) {
            return $self->_traveler_for_customer_order($c, $co);
        }
        return $self->_traveler_for_item($c, 0 + $order_id);
    }

    # SKU
    if ($order_id ne '') {
        my $item = eval {
            $c->model('DBEncy')->resultset('Accounting::InventoryItem')->find({
                sitename => $self->_sitename($c),
                sku      => $order_id,
            });
        };
        return $self->_traveler_for_item($c, $item->id) if $item;
    }

    # Default in-house system
    return $self->_traveler_for_item($c, HDRY_SYSTEM_ID);
}

sub _traveler_for_customer_order {
    my ($self, $c, $order) = @_;

    my @leaves;
    my @line_notes;
    eval {
        for my $line ($order->lines->all) {
            my $item = eval { $line->item };
            my $qty  = $line->quantity || 1;
            if ($item) {
                my $iid  = $item->id;
                my $isku = $item->sku || '';
                my $bom  = $self->_list_bom($c, $iid, $isku);
                my $bl   = $bom->{lines} || [];
                if (@$bl) {
                    push @leaves, $self->_explode_to_leaves($c, $iid, $isku, $qty, {});
                } else {
                    # Leaf sellable part on the order
                    push @leaves, {
                        component_item_id => $iid,
                        sku               => $isku,
                        name              => $item->name || $line->description || $isku,
                        quantity          => $qty,
                        item_origin       => eval { $item->item_origin } // '',
                    };
                }
                push @line_notes, sprintf('%sx %s (%s)', $qty, $item->name || '', $isku);
            } elsif ($line->description) {
                push @line_notes, ($line->quantity || 1) . 'x ' . $line->description;
            }
        }
    };

    my @merged = $self->_merge_leaves(@leaves);
    my $parts  = $self->_parts_from_leaves($c, @merged);

    return {
        order_id      => $order->id,
        order_kind    => 'customer_order',
        customer_name => $order->customer_name || 'Customer',
        order_date    => $self->_fmt_date($order->created_at),
        parent_sku    => '',
        parent_name   => 'Order #' . $order->id,
        notes         => join(' | ', grep { $_ } ($order->notes, @line_notes))
            || 'Customer order manufacturing traveler',
        live_url      => '' . $c->uri_for('/Accounting/manufacturing/view', $order->id),
        print_url     => '' . $c->uri_for('/Accounting/manufacturing/print', $order->id),
        parts         => $parts,
        modules       => $self->get_dryer_modules($c),
        id            => $order->id,
        bom_note      => 'Exploded from each order line item BOM. INT-HDRY-001 expands base+add-on; HW-WHEEL-KIT is nested under base.',
    };
}

sub _traveler_for_item {
    my ($self, $c, $parent_id) = @_;
    $parent_id ||= HDRY_SYSTEM_ID;

    my ($parent_sku, $parent_name) = (HDRY_SYSTEM_SKU, HDRY_SYSTEM_SKU);
    eval {
        my $parent = $c->model('DBEncy')->resultset('Accounting::InventoryItem')->find($parent_id);
        if ($parent) {
            $parent_sku  = $parent->sku;
            $parent_name = $parent->name;
            $parent_id   = $parent->id;
        }
    };

    my @leaves = $self->_merge_leaves(
        $self->_explode_to_leaves($c, $parent_id, $parent_sku, 1, {})
    );
    # If item has no BOM, show the item itself
    unless (@leaves) {
        @leaves = ({
            component_item_id => $parent_id,
            sku               => $parent_sku,
            name              => $parent_name,
            quantity          => 1,
            item_origin       => '3d_printed',
        });
    }

    my $parts   = $self->_parts_from_leaves($c, @leaves);
    my $is_hdry = ($parent_sku eq HDRY_SYSTEM_SKU || $parent_id == HDRY_SYSTEM_ID);

    return {
        order_id      => $parent_id,
        order_kind    => 'inventory_item',
        customer_name => $is_hdry ? 'In-House' : 'Assembly',
        order_date    => $self->_today,
        parent_sku    => $parent_sku,
        parent_name   => $parent_name,
        notes         => $is_hdry
            ? 'In-house order for INT-HDRY-001 (HDRY System V3). Full BOM exploded; '
              . 'wheel kit (HW-WHEEL-KIT) is a nested subset under the base unit, not a separate order.'
            : "Manufacturing traveler for $parent_name ($parent_sku).",
        live_url      => '' . $c->uri_for('/Accounting/manufacturing/view/item', $parent_id),
        print_url     => '' . $c->uri_for('/Accounting/manufacturing/print/item', $parent_id),
        parts         => $parts,
        modules       => $self->get_dryer_modules($c),
        id            => $parent_id,
        bom_note      => 'Leaf BOM after exploding nested assemblies under this inventory item.',
    };
}

1;

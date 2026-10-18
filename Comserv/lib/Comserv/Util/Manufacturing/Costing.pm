package Comserv::Util::Manufacturing::Costing;
# Generic manufacturing costing (3D printing first; any process later).
#
# On job completion: run cost = material + machine wear + electricity + labour,
# plus a normal scrap/yield allowance, divided by units made. The produced
# inventory item's unit_cost becomes a weighted MOVING AVERAGE of stock on hand
# and the new run; selling_price = unit_cost x (1 + markup%), rounded UP to $0.05
# (CAD), unless the item has manual_price = 1.
#
# Settings: comserv.conf <Manufacturing> (editable), defaults below.
# New DB pieces are optional: if inventory_items.markup_percent/manual_price,
# printing_3d_jobs.labour_cost/cost_breakdown or table mfg_cost_history are not
# there yet, those writes are skipped with a warning (sql/20261017_manufacturing_costing.sql).
use strict;
use warnings;
use POSIX qw(ceil);
use JSON ();
use Comserv::Util::Logging;

# Researched defaults (see docs/plans/manufacturing_costing_plan.md for sources).
our %DEFAULTS = (
    currency       => 'CAD',
    markup_percent => 50,      # small/local 3D print service: 30-60% typical
    labour_rate    => 38.46,   # CAD/hr, BC median manufacturing technician (Job Bank)
    kwh_rate       => 0.1408,  # CAD/kWh, BC Hydro residential Tier 2 (marginal kWh)
    scrap_percent  => 5,       # normal failed-print / purge allowance (yield 95%)
    round_to       => 0.05,
    steps => {                 # default hands-on minutes per job
        queue_management => 2,
        slicing          => 5, # skipped when the job file is already sliced (gcode/gcode.3mf)
        send_to_printer  => 2,
        filament_change  => 3, # per change (0 changes by default)
        maintenance      => 3, # share of between-print maintenance
        collect_clean    => 5,
    },
);

sub new { my ($class, %a) = @_; return bless { %a }, $class }
sub logging { Comserv::Util::Logging->instance }

sub settings {
    my ($self, $c) = @_;
    my %s = %DEFAULTS;
    $s{steps} = { %{ $DEFAULTS{steps} } };
    my $cfg = eval { $c && $c->config->{Manufacturing} };
    if (ref $cfg eq 'HASH') {
        for my $k (qw(currency markup_percent labour_rate kwh_rate scrap_percent round_to)) {
            $s{$k} = $cfg->{$k} if defined $cfg->{$k} && $cfg->{$k} ne '';
        }
        if (ref $cfg->{steps} eq 'HASH') {
            for my $k (keys %{ $cfg->{steps} }) {
                $s{steps}{$k} = 0 + $cfg->{steps}{$k} if $cfg->{steps}{$k} =~ /^\d+(?:\.\d+)?$/;
            }
        }
    }
    return \%s;
}

# ---- pure math (tested in t/manufacturing_costing.t) ----
sub ceil_to {
    my ($x, $step) = @_;
    $step ||= 0.05;
    return 0 unless $x && $x > 0;
    my $cents = ceil($x * 100 - 1e-6);
    my $sc    = int($step * 100 + 0.5) || 1;
    return sprintf('%.2f', ceil($cents / $sc) * $sc / 100) + 0;
}

sub moving_average {
    my ($old_qty, $old_cost, $new_qty, $new_unit) = @_;
    $old_qty = 0 if !$old_qty || $old_qty < 0 || !defined $old_cost || $old_cost <= 0;
    my $tot = $old_qty + $new_qty;
    return $new_unit unless $tot > 0;
    return ($old_qty * ($old_cost || 0) + $new_qty * $new_unit) / $tot;
}

# Yield method: good units must carry the cost of normal failures.
sub with_scrap { my ($cost, $pct) = @_; $pct ||= 0; return $pct >= 100 ? $cost : $cost / (1 - $pct / 100) }

sub electricity_cost { my ($hours, $watts, $rate) = @_; return ($hours || 0) * ($watts || 0) * ($rate || 0) / 1000 }

sub labour_minutes {
    my ($s, %f) = @_;
    my $st = $s->{steps};
    my %m = map { $_ => ($st->{$_} || 0) } grep { $_ ne 'filament_change' } keys %$st;
    $m{slicing} = 0 if $f{pre_sliced};
    $m{filament_change} = ($st->{filament_change} || 0) * ($f{filament_changes} || 0);
    $m{$_} = $f{actual}{$_} for keys %{ $f{actual} || {} };   # logged time wins
    return \%m;
}

sub breakdown {
    my ($s, %a) = @_;
    my $qty = ($a{quantity} && $a{quantity} > 0) ? $a{quantity} : 1;
    my $mins = labour_minutes($s, %a);
    my $lab_min = 0; $lab_min += $_ for values %$mins;
    my %b = (
        currency      => $s->{currency},
        grams         => $a{grams} || 0,
        hours         => $a{hours} || 0,
        filament      => $a{filament_cost} || 0,
        machine       => $a{machine_cost}  || 0,
        electricity   => defined $a{electricity_cost} ? $a{electricity_cost}
                         : electricity_cost($a{hours}, $a{watts}, $s->{kwh_rate}),
        labour_minutes=> $mins,
        labour_total_minutes => $lab_min,
        labour_rate   => $s->{labour_rate},
    );
    $b{labour}   = $lab_min / 60 * $s->{labour_rate};
    $b{subtotal} = $b{filament} + $b{machine} + $b{electricity} + $b{labour};
    $b{scrap_percent} = $s->{scrap_percent};
    $b{total}    = with_scrap($b{subtotal}, $s->{scrap_percent});
    $b{scrap}    = $b{total} - $b{subtotal};
    $b{quantity} = $qty;
    $b{unit_cost}= $b{total} / $qty;
    $b{$_} = sprintf('%.4f', $b{$_}) + 0 for qw(filament machine electricity labour subtotal scrap total unit_cost);
    return \%b;
}

sub selling_price {
    my ($s, $unit_cost, $markup) = @_;
    $markup = $s->{markup_percent} unless defined $markup && $markup ne '';
    return ceil_to($unit_cost * (1 + $markup / 100), $s->{round_to});
}

# ---- DB helpers (degrade safely) ----
my %_col_cache;
sub _has_col {
    my ($dbh, $table, $col) = @_;
    my $k = "$table.$col";
    return $_col_cache{$k} if exists $_col_cache{$k};
    my $n = eval { $dbh->selectrow_array(
        'SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?',
        undef, $table, $col) } || 0;
    return $_col_cache{$k} = $n ? 1 : 0;
}

sub _onhand {
    my ($dbh, $item_id) = @_;
    return 0 + (eval { $dbh->selectrow_array(
        'SELECT COALESCE(SUM(quantity_on_hand),0) FROM inventory_stock_levels WHERE item_id = ?', undef, $item_id) } || 0);
}

sub _history {
    my ($self, $c, $dbh, %h) = @_;
    my $ok = eval {
        $dbh->do('INSERT INTO mfg_cost_history (sitename,item_id,job_id,event,old_cost,new_cost,old_price,new_price,detail,created_by,created_at)
                  VALUES (?,?,?,?,?,?,?,?,?,?,UTC_TIMESTAMP())', undef,
            @h{qw(sitename item_id job_id event old_cost new_cost old_price new_price)},
            JSON->new->canonical->encode($h{detail} || {}), $h{created_by});
        1;
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'costing',
        "mfg_cost_history not written (table missing?): $@") unless $ok;
}

# Update the item's moving-average cost (adding $add_total to $add_qty new units,
# or spreading $add_total over stock when $add_qty = 0) and reprice it.
sub _apply_to_item {
    my ($self, $c, $dbh, %a) = @_;
    my $s = $a{settings};
    my $item = $dbh->selectrow_hashref('SELECT * FROM inventory_items WHERE id = ?', undef, $a{item_id})
        or return { ok => 0, error => 'item not found' };
    my $old_cost  = 0 + ($item->{unit_cost} || 0);
    my $old_price = $item->{selling_price};
    my $onhand    = $a{onhand} // _onhand($dbh, $a{item_id});
    my $new_cost;
    if ($a{add_qty}) {
        $new_cost = moving_average($onhand, $old_cost, $a{add_qty}, $a{add_total} / $a{add_qty});
    } else {
        $new_cost = $old_cost + $a{add_total} / ($onhand > 0 ? $onhand : 1);
    }
    $new_cost = sprintf('%.4f', $new_cost) + 0;
    my $manual = _has_col($dbh, 'inventory_items', 'manual_price') ? ($item->{manual_price} || 0) : 0;
    my $markup = _has_col($dbh, 'inventory_items', 'markup_percent') ? $item->{markup_percent} : undef;
    my $new_price = $manual ? $old_price : selling_price($s, $new_cost, $markup);
    $dbh->do('UPDATE inventory_items SET unit_cost = ?, selling_price = ?, updated_at = UTC_TIMESTAMP() WHERE id = ?',
        undef, $new_cost, $new_price, $a{item_id});
    $self->_history($c, $dbh, sitename => $a{sitename}, item_id => $a{item_id}, job_id => $a{job_id},
        event => $a{event}, old_cost => $old_cost, new_cost => $new_cost,
        old_price => $old_price, new_price => $new_price, detail => $a{detail},
        created_by => (eval { $c->session->{username} } || 'system'));
    return { ok => 1, old_cost => $old_cost, new_cost => $new_cost, old_price => $old_price,
             new_price => $new_price, manual_price => $manual, onhand_before => $onhand };
}

# Called from the 3D queue Complete action BEFORE finished goods are received.
# %a: job, item_id (produced item or undef), filament_cost, printer_cost,
#     electricity_cost, grams, hours, sitename
sub rollup_job {
    my ($self, $c, %a) = @_;
    my $job = $a{job};
    my $s   = $self->settings($c);
    my $dbh = $c->model('DBEncy')->schema->storage->dbh;
    my $file = join ' ', grep { defined } ($job->item_name, eval { $job->notes });
    my $b = breakdown($s,
        quantity         => $job->quantity || 1,
        grams            => $a{grams},
        hours            => $a{hours},
        filament_cost    => $a{filament_cost},
        machine_cost     => $a{printer_cost},
        electricity_cost => $a{electricity_cost},
        pre_sliced       => ($file =~ /\.gcode/i ? 1 : 0),
    );
    if (_has_col($dbh, 'printing_3d_jobs', 'cost_breakdown')) {
        eval { $dbh->do('UPDATE printing_3d_jobs SET labour_cost = ?, cost_breakdown = ? WHERE id = ?',
            undef, $b->{labour}, JSON->new->canonical->encode($b), $job->id) };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'costing', "job breakdown not saved: $@") if $@;
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'costing',
            'printing_3d_jobs.cost_breakdown missing; breakdown not stored (run sql/20261017_manufacturing_costing.sql)');
    }
    my $res = { ok => 1, breakdown => $b };
    if ($a{item_id}) {
        $res->{item} = $self->_apply_to_item($c, $dbh, settings => $s, item_id => $a{item_id},
            add_qty => $b->{quantity}, add_total => $b->{total}, job_id => $job->id,
            sitename => $a{sitename}, event => 'job_complete', detail => $b);
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'costing', sprintf(
        'job %d run total %.2f %s (%.2f/unit) item %s cost %s -> %s price %s -> %s',
        $job->id, $b->{total}, $s->{currency}, $b->{unit_cost}, $a{item_id} // '-',
        $res->{item}{old_cost} // '-', $res->{item}{new_cost} // '-',
        $res->{item}{old_price} // '-', $res->{item}{new_price} // '-'));
    return $res;
}

# Traveler labour logged (minutes, step). Replaces the job's default minutes
# for that step once (when the breakdown is stored); otherwise the full labour
# cost is spread over stock on hand. Never just adds the run total to unit_cost.
sub apply_logged_labour {
    my ($self, $c, %a) = @_;
    my $s   = $self->settings($c);
    my $dbh = $c->model('DBEncy')->schema->storage->dbh;
    my $cost = $a{minutes} / 60 * $s->{labour_rate};
    my $extra = $cost;
    my $job_id = $a{job_id};
    if ($job_id && _has_col($dbh, 'printing_3d_jobs', 'cost_breakdown')) {
        my ($json) = eval { $dbh->selectrow_array('SELECT cost_breakdown FROM printing_3d_jobs WHERE id = ?', undef, $job_id) };
        my $b = $json ? eval { JSON::decode_json($json) } : undef;
        if ($b && $a{step} && exists $b->{labour_minutes}{ $a{step} } && !$b->{actual}{ $a{step} }) {
            $extra = $cost - ($b->{labour_minutes}{ $a{step} } / 60 * $s->{labour_rate});
            $b->{actual}{ $a{step} } = $a{minutes};
        } elsif ($b) {
            $b->{actual}{ $a{step} || 'other' } = ($b->{actual}{ $a{step} || 'other' } || 0) + $a{minutes};
        }
        if ($b) {
            $b->{labour} = sprintf('%.4f', ($b->{labour} || 0) + $extra) + 0;
            eval { $dbh->do('UPDATE printing_3d_jobs SET labour_cost = ?, cost_breakdown = ? WHERE id = ?',
                undef, $b->{labour}, JSON->new->canonical->encode($b), $job_id) };
        }
    }
    return { ok => 1, labour_cost => $cost, applied => 0 } if abs($extra) < 0.00005;
    my $r = $self->_apply_to_item($c, $dbh, settings => $s, item_id => $a{item_id}, add_qty => 0,
        add_total => $extra, job_id => $job_id, sitename => $a{sitename}, event => 'labour_log',
        detail => { step => $a{step}, minutes => $a{minutes}, labour_cost => $cost, applied => $extra });
    return { %$r, labour_cost => $cost, applied => $extra };
}

1;

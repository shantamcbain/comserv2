package Comserv::Util::Printing3d;

use strict;
use warnings;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::Printing3d - thin helpers for the 3D print-farm workflow.

=head1 DESCRIPTION

Keeps new print-farm orchestration OUT of the (already large) Controller::3d.
reorder_item(), STL volume parse, filament estimate, change_filament().

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub _now { return sprintf('%04d-%02d-%02d %02d:%02d:%02d', (localtime)[5]+1900, (localtime)[4]+1, (localtime)[3], (localtime)[2], (localtime)[1], (localtime)[0]) }

# Queue a reprint of a finished-goods inventory item to restock it.
# Finds the linked active printing_3d_models row (if any) so the job carries a
# model_id; otherwise queues a standalone job named after the item. Quantity
# defaults to the item's reorder_quantity (or 1).
# Returns { ok => 1, job_id => $id } or { ok => 0, error => $msg }.
sub reorder_item {
    my ($self, $c, $item_id) = @_;

    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $schema   = $c->model('DBEncy');
    my $item;
    try { $item = $schema->resultset('Accounting::InventoryItem')->find($item_id) }
        catch { };
    return { ok => 0, error => 'Item not found.' } unless $item;

    my $model;
    try {
        $model = $schema->resultset('Printing3dModel')->search(
            { item_id => $item_id, sitename => $sitename, is_active => 1 },
            { order_by => { -asc => 'id' } },
        )->first;
    }
    catch { };

    my $qty = $item->reorder_quantity && $item->reorder_quantity > 0
            ? $item->reorder_quantity : 1;

    my $job;
    try {
        $job = $schema->resultset('Printing3dJob')->create({
            sitename            => $sitename,
            model_id            => $model ? $model->id : undef,
            item_id             => $item_id,
            user_id             => $c->session->{user_id} || 0,
            username            => $c->session->{username} || 'admin',
            status              => 'queued',
            quantity            => $qty,
            item_name           => $item->name,
            notes               => 'Reorder: restock to reorder quantity',
            inventory_reserved  => 0,
            created_at          => _now(),
        });
    }
    catch {
        my $err = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'reorder_item', "Failed to queue reorder for item $item_id: $err");
        return { ok => 0, error => "Could not queue reorder: $err" };
    };

    return { ok => 1, job_id => $job ? $job->id : undef };
}

# g/cm3. stl_weight_g on models is stored as PLA (1.24).
my %DENSITY = (
    pla   => 1.24,
    petg  => 1.27,
    'pet-g' => 1.27,
    abs   => 1.04,
    tpu   => 1.21,
    nylon => 1.14,
    asa   => 1.07,
);

sub density_for {
    my ($self, $type) = @_;
    my $k = lc($type // '');
    $k =~ s/[^a-z0-9\-]//g;
    return $DENSITY{$k} || $DENSITY{pla};
}

sub parse_stl {
    my ($self, $filepath) = @_;
    return undef unless $filepath && -r $filepath;
    open my $fh, '<:raw', $filepath or return undef;
    my $header;
    read($fh, $header, 80) or do { close $fh; return undef; };
    my ($volume_cm3, $triangle_count) = (0, 0);
    my $is_ascii = ($header =~ /^solid\s/i && $header !~ /\x00/);
    if (!$is_ascii) {
        my $buf;
        read($fh, $buf, 4) or do { close $fh; return undef; };
        $triangle_count = unpack('V', $buf);
        for my $i (1 .. $triangle_count) {
            my $tri;
            read($fh, $tri, 50) or last;
            my (undef, $x1,$y1,$z1, $x2,$y2,$z2, $x3,$y3,$z3) =
                unpack('f<3 f<3 f<3 f<3', $tri);
            $volume_cm3 += ($x1*($y2*$z3 - $y3*$z2)
                          - $y1*($x2*$z3 - $x3*$z2)
                          + $z1*($x2*$y3 - $x3*$y2)) / 6.0;
        }
    } else {
        seek $fh, 0, 0;
        my @vertices;
        while (my $line = <$fh>) {
            if ($line =~ /^\s*vertex\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)/i) {
                push @vertices, [$1+0, $2+0, $3+0];
                if (@vertices == 3) {
                    my ($v1,$v2,$v3) = @vertices;
                    $volume_cm3 += ($v1->[0]*($v2->[1]*$v3->[2] - $v3->[1]*$v2->[2])
                                  - $v1->[1]*($v2->[0]*$v3->[2] - $v3->[0]*$v2->[2])
                                  + $v1->[2]*($v2->[0]*$v3->[1] - $v3->[0]*$v2->[1])) / 6.0;
                    @vertices = ();
                    $triangle_count++;
                }
            }
        }
    }
    close $fh;
    $volume_cm3 = abs($volume_cm3) / 1000.0;
    return { volume_cm3 => $volume_cm3, triangles => $triangle_count };
}

# This site stores filament on_hand in grams even when unit_of_measure is 'each'.
sub stock_qty_from_grams {
    my ($self, $fil, $grams) = @_;
    return 0 unless $grams && $grams > 0;
    my $uom = lc($fil ? ($fil->unit_of_measure || '') : '');
    return $grams if $uom eq 'g' || $uom eq 'gram' || $uom eq 'grams';
    return $grams if $uom eq '' || $uom eq 'each';
    return $grams / 1000 if $uom eq 'kg';
    return $grams;
}

sub infer_type_color {
    my ($self, $item) = @_;
    return ('', '') unless $item;
    my $type  = $item->filament_type  || '';
    my $color = $item->filament_color || '';
    my $name  = $item->name || '';
    $type  = 'PETG'  if !$type  && $name =~ /PET[- ]?G/i;
    $type  = 'PLA'   if !$type  && $name =~ /\bPLA\b/i;
    $type  = 'TPU'   if !$type  && $name =~ /\bTPU\b/i;
    $type  = 'Nylon' if !$type  && $name =~ /nylon/i;
    $color = 'White' if !$color && $name =~ /white/i;
    $color = 'Black' if !$color && $name =~ /black/i;
    $color = 'Blue'  if !$color && $name =~ /blue/i;
    $color = 'Red'   if !$color && $name =~ /red/i;
    $color = 'Clear' if !$color && $name =~ /clear|transparent/i;
    return ($type, $color);
}

# Any queue row: model_id, else model linked to the printed item
# (restock source_item_id, consignment line item, then name match).
sub resolve_model_for_job {
    my ($self, $schema, $job) = @_;
    return undef unless $schema && $job;
    my $sitename = $job->sitename || '';
    if ($job->model_id) {
        my $m = eval { $schema->resultset('Printing3dModel')->find($job->model_id) };
        return $m if $m;
    }
    my @item_ids;
    push @item_ids, $job->source_item_id if $job->source_item_id;
    if ($job->consignment_line_id) {
        my $iid = eval {
            $schema->storage->dbh->selectrow_array(
                'SELECT item_id FROM inventory_consignment_lines WHERE id = ?',
                undef, $job->consignment_line_id);
        };
        push @item_ids, $iid if $iid;
    }
    for my $iid (@item_ids) {
        my $m = eval {
            $schema->resultset('Printing3dModel')->search(
                { item_id => $iid, sitename => $sitename, is_active => 1 },
                { order_by => { -asc => 'id' } },
            )->first;
        };
        return $m if $m;
    }
    if ($job->item_name) {
        my $m = eval {
            $schema->resultset('Printing3dModel')->search(
                {
                    sitename => $sitename,
                    is_active => 1,
                    name     => $job->item_name,
                },
                { rows => 1 },
            )->first;
        };
        return $m if $m;
    }
    return undef;
}

sub estimate_grams {
    my ($self, $model, $filament_type) = @_;
    return { grams => undef, source => 'none', volume_cm3 => undef }
        unless $model;
    my $dens = $self->density_for($filament_type);
    my $vol  = $model->stl_volume_cm3;
    if ($vol && $vol > 0) {
        return {
            grams      => sprintf('%.2f', $vol * $dens),
            source     => 'stl_volume',
            volume_cm3 => 0 + $vol,
            density    => $dens,
        };
    }
    my $pla_g = $model->stl_weight_g;
    if ($pla_g && $pla_g > 0) {
        return {
            grams      => sprintf('%.2f', $pla_g * ($dens / 1.24)),
            source     => 'stl_weight_pla',
            volume_cm3 => undef,
            density    => $dens,
        };
    }
    my $path = $model->nfs_path || '';
    if ($path =~ /\.stl$/i && -r $path) {
        my $info = $self->parse_stl($path);
        if ($info && $info->{volume_cm3}) {
            return {
                grams      => sprintf('%.2f', $info->{volume_cm3} * $dens),
                source     => 'parsed_stl',
                volume_cm3 => $info->{volume_cm3},
                density    => $dens,
            };
        }
    }
    my $ft = lc($model->file_type || '');
    return {
        grams      => undef,
        source     => ($ft eq '3mf' ? '3mf_needs_stl' : 'no_geometry'),
        volume_cm3 => undef,
        density    => $dens,
    };
}

sub list_filaments {
    my ($self, $schema, $sitename) = @_;
    my @rows;
    try {
        @rows = $schema->resultset('Accounting::InventoryItem')->search(
            {
                sitename => $sitename,
                status   => 'active',
                -or      => [
                    { category       => { -like => '%Filament%' } },
                    { category       => { -like => '%3D Print%' } },
                    { name           => { -like => '%Filament%' } },
                    { filament_type  => { '!=', undef } },
                ],
            },
            { order_by => 'name' },
        )->all;
    }
    catch { };
    my @out;
    for my $it (@rows) {
        next if ($it->item_origin || '') eq '3d_printed';
        next if ($it->category || '') =~ /printer|equipment|cost/i;
        my ($type, $color) = $self->infer_type_color($it);
        my $on_hand = 0;
        try {
            for my $sl ($it->stock_levels->all) {
                $on_hand += ($sl->quantity_on_hand || 0);
            }
        }
        catch { };
        push @out, {
            id      => $it->id,
            name    => $it->name,
            sku     => $it->sku,
            type    => $type,
            color   => $color,
            on_hand => $on_hand,
            item    => $it,
        };
    }
    return @out;
}

# Swap spool + optional grams. Releases old reserve, reserves new. Same txn.
# $ctl is Controller::3d (for _inventory_transaction).
sub change_filament {
    my ($self, $c, $job, $filament_item_id, $grams, $ctl) = @_;
    return { ok => 0, error => 'Job not found.' } unless $job;
    my $st = $job->status || '';
    return { ok => 0, error => 'Job is not open (queued/assigned/printing).' }
        unless $st =~ /^(queued|assigned|printing)$/;
    return { ok => 0, error => 'Select a filament.' } unless $filament_item_id;

    my $schema   = $c->model('DBEncy');
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || '';
    my $fil;
    try { $fil = $schema->resultset('Accounting::InventoryItem')->find($filament_item_id) }
        catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'change_filament', "filament find failed: $_");
        };
    return { ok => 0, error => 'Filament item not found.' } unless $fil;
    return { ok => 0, error => 'Filament is not on this site.' }
        if $fil->sitename && $sitename && $fil->sitename ne $sitename;

    my ($type, $color) = $self->infer_type_color($fil);
    $grams = undef if defined $grams && $grams !~ /^\d+(?:\.\d+)?$/;
    $grams = undef if defined $grams && $grams <= 0;

    my $old_id   = $job->filament_item_id;
    my $old_g    = $job->filament_quantity;
    my $was_res  = $job->inventory_reserved;

    my $err;
    try {
        $schema->txn_do(sub {
            if ($was_res && $old_id && $old_g && $ctl) {
                my $old_fil = $schema->resultset('Accounting::InventoryItem')->find($old_id);
                my $sl = $old_fil ? eval { ($old_fil->stock_levels->all)[0] } : undef;
                $ctl->_inventory_transaction($c,
                    schema           => $schema,
                    sitename         => $sitename,
                    item_id          => $old_id,
                    location_id      => $sl ? $sl->location_id : undef,
                    transaction_type => 'reserve_release',
                    quantity         => $self->stock_qty_from_grams($old_fil, $old_g),
                    reference_number => '3D-JOB-' . $job->id,
                    notes            => 'Release reserve before filament change, job #' . $job->id,
                    performed_by     => $c->session->{username} || 'system',
                );
            }
            $job->update({
                filament_item_id   => $filament_item_id,
                filament_type      => $type || undef,
                filament_color     => $color || undef,
                filament_quantity  => $grams,
                inventory_reserved => 0,
            });
            if ($grams && $ctl) {
                my $sl = eval { ($fil->stock_levels->all)[0] };
                $ctl->_inventory_transaction($c,
                    schema           => $schema,
                    sitename         => $sitename,
                    item_id          => $filament_item_id,
                    location_id      => $sl ? $sl->location_id : undef,
                    transaction_type => 'reserve',
                    quantity         => $self->stock_qty_from_grams($fil, $grams),
                    reference_number => '3D-JOB-' . $job->id,
                    notes            => sprintf('Filament reserved: %sg for job #%d', $grams, $job->id),
                    performed_by     => $c->session->{username} || 'system',
                );
                $job->update({ inventory_reserved => 1 });
            }
        });
    }
    catch {
        $err = "$_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'change_filament', "job ".$job->id." failed: $err");
    };
    return { ok => 0, error => $err } if $err;
    return {
        ok      => 1,
        job_id  => $job->id,
        grams   => $grams,
        reserved => $grams ? 1 : 0,
    };
}

__PACKAGE__->meta->make_immutable;
1;

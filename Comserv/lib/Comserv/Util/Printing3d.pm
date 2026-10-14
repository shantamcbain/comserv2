package Comserv::Util::Printing3d;

use strict;
use warnings;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use Comserv::Util::Logging;
use JSON::MaybeXS qw(decode_json from_json);
use File::Copy qw(copy);
use File::Basename qw(basename dirname);
use DateTime;

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

# Parse 3MF files to extract slice info, filament usage, and copy files to model system.
sub parse_3mf {
    my ($self, $c, $filepath) = @_;
    return undef unless $filepath && -f $filepath;

    my $tmp_dir = "/tmp/3mf_extract_" . int(rand(10000));
    mkdir($tmp_dir) || return undef;

    # 3MF is a zip. Backticks return stdout, not the exit code — use system.
    my $rc = system('unzip', '-q', '-o', $filepath, '-d', $tmp_dir);
    return undef if $rc != 0;

    my %metadata;
    my $slice_info;
    my $filament_g = undef;
    my $print_hours = undef;

    # Look for common 3MF structure
    my $info_file = "$tmp_dir/Metadata/info.json";
    if (-f $info_file) {
        my $content = `cat '$info_file' 2>/dev/null`;
        $slice_info = eval { from_json($content) };
    }

    # Extract G-code from common locations
    my $gcode_files = `find '$tmp_dir' -name "*.gcode" -o -name "*.gco" 2>/dev/null`;
    if ($gcode_files) {
        my $last_gcode;
        for my $gpath (split('\n', $gcode_files)) {
            next unless $gpath && -f $gpath;
            $last_gcode = $gpath;
        }
        if ($last_gcode) {
            $metadata{gcode_path} = $last_gcode;
            $metadata{gcode_size} = -s $last_gcode;
            $metadata{gcode_mtime} = (stat $last_gcode)[9];
        }
    }

    # Look for slice data in JSON files
    my $slice_json = "$tmp_dir/Metadata/slice.json";
    if (-f $slice_json) {
        my $content = `cat '$slice_json' 2>/dev/null`;
        my $slice = eval { from_json($content) };
        if ($slice) {
            $metadata{slice_info} = $slice;
            $filament_g = $slice->{filament_used_g};
            $print_hours = $slice->{print_time_hours};
        }
    }

    # Fallback: try to estimate from gcode if we have it
    if (!$filament_g && $metadata{gcode_path}) {
        my $est = $self->estimate_filament_from_gcode($metadata{gcode_path});
        if ($est) {
            $filament_g = $est->{grams};
            $print_hours = $est->{hours};
        }
    }

    # Copy files to model system
    my $copy_result;
    if ($c && $c->stash->{SiteName}) {
        $copy_result = $self->copy_3mf_to_model_system($c, $filepath, $tmp_dir);
    }

    # Clean up
    my $cleanup_cmd = "rm -rf '$tmp_dir'";
    system($cleanup_cmd);

    return {
        metadata    => \%metadata,
        slice_info  => $slice_info,
        filament_g  => $filament_g,
        print_hours => $print_hours,
        copy_result => $copy_result,
    };
}

# Is this file something the Kobra can actually print?
# The printer rejects unsliced geometry with code 19007 "Invalid gcode file":
# a .stl is never sliced, and a plain .3mf from the library is geometry only.
# A sliced job from Anycubic Slicer Next is a .gcode (or a .gcode.3mf holding
# a .gcode/.gco inside the zip).
sub is_sliced_file {
    my ($self, $filepath) = @_;
    return 0 unless $filepath && -f $filepath;

    return 1 if $filepath =~ /\.gcode$/i;

    if ($filepath =~ /\.3mf$/i) {
        # Listing the zip is enough — no extraction, no side effects.
        my $listing = `unzip -l '$filepath' 2>/dev/null`;
        return 0 if $? && $listing !~ /\S/;
        return ($listing =~ /\.gcod?e"?\s*$/im) ? 1 : 0;
    }

    return 0;   # .stl and anything else is geometry, not a print job
}

# Estimate filament usage and print time from G-code file.
sub estimate_filament_from_gcode {
    my ($self, $gcode_path) = @_;
    return undef unless $gcode_path && -f $gcode_path;

    my $filament_total = 0;
    my $print_seconds = 0;
    my $line_count = 0;

    # Read gcode and extract filament usage and time estimate
    open my $fh, '<', $gcode_path or return undef;
    while (my $line = <$fh>) {
        $line_count++;
        
        # Extract filament length/grams from common G1 commands
        if ($line =~ /G91\s.*F(\d+\.?\d*)/i) {
            # filament feed rate can give hints about usage
        }
        
        # Look for M050, M105 or similar filament measurements
        if ($line =~ /G1\s.*E(\d+\.?\d*)/i) {
            $filament_total += $1; # extrude length in mm
        }
        
        # Extract time from G1 commands
        if ($line =~ /G1\s.*F(\d+\.?\d*)/i) {
            # estimate time based on filament movement speed
            my $distance = $1 / 60; # crude approximation
            $print_seconds += $distance;
        }
        
        # Look for G4 (wait) commands for delay-based time tracking
        if ($line =~ /G4\s+P(\d+)/i) {
            $print_seconds += $1 / 1000; # milliseconds to seconds
        }
    }
    close $fh;

    if ($filament_total > 0) {
        # Estimate grams from extrusion length (typical filament diameter ~1.75mm)
        my $filament_diameter = 1.75;
        my $area = 3.1416 * ($filament_diameter / 2) ** 2;
        my $volume_mm3 = $filament_total * $area;
        my $volume_cm3 = $volume_mm3 / 1000;
        
        # Typical filament density
        my $density = $self->density_for('PLA');
        my $grams = $volume_cm3 * $density;
        
        # Convert seconds to hours
        my $hours = $print_seconds / 3600;
        
        return {
            grams => sprintf('%.2f', $grams),
            hours => sprintf('%.2f', $hours),
            lines => $line_count,
        };
    }
    
    return undef;
}

# Copy the printer file into the model library (/data/nfs/3d/models), same store
# as Controller::3d model upload. Do not invent a worktree path from SiteName.
sub copy_3mf_to_model_system {
    my ($self, $c, $original_path, $tmp_dir) = @_;
    return { ok => 0, error => 'No Catalyst context or site name' } unless $c && $c->stash->{SiteName};

    my $sitename = $c->stash->{SiteName};
    my $schema = $c->model('DBEncy');
    my $src = $original_path;
    return { ok => 0, error => 'Source file missing' } unless $src && -f $src;

    my $base = basename($src);
    $base =~ s/[^\w.\-]+/_/g;
    $base = 'printer-file.3mf' if $base eq '' || $base eq '.' || $base eq '..';
    my $dest_dir = '/data/nfs/3d/models';
    unless (-d $dest_dir) {
        return { ok => 0, error => "Model library $dest_dir is not available" };
    }
    my $dest_path = "$dest_dir/$base";
    if (-e $dest_path) {
        my $stamp = time();
        $dest_path = "$dest_dir/${stamp}_$base";
    }
    unless (copy($src, $dest_path)) {
        return { ok => 0, error => "Copy to $dest_path failed: $!" };
    }

    my $model;
    my $err;
    eval {
        $model = $schema->resultset('Printing3dModel')->create({
            sitename   => $sitename,
            name       => $base,
            nfs_path   => $dest_path,
            file_type  => ($base =~ /\.3mf$/i ? '3mf' : 'unknown'),
            source     => 'printer_lan',
            is_active  => 1,
            created_at => _now(),
        });
    };
    $err = $@ if $@;
    return { ok => 0, error => "Copied file but model row failed: $err", path => $dest_path } if $err || !$model;
    return { ok => 1, copied_models => $base, model_id => $model->id, path => $dest_path };
}

# Parse STL files to extract volume and triangle count for filament estimation.
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
            # unpack('f<3 f<3 f<3 f<3') is WRONG: Perl does not group "f<3" as
            # three little-endian floats, so every vertex was garbage. Measured
            # 446.73 cm3 on a part whose true volume is 137.20 cm3 (3.3x high) —
            # which inflated every filament estimate derived from it.
            # Read 12 flat floats: normal(3) + v1(3) + v2(3) + v3(3).
            my @v = unpack('f<12', substr($tri, 0, 48));
            my ($x1,$y1,$z1, $x2,$y2,$z2, $x3,$y3,$z3) = @v[3..11];
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
    return { ok => 0, error => 'Job is not open (queued/assigned/printing) or completed.' }
        unless $st =~ /^(queued|assigned|printing|completed)$/;
    return { ok => 0, error => 'Select a filament.' } unless $filament_item_id;
    # 3D-20260907-4807: completed job had the wrong spool; re-cost it in place.
    return $self->recost_completed_filament($c, $job, $filament_item_id, $grams, $ctl)
        if $st eq 'completed';

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

# Correct filament / grams on a COMPLETED job (3D-20260907-4807).
# Returns the old spool's issued stock, issues the new spool, and recomputes
# filament_cost and total_cost (printer/electricity costs are kept).
sub recost_completed_filament {
    my ($self, $c, $job, $filament_item_id, $grams, $ctl) = @_;
    my $schema   = $c->model('DBEncy');
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || '';
    my $irs      = $schema->resultset('Accounting::InventoryItem');
    my $fil;
    try { $fil = $irs->find($filament_item_id) }
        catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'recost_completed_filament', "filament find failed: $_");
        };
    return { ok => 0, error => 'Filament item not found.' } unless $fil;
    return { ok => 0, error => 'Filament is not on this site.' }
        if $fil->sitename && $sitename && $fil->sitename ne $sitename;
    $grams = undef if defined $grams && $grams !~ /^\d+(?:\.\d+)?$/;
    $grams = undef if defined $grams && $grams <= 0;
    $grams //= $job->filament_quantity;
    return { ok => 0, error => 'Enter the grams actually used.' } unless $grams && $grams > 0;

    my ($type, $color) = $self->infer_type_color($fil);
    my $old_id   = $job->filament_item_id;
    my $old_g    = $job->filament_quantity;
    my $old_cost = $job->filament_cost || 0;
    my $new_cost;
    if ($fil->unit_cost) {
        my $uom = lc($fil->unit_of_measure || 'g');
        $new_cost = ($uom eq 'g') ? $grams * $fil->unit_cost : ($grams / 1000) * $fil->unit_cost;
    }
    my $other = ($job->total_cost || 0) - $old_cost;
    $other = 0 if $other < 0;
    my $new_total = $other + ($new_cost || 0);
    my $user = $c->session->{username} || 'system';
    my $ref  = '3D-JOB-' . $job->id;

    my $err;
    try {
        $schema->txn_do(sub {
            if ($ctl && $old_id && $old_g) {
                my $old_fil = $irs->find($old_id);
                my $sl = $old_fil ? eval { ($old_fil->stock_levels->all)[0] } : undef;
                $ctl->_inventory_transaction($c,
                    schema => $schema, sitename => $sitename, item_id => $old_id,
                    location_id => $sl ? $sl->location_id : undef,
                    transaction_type => 'return',
                    quantity => $self->stock_qty_from_grams($old_fil, $old_g),
                    reference_number => $ref,
                    notes => sprintf('Filament correction: return %sg wrongly issued to job #%d', $old_g, $job->id),
                    performed_by => $user,
                );
            }
            if ($ctl) {
                my $sl  = eval { ($fil->stock_levels->all)[0] };
                my $qty = $self->stock_qty_from_grams($fil, $grams);
                $ctl->_inventory_transaction($c,
                    schema => $schema, sitename => $sitename, item_id => $filament_item_id,
                    location_id => $sl ? $sl->location_id : undef,
                    transaction_type => 'issue',
                    quantity => $qty,
                    unit_cost => ($new_cost && $qty) ? $new_cost / $qty : undef,
                    reference_number => $ref,
                    notes => sprintf('Filament correction: %sg issued for completed job #%d', $grams, $job->id),
                    performed_by => $user,
                );
            }
            $job->update({
                filament_item_id  => $filament_item_id,
                filament_type     => $type || undef,
                filament_color    => $color || undef,
                filament_quantity => $grams,
                filament_cost     => $new_cost,
                total_cost        => $new_total || undef,
            });
        });
    }
    catch {
        $err = "$_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'recost_completed_filament', "job " . $job->id . " failed: $err");
    };
    return { ok => 0, error => $err } if $err;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'recost_completed_filament',
        sprintf('job %d filament %s/%sg -> %s/%sg cost %.2f -> %.2f', $job->id,
            $old_id // '-', $old_g // '-', $filament_item_id, $grams, $old_cost, $new_cost || 0));
    return { ok => 1, job_id => $job->id, grams => $grams, recosted => 1 };
}

# Re-open a job that was marked complete (or cancelled) by mistake.
# Resets status -> queued and unwinds the inventory side effects that the
# complete/cancel handlers applied:
#   * filament 'issue'  -> 'return'   (stock back on hand)
#   * finished goods 'receive' -> 'issue' (part taken back out of stock)
#   * printer 'depreciation' isNOT reversed (already consumed; accounting artefact)
# $ctl is Controller::3d (for _inventory_transaction).
# Returns { ok => 1, job_id => $id, reversed => \@notes } or { ok => 0, error => $msg }.
sub reopen_job {
    my ($self, $c, $job, $ctl) = @_;
    return { ok => 0, error => 'Job not found.' } unless $job;

    my $st = $job->status || '';
    return { ok => 0, error => 'Only completed or cancelled jobs can be reopened.' }
        unless $st =~ /^(completed|cancelled)$/;

    my $schema   = $c->model('DBEncy');
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || '';
    my $who      = $c->session->{username} || 'system';
    my @reversed;

    my $err;
    try {
        $schema->txn_do(sub {
            # ---- 1. Reverse the filament issue (grams consumed at completion) ----
            if ($job->filament_item_id && $job->filament_quantity) {
                my $fil = eval { $schema->resultset('Accounting::InventoryItem')
                                    ->find($job->filament_item_id) };
                my $sl  = $fil ? eval { ($fil->stock_levels->all)[0] } : undef;
                my $qty = $self->stock_qty_from_grams($fil, $job->filament_quantity);
                $ctl->_inventory_transaction($c,
                    schema           => $schema,
                    sitename         => $sitename,
                    item_id          => $job->filament_item_id,
                    location_id      => $sl ? $sl->location_id : undef,
                    transaction_type => 'return',
                    quantity         => $qty,
                    unit_cost        => ($job->filament_cost && $qty)
                                        ? ($job->filament_cost / $qty) : undef,
                    reference_number => '3D-JOB-' . $job->id,
                    notes            => sprintf('Filament returned: %sg — job #%d reopened',
                                            $job->filament_quantity, $job->id),
                    performed_by     => $who,
                );
                push @reversed, sprintf('returned %sg of filament', $job->filament_quantity);
            }

            # ---- 2. Reverse the finished-goods receipt (part back out of stock) ----
            # Mirror completion: prefer model.item_id (printed component), then source/consignment.
            my $printed_item_id;
            if ($job->model_id) {
                my $model = eval { $job->model };
                $printed_item_id = $model->item_id
                    if $model && eval { $model->item_id };
            }
            if (!$printed_item_id && $job->source_item_id) {
                $printed_item_id = $job->source_item_id;
            }
            if (!$printed_item_id && $job->consignment_line_id) {
                $printed_item_id = eval {
                    $schema->storage->dbh->selectrow_array(
                        'SELECT item_id FROM inventory_consignment_lines WHERE id = ?',
                        undef, $job->consignment_line_id)
                };
            }
            if ($printed_item_id) {
                # Mirror the completion handler: it received into the FIRST location
                # for this site. Reverse against the same location.
                my $default_loc = eval {
                    $schema->storage->dbh->selectrow_array(
                        'SELECT id FROM inventory_locations WHERE sitename = ? ORDER BY id LIMIT 1',
                        undef, $sitename)
                };
                if ($default_loc) {
                    $ctl->_inventory_transaction($c,
                        schema           => $schema,
                        sitename         => $sitename,
                        item_id          => $printed_item_id,
                        location_id      => $default_loc,
                        transaction_type => 'issue',
                        quantity         => $job->quantity || 1,
                        unit_cost        => $job->total_cost || undef,
                        reference_number => '3D-JOB-' . $job->id,
                        notes            => sprintf('Printed unit removed from stock — job #%d reopened',
                                                $job->id),
                        performed_by     => $who,
                    );
                    push @reversed, sprintf('removed %d printed unit(s) from stock',
                                        $job->quantity || 1);
                }
            }

            # ---- 3. Reset the job to queued and clear completion bookkeeping ----
            $job->update({
                status            => 'queued',
                completed_at      => undef,
                print_hours       => undef,
                filament_quantity => undef,
                filament_cost     => undef,
                printer_cost      => undef,
                electricity_cost  => undef,
                total_cost        => undef,
                inventory_reserved => 0,
                admin_notes       => (($job->admin_notes || '') =~ s/\s*$//r)
                                     . ($job->admin_notes ? "\n" : '')
                                     . sprintf('[%s] Reopened by %s (was %s)',
                                           Comserv::Util::AppTime->now_utc, $who, $st),
            });

            # ---- 4. Free the printer if it is still holding this job ----
            if ($job->printer_id) {
                my $printer = eval { $schema->resultset('Printing3dPrinter')
                                        ->find($job->printer_id) };
                if ($printer && ($printer->current_job_id // 0) == $job->id) {
                    $printer->update({
                        status         => 'idle',
                        current_job_id => undef,
                        updated_at     => Comserv::Util::AppTime->now_utc,
                    });
                    push @reversed, 'printer set back to idle';
                }
            }
        });
    }
    catch {
        $err = "$_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'reopen_job', "job ".$job->id." failed: $err");
    };
    return { ok => 0, error => $err } if $err;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'reopen_job',
        sprintf('Job #%d reopened by %s (was %s). Reversed: %s',
            $job->id, $who, $st, (@reversed ? join('; ', @reversed) : 'nothing')));

    return { ok => 1, job_id => $job->id, reversed => \@reversed };
}

__PACKAGE__->meta->make_immutable;
1;

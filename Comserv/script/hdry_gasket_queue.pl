#!/usr/bin/env perl
# Create printing_3d_models + queued jobs for HDRY TPU gaskets (sitename=3d).
# Light path via Model::RemoteDB (avoids full Catalyst boot / Inventory conflict markers).
# Run: cd Comserv && perl script/hdry_gasket_queue.pl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Model::RemoteDB;
use Comserv::Model::Schema::Ency;
use Comserv::Util::AppTime;

my $rdb  = Comserv::Model::RemoteDB->new;
my $info = $rdb->get_connection_info('ency');
my $conn = $info->{config} or die "no ency connection\n";
my $dsn  = "dbi:mysql:database=$conn->{database};host=$conn->{host};port=$conn->{port}";
my $schema = Comserv::Model::Schema::Ency->connect(
    $dsn, $conn->{username}, $conn->{password},
    { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 },
);

my $sitename = '3d';
my $username = 'Shanta';
my $user_id  = 178;
my $now      = Comserv::Util::AppTime->now_utc;
my $tpu_id   = 36;    # PM-TPU90
my $parent_base = 52; # INT-HDRY-001-P36787
my $nfs_dir  = '/data/nfs/3d/models/gasket';

my @parts = (
  { sku => 'INT-HDRY-GSK215',  qty => 10, stl => 'gasket_215_straight.stl',  name => 'TPU gasket 215 mm 3x3 (L1 vertical)', length => 215 },
  { sku => 'INT-HDRY-GSK150',  qty => 10, stl => 'gasket_150_straight.stl',  name => 'TPU gasket 150 mm 3x3 (L2 vertical)', length => 150 },
  { sku => 'INT-HDRY-GSK180',  qty => 3,  stl => 'gasket_180_straight.stl',  name => 'TPU gasket 180 mm 3x3 (cap loop)', length => 180 },
  { sku => 'INT-HDRY-GSK358',  qty => 2,  stl => 'gasket_358_coil.stl',      name => 'TPU gasket 358 mm 3x3 (door top/bot)', length => 358 },
  { sku => 'INT-HDRY-GSK378',  qty => 2,  stl => 'gasket_378_coil.stl',      name => 'TPU gasket 378 mm 3x3 (door side)', length => 378 },
  { sku => 'INT-HDRY-GSK1582', qty => 3,  stl => 'gasket_1582_coil.stl',     name => 'TPU gasket 1582 mm 3x3 (ring perimeter)', length => 1582 },
);

my $mrs = $schema->resultset('Printing3dModel');
my $jrs = $schema->resultset('Printing3dJob');
my $irs = $schema->resultset('Accounting::InventoryItem');

for my $p (@parts) {
    my $it = $irs->find({ sitename => $sitename, sku => $p->{sku} })
        or die "missing item $p->{sku}\n";
    $p->{item_id} = $it->id;
    if (($it->item_origin // '') ne '3d_printed') {
        $it->update({ item_origin => '3d_printed', category => '3D Print' });
    }

    my $path = "$nfs_dir/$p->{stl}";
    die "missing STL $path\n" unless -r $path;

    my $vol_cm3 = sprintf('%.4f', (3 * 3 * $p->{length}) / 1000.0);
    my $wt_g    = sprintf('%.3f', $vol_cm3 * 1.20);

    my $model = $mrs->search({ sitename => $sitename, item_id => $p->{item_id}, is_active => 1 })->first;
    if ($model) {
        $model->update({
            name            => $p->{name},
            description     => "HDRY TPU gasket 3x3 mm, length $p->{length} mm. NFS $path",
            nfs_path        => $path,
            file_type       => 'stl',
            tags            => 'project:hdry,gasket,tpu',
            source          => 'project_import',
            stl_volume_cm3  => $vol_cm3,
            stl_weight_g    => $wt_g,
        });
        print "MODEL update id=", $model->id, " $p->{sku}\n";
    } else {
        $model = $mrs->create({
            sitename        => $sitename,
            name            => $p->{name},
            description     => "HDRY TPU gasket 3x3 mm, length $p->{length} mm. NFS $path",
            nfs_path        => $path,
            file_type       => 'stl',
            tags            => 'project:hdry,gasket,tpu',
            source          => 'project_import',
            item_id         => $p->{item_id},
            added_by        => $username,
            is_active       => 1,
            created_at      => $now,
            stl_volume_cm3  => $vol_cm3,
            stl_weight_g    => $wt_g,
        });
        print "MODEL create id=", $model->id, " $p->{sku}\n";
    }

    my $existing = $jrs->search({
        sitename => $sitename,
        model_id => $model->id,
        status   => { -in => [qw(queued assigned printing)] },
    })->first;
    if ($existing) {
        print "JOB exists id=", $existing->id, " status=", $existing->status,
              " qty=", $existing->quantity, " $p->{sku}\n";
        next;
    }

    my $grams = sprintf('%.3f', $wt_g * $p->{qty});
    my $job = $jrs->create({
        sitename           => $sitename,
        model_id           => $model->id,
        source_type        => 'project',
        source_item_id     => $parent_base,
        item_name          => $p->{name},
        user_id            => $user_id,
        username           => $username,
        status             => 'queued',
        quantity           => $p->{qty},
        filament_item_id   => $tpu_id,
        filament_type      => 'TPU',
        filament_quantity  => $grams,
        notes              => "HDRY TPU gasket 3x3; length_mm=$p->{length}; CUTLIST hdry_work/gasket; filament=PM-TPU90",
        created_at         => $now,
        inventory_reserved => 0,
    });
    print "JOB create id=", $job->id, " qty=$p->{qty} $p->{sku} grams_est=$grams\n";
}

print "DONE\n";

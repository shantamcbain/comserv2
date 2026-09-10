#!/usr/bin/env perl
use strict;
use warnings;
use lib '/home/shanta/.comserv/worktrees/3d/Comserv/Comserv/lib';
use Comserv::Model::RemoteDB;
use DBI;
use JSON::PP;

my $sitename = '3d';
my $api_base = 'http://workstation.local:4003';
my $nfs_root = '/home/shanta/nfs/hdry_parts';

# Connect to DB via RemoteDB for model records (raw DBI bypasses DBIC column defaults)
my $remote  = Comserv::Model::RemoteDB->new();
my $info    = $remote->get_connection_info('ency');
my $conn    = $info->{config};
my $dsn     = "dbi:mysql:database=$conn->{database};host=$conn->{host};port=$conn->{port}";
my $dbh     = DBI->connect($dsn, $conn->{username}, $conn->{password} || '', { PrintError => 0, RaiseError => 0, AutoCommit => 1 })
    or die "DB connect: $DBI::errstr\n";

# Get existing SKUs
my %existing_sku_ids;
my $rows = $dbh->selectall_arrayref("SELECT sku, id FROM inventory_items WHERE sitename = ?", {}, $sitename);
for my $r (@$rows) {
    $existing_sku_ids{ uc($r->[0]) } = $r->[1];
}

my @items = (
    # [code, name, stl_file, module_dir, multi_plate]
    ['B01',               'Bottom Board 1',                'B01.stl',                            '023022_HDRY_System_V3__Module_1',           1],
    ['B02',               'Bottom Board 2',                'B02.stl',                            '023022_HDRY_System_V3__Module_1',           1],
    ['B03',               'Bottom Board 3',                'B03.stl',                            '023022_HDRY_System_V3__Module_1',           1],
    ['B04',               'Bottom Board 4',                'B04.stl',                            '023022_HDRY_System_V3__Module_1',           1],
    ['T01',               'Top Board 1',                   'T01.stl',                            '023022_HDRY_System_V3__Module_1',           1],
    ['T02',               'Top Board 2',                   'T02.stl',                            '023022_HDRY_System_V3__Module_1',           1],
    ['T03',               'Top Board 3',                   'T03.stl',                            '023022_HDRY_System_V3__Module_1',           1],
    ['T04',               'Top Board 4',                   'T04.stl',                            '023022_HDRY_System_V3__Module_1',           1],
    ['BOARD',             'Vertical Board',                'Board.stl',                          '023022_HDRY_System_V3__Module_1',           1],
    ['BOARD-CAP',         'Board Cap Closed',              'Board_Cap_Closed.stl',               '023022_HDRY_System_V3__Module_1',           1],
    ['CONNECTOR-CUP',     'Connector Cup',                 'Connector_Cup.stl',                  '023022_HDRY_System_V3__Module_1',           0],
    ['SMOOTH-CAP',        'Smooth Cap',                    'Smooth_Cap.stl',                     '023022_HDRY_System_V3__Module_1',           0],
    ['STEAM-CAP',         'Steam Cap (M1 only)',           'Steam_Cap.stl',                      '023022_HDRY_System_V3__Module_1',           0],
    ['BBR03',             'Bottom Back Right L3',          'BBR03.stl',                          '023022_HDRY_System_V3__Module_1',           0],
    ['BL03',              'Back Left L3',                  'BL03.stl',                           '023022_HDRY_System_V3__Module_1',           0],
    ['BR03',              'Back Right L3',                 'BR03.stl',                           '023022_HDRY_System_V3__Module_1',           0],
    ['FL03',              'Front Left L3',                 'FL03.stl',                           '023022_HDRY_System_V3__Module_1',           0],
    ['SBL01',             'Spool Bracket Left 1',          'SBL01__1_.stl',                      '023030_HDRY_System_V3__Module_2',           0],
    ['SBL02',             'Spool Bracket Left 2',          'SBL02__1_.stl',                      '023022_HDRY_System_V3__Module_1',           0],
    ['FEMALE-HINGE-L1',   'Female Hinge Left',             'Female_hinge_L1__1___1___1_.stl',   '023037_HDRY_System_V3__Doors',             0],
    ['FEMALE-HINGE-R1',   'Female Hinge Right',            'Female_hinge_R1__1___1___1_.stl',   '023037_HDRY_System_V3__Doors',             0],
    ['MALE-HINGE-L1',     'Male Hinge Left',               'Male_hinge_L1__1___1___1_.stl',     '023037_HDRY_System_V3__Doors',             0],
    ['MALE-HINGE-R1',     'Male Hinge Right',              'Male_hinge_R1__1___1___1_.stl',     '023037_HDRY_System_V3__Doors',             0],
    ['HINGE-LATCH-L1',    'Hinge Latch Left',              'Hinge_latch_L1__1___1___1_.stl',    '023037_HDRY_System_V3__Doors',             0],
    ['HINGE-LATCH-R1',    'Hinge Latch Right',             'Hinge_latch_R1__1___1___1_.stl',    '023037_HDRY_System_V3__Doors',             0],
    ['HANDLE',            'Door Handle',                   'Handle__2___1_.stl',                 '023037_HDRY_System_V3__Doors',             0],
    ['WINDOW',            'Window Shape',                  'Window_Shape.stl',                   '023037_HDRY_System_V3__Doors',             0],
    ['BACK-LH-DRAWER',    'Back Left Drawer',              'Back_LH_-_Drawer_2.0.stl',          '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['BACK-LH-HPV',       'Back Left HPV',                 'Back_LH_-_HPV.stl',                 '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['BACK-RH-DRAWER',    'Back Right Drawer',             'Back_RH_-_Drawer_2.0.stl',          '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['BACK-RH-HPV',       'Back Right HPV',                'Back_RH_-_HPV.stl',                 '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['DRYER-BASE',        'Dryer Base',                    'Base.stl',                           '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['CASE-1',            'Case 1',                        'Case_1.stl',                         '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['CASE-2',            'Case 2',                        'Case_2.stl',                         '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['CERCHIO',           'Cerchio',                       'Cerchio__1_.stl',                    '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['DRYER-CAP',         'Dryer CAP',                     'Dryer_CAP.stl',                      '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['DRYER-SUPPORT-LH',  'Dryer Support Left',            'Dryer_Support_LH.stl',               '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['DRYER-SUPPORT-RH',  'Dryer Support Right',           'Dryer_Support_RH.stl',               '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['FOOT',              'Dryer Foot',                    'Foot__1___1_.stl',                   '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['FRONT-LH',          'Front Left Panel',              'Front_LH.stl',                       '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['FRONT-RH',          'Front Right Panel',             'Front_RH.stl',                       '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['GOMMA',             'Gomma / Tire',                  'Gomma.stl',                          '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['HOLDER',            'Dryer Holder',                  'Holder.stl',                         '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['MAIN',              'Main Frame',                    'Main.stl',                           '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['PIPE',              'Pipe',                          'Pipe.stl',                           '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['WHEEL',             'Dryer Wheel',                   'Wheel.stl',                          '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['WHEEL-M',           'Dryer Motor Wheel',             'Wheel_M.stl',                        '023113_HDRY_System_V3__Dryer__Extras',     0],
    ['HYDRA-BDX-BAR',     'Hydra Roller Bar BDX',          'Hydra_Rollers_-_BDX_Bar.stl',       '110520_HDRY_System_V3__AMS__Hydra__Rollers', 0],
    ['HYDRA-BSX-BAR',     'Hydra Roller Bar BSX',          'Hydra_Rollers_-_BSX_Bar.stl',       '110520_HDRY_System_V3__AMS__Hydra__Rollers', 0],
    ['HYDRA-FDX-BAR',     'Hydra Roller Bar FDX',          'Hydra_Rollers_-_FDX_Bar.stl',       '110520_HDRY_System_V3__AMS__Hydra__Rollers', 0],
    ['HYDRA-FSX-BAR',     'Hydra Roller Bar FSX',          'Hydra_Rollers_-_FSX_Bar.stl',       '110520_HDRY_System_V3__AMS__Hydra__Rollers', 0],
    ['NMBR1',             'Number Tag 1',                  'NMBR1.stl',                          '110520_HDRY_System_V3__AMS__Hydra__Rollers', 0],
    ['NMBR2',             'Number Tag 2',                  'NMBR2.stl',                          '110520_HDRY_System_V3__AMS__Hydra__Rollers', 0],
    ['NMBR3',             'Number Tag 3',                  'NMBR3.stl',                          '110520_HDRY_System_V3__AMS__Hydra__Rollers', 0],
    ['NMBR4',             'Number Tag 4',                  'NMBR4.stl',                          '110520_HDRY_System_V3__AMS__Hydra__Rollers', 0],
    ['PTFE-BAR',          'PTFE Tube Bar',                 'PTFE_Tube_Bar_1-2__1_.stl',          '110520_HDRY_System_V3__AMS__Hydra__Rollers', 0],
    ['ROLLER-BAR-D3',     'Roller Bar D3',                 'Roller_Bar_D3__1_.stl',              '110520_HDRY_System_V3__AMS__Hydra__Rollers', 0],
    ['ROLLER-BAR-S2',     'Roller Bar S2',                 'Roller_Bar_S2__1_.stl',              '110520_HDRY_System_V3__AMS__Hydra__Rollers', 0],
    ['ROLLER',            'Roller Center',                 'Roller__1_.stl',                     '110520_HDRY_System_V3__AMS__Hydra__Rollers', 0],
);

my $now = time();
my $dt = scalar gmtime($now);
my $now_str = strftime('%Y-%m-%d %H:%M:%S', gmtime);
use POSIX qw(strftime);
$now_str = strftime('%Y-%m-%d %H:%M:%S', gmtime);

my ($created, $skipped, $errors) = (0, 0, 0);

for my $item (@items) {
    my ($code, $name, $stl_file, $mod_dir, $multi) = @$item;
    my $sku = "INT-HDRY-$code";
    my $desc = $name;
    $desc .= " (multi-plate)" if $multi;
    my $nfs_path = "$nfs_root/$mod_dir/$stl_file";

    unless (-f $nfs_path) {
        print STDERR "  WARN: STL not found: $nfs_path (will set nfs_path anyway)\n";
    }

    if ($existing_sku_ids{$sku}) {
        printf "  SKIP %-35s id=%d (exists)\n", $sku, $existing_sku_ids{$sku};
        $skipped++;
        next;
    }

    # Use raw SQL INSERT to bypass DBIC column default issues
    my $item_id;
    eval {
        $dbh->do(qq{
            INSERT INTO inventory_items
            (sitename, sku, name, description, item_origin, unit_of_measure, status, is_assemblable, hide_stock_count, show_in_shop, notes, created_by, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 'project:hdry', 'system', ?, ?)
        }, {}, $sitename, $sku, "$name ($code)", "HDRY $desc",
            '3d_printed', 'each', 'active', 0, $now_str, $now_str);
        $item_id = $dbh->last_insert_id(undef, undef, undef, undef);

        my ($ext) = $stl_file =~ /\.([^.]+)$/;
        $ext = lc($ext || 'stl');
        $dbh->do(qq{
            INSERT INTO printing_3d_models
            (sitename, name, description, nfs_path, file_type, tags, source, item_id, added_by, is_active, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
        }, {}, $sitename, "$name ($code)", "HDRY $desc",
            $nfs_path, $ext, 'project:hdry', 'filemanager', $item_id, 'system', $now_str);
    };
    if ($@) {
        print STDERR "  ERROR creating $sku: $@\n";
        $errors++;
    } else {
        printf "  CREATED %-35s id=%-4d STL=%-35s%s\n", $sku, $item_id, $stl_file, $multi ? ' ⭐' : '';
        $created++;
    }
}

print "\n--- SUMMARY ---\n";
print "Created: $created\n";
print "Skipped (exists): $skipped\n";
print "Errors: $errors\n";
$dbh->disconnect;
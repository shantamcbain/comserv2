use strict; use warnings; use lib 'lib', 't/lib';
use Test::More;
use File::Temp qw(tempdir);
use HKFake;
use Comserv::Util::HealthKitchen::Backup;
use Comserv::Util::HealthKitchen::RecipeSetup;
my $RS = 'Comserv::Util::HealthKitchen::RecipeSetup';
my $BK = 'Comserv::Util::HealthKitchen::Backup';

# --- Backup: private, atomic, symlink-refusing, no /tmp fallback
my $root = tempdir(CLEANUP => 1);
my $p = $BK->write('t_one', { a => 1 }, dir => "$root/backups");
ok -f $p, 'backup written';
is( ( stat "$root/backups" )[2] & 07777, 0700, 'dir 0700' );
is( ( stat $p )[2] & 07777, 0600, 'file 0600' );
ok !glob("$root/backups/.hkbk_*"), 'no temp left behind';
symlink "$root/backups", "$root/link" or die;
ok !eval { $BK->write('t_two', {}, dir => "$root/link"); 1 }, 'symlinked dir refused';
ok !eval { $BK->write('Bad Label', {}, dir => "$root/backups"); 1 }, 'bad label refused';
{ local $ENV{HOME}; ok !eval { $BK->dir; 1 }, 'no HOME -> die (no /tmp fallback)'; }
ok !eval { $BK->write('t_three', {}, dir => "$root/missing/backups"); 1 }, 'missing parent -> die';

# --- RecipeSetup
sub fresh {
  %HKFake::DB = (
    Recipe => [
      HKFake::Row->new(id => 1, name => 'Morning beverage', sitename => 'Shanta', username_of_poster => 'Shanta', _lines => [
        HKFake::Row->new(id => 51, sort_order => 1, name_raw => 'Ceylon cinnamon', inventory_item_id => 281),
        HKFake::Row->new(id => 52, sort_order => 2, name_raw => 'Turmeric', inventory_item_id => 282),
        HKFake::Row->new(id => 53, sort_order => 3, name_raw => 'Black Pepper', inventory_item_id => 1550),
        HKFake::Row->new(id => 54, sort_order => 4, name_raw => 'Chia Seed', inventory_item_id => 1551) ]),
      HKFake::Row->new(id => 9, name => 'Morning beverage', sitename => 'CSC', username_of_poster => 'Mallory', _lines => []),
    ],
    InventoryItem => [ HKFake::Row->new(id => 281, sitename => 'Shanta', net_weight_g => undef), HKFake::Row->new(id => 282, sitename => 'Shanta', net_weight_g => undef),
                       HKFake::Row->new(id => 283, sitename => 'CSC', net_weight_g => undef) ],
  );
  $HKFake::DB{lines} = [];
}
fresh();
my $c = HKFake::C->new(session => { user_id => 178, username => 'Shanta', SiteName => 'Shanta' });
$HKFake::WRITES = 0;
my $r = $RS->apply($c, backup_dir => "$root/backups");
ok $r->{ok}, 'apply ok';
ok -f $r->{backup} && ( ( stat $r->{backup} )[2] & 07777 ) == 0600, 'backup first, private';
my %l = map { $_->{name_raw} => $_ } @{ $HKFake::DB{Recipe}[0]{_lines} };
is_deeply [ map { $l{$_}{quantity} } 'Ceylon cinnamon', 'Turmeric', 'Chia Seed' ], [16, 16, 58], 'weighed grams';
is $l{'Ceylon cinnamon'}{unit}, 'g', 'unit g';
ok !defined $l{'Black Pepper'}{quantity} && $l{'Black Pepper'}{quantity_text} eq 'pinch', 'pepper pinch, no quantity (never deducted)';
my ($col) = grep { $_->{name_raw} eq 'Collagen' } @{ $HKFake::DB{RecipeLine} || [] };
ok $col && $col->{quantity} == 78 && $col->{recipe_id} == 1 && $col->{sort_order} == 5, 'collagen 78 g added';
my ($cof) = grep { $_->{name} eq 'Coffee' } @{ $HKFake::DB{Recipe} };
ok $cof && $cof->{sitename} eq 'Shanta' && $cof->{username_of_poster} eq 'Shanta', 'home Coffee recipe, owner+site';
my ($bean) = grep { $_->{name_raw} eq 'Coffee beans' } @{ $HKFake::DB{RecipeLine} };
is $bean->{quantity}, 112, '112 g beans';
is_deeply [ map { $_->{net_weight_g} } @{ $HKFake::DB{InventoryItem} } ], [56, 56, undef], 'net weights on own items only';
ok !@{ $r->{pending} }, 'nothing pending once column exists';

# idempotent: the collagen line now sits in RecipeLine table; add it to the recipe's lines
push @{ $HKFake::DB{Recipe}[0]{_lines} }, $col;
$HKFake::WRITES = 0;
$r = $RS->apply($c, backup_dir => "$root/backups");
ok $r->{ok} && !@{ $r->{changes} }, 'second apply: no changes';
is $HKFake::WRITES, 0, 'second apply wrote nothing';

# before Schema Compare: InventoryItem query fails -> net weights pending, rest applied
fresh();
local $HKFake::MISSING{InventoryItem} = 1;
$r = $RS->apply($c, backup_dir => "$root/backups");
ok $r->{ok}, 'apply ok without net_weight_g';
like $r->{pending}[0], qr/net_weight_g on items 281, 282: run Schema Compare/, 'net weight listed pending';
delete $HKFake::MISSING{InventoryItem};

# other owner: nothing found
fresh();
$c->{session}{username} = 'Mallory';
ok !$RS->apply($c, backup_dir => "$root/backups")->{ok}, "other owner can't apply to Shanta's recipe";
$c->{session}{username} = 'Shanta';

# backup failure aborts before any write
fresh(); $HKFake::WRITES = 0;
ok !eval { $RS->apply($c, backup_dir => "$root/link"); 1 }, 'backup failure aborts';
is $HKFake::WRITES, 0, 'no writes when backup fails';
done_testing;

#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use POSIX qw(strftime);

my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);

# Define the filaments with proper per-kg pricing
my @filaments = (
    { sku => 'MAT3D-NYLON-WHT',  name => 'Nylon White Filament 1kg',       brand => 'Mater3D', type => 'Nylon',  color => 'White',      cost_per_kg => 25.00 },
    { sku => 'MAT3D-PETG-BLU',   name => 'PET-G Blue Filament 1kg',        brand => 'Mater3D', type => 'PETG',  color => 'Blue',       cost_per_kg => 25.00 },
    { sku => 'MAT3D-PLA-YEL',    name => 'PLA Yellow Filament 1kg',         brand => 'Mater3D', type => 'PLA',   color => 'Yellow',     cost_per_kg => 20.00 },
    { sku => 'MAT3D-PLA-BLK',    name => 'PLA Black Filament 1kg',          brand => 'Mater3D', type => 'PLA',   color => 'Black',      cost_per_kg => 20.00 },
    { sku => 'MAT3D-PLA-RED',    name => 'PLA Red Filament 1kg',            brand => 'Mater3D', type => 'PLA',   color => 'Red',        cost_per_kg => 20.00 },
    { sku => 'MAT3D-PETG-RED',   name => 'PET-G Red Filament 1kg',          brand => 'Mater3D', type => 'PETG',  color => 'Red',        cost_per_kg => 25.00 },
    { sku => 'MAT3D-PETG-TRNBR', name => 'PET-G Transparent Brown Filament 1kg', brand => 'Mater3D', type => 'PETG', color => 'Transparent Brown', cost_per_kg => 25.00 },
    { sku => 'MAT3D-PLA-NTR',    name => 'PLA Neutral Filament 1kg',        brand => 'Mater3D', type => 'PLA',   color => 'Natural',    cost_per_kg => 20.00 },
    { sku => 'MAT3D-BAMB-CHBR',  name => 'PLA Bamboo Chocolate Brown Filament 1kg', brand => 'Mater3D', type => 'PLA', color => 'Chocolate Brown', cost_per_kg => 22.00 },
    { sku => 'MAT3D-BAMB-SLGR',  name => 'PLA Bamboo Slate Gray Filament 1kg', brand => 'Mater3D', type => 'PLA', color => 'Slate Gray', cost_per_kg => 22.00 },
    { sku => 'MAT3D-PLA-WD',     name => 'PLA Wood Filament 1kg',           brand => 'Mater3D', type => 'PLA',   color => 'Wood',       cost_per_kg => 25.00 },
    { sku => 'MAT3D-PETG-CLR',   name => 'PET-G Clear Filament 1kg',        brand => 'Mater3D', type => 'PETG',  color => 'Clear',      cost_per_kg => 28.00 },
    { sku => 'MAT3D-PLA-GRN',    name => 'PLA Green Filament 1kg',          brand => 'Mater3D', type => 'PLA',   color => 'Green',      cost_per_kg => 20.00 },
    { sku => 'MAT3D-BAMB-WHT',   name => 'Bamboo PLA White Filament 1kg',   brand => 'Mater3D', type => 'PLA',   color => 'White',      cost_per_kg => 22.00 },
    { sku => 'MAT3D-BAMB-BLU',   name => 'Bamboo PLA Blue Filament 1kg',    brand => 'Mater3D', type => 'PLA',   color => 'Blue',       cost_per_kg => 22.00 },
    { sku => 'MAT3D-PLA-SPGR',   name => 'PLA Space Gray Filament 1kg',     brand => 'Mater3D', type => 'PLA',   color => 'Space Gray', cost_per_kg => 20.00 },
    { sku => 'MAT3D-PLA-BRN',    name => 'PLA Brown Filament 1kg',          brand => 'Mater3D', type => 'PLA',   color => 'Brown',      cost_per_kg => 20.00 },
    { sku => 'MAT3D-PLA-GRY',    name => 'PLA Gray Filament 1kg',           brand => 'Mater3D', type => 'PLA',   color => 'Gray',       cost_per_kg => 20.00 },
    { sku => 'MAT3D-PLA-LTBR',   name => 'PLA Light Brown Filament 1kg',    brand => 'Mater3D', type => 'PLA',   color => 'Light Brown', cost_per_kg => 20.00 },
    { sku => 'PM-TPU90',         name => 'Polly Maker TPU90 Filament 1kg',  brand => 'Polymaker', type => 'TPU', color => 'Black',      cost_per_kg => 30.00 },
    { sku => 'KEXL-LTBR',        name => 'Kexcllish Light Brown Filament 1kg', brand => 'Kexcllish', type => 'PLA', color => 'Light Brown', cost_per_kg => 22.00 },
);

# Connect to the MySQL database
my $dsn = "DBI:mysql:database=ency;host=localhost";
my $dbh = DBI->connect($dsn, 'shanta', '', { RaiseError => 1, AutoCommit => 0 })
    or die "Cannot connect: $DBI::errstr";

# Check if we can find the password
# Try using the .my.cnf
my $password_file = '/home/shanta/storage/3d/coop/backup-11.15.2023_13-42-15_shanta/homedir/.my.cnf';
if (-f $password_file) {
    open my $fh, '<', $password_file or die "Can't open $password_file: $!";
    while (<$fh>) {
        chomp;
        if (/password=(\S+)/) {
            $dbh = DBI->connect($dsn, 'shanta', $1, { RaiseError => 1, AutoCommit => 0 });
            last;
        }
    }
    close $fh;
}

print "Connected to database.\n";

my $site = '3d';
my $by = 'system';
my $updated = 0;
my $skipped = 0;
my @log;

for my $f (@filaments) {
    my $unit_cost = sprintf('%.4f', $f->{cost_per_kg} / 1000);
    my $unit_price = sprintf('%.2f', $f->{cost_per_kg} * 1.5);
    my $desc = $f->{brand} . ' ' . $f->{name} . ' (cost: $' . $f->{cost_per_kg} . '/kg, $' . sprintf('%.2f', $f->{cost_per_kg} / 1000) . '/g)';
    
    # Check if exists
    my $exists = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM inventory_items WHERE sitename = ? AND sku = ?',
        undef, $site, $f->{sku}
    );
    
    if ($exists) {
        # Update existing
        $dbh->do(
            'UPDATE inventory_items SET unit_cost = ?, unit_price = ?, category = ?, unit_of_measure = ?, filament_type = ?, filament_color = ?, reorder_point = ?, reorder_quantity = ?, description = ?, updated_by = ? WHERE sitename = ? AND sku = ?',
            undef, $unit_cost, $unit_price, '3d_filament', 'g', $f->{type} || undef, $f->{color} || undef, 100, 500, $desc, $by, $site, $f->{sku}
        );
        push @log, "$f->{sku}: updated (unit_cost=$unit_cost, unit_price=$unit_price, type=$f->{type}, color=$f->{color})";
        $updated++;
    } else {
        # Insert new (this shouldn't happen since items already exist)
        push @log, "$f->{sku}: already exists (skipped)";
        $skipped++;
    }
}

$dbh->commit();
$dbh->disconnect();

print "\nSummary: $updated updated, $skipped skipped.\n";
print "Log:\n";
print "  $_\n" for @log;

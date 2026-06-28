#!/usr/bin/env perl
#
# migrate_legacy_menu_css.pl — One-time migration of legacy filesystem menu/CSS/theme data into DB
#
# Usage:
#   cd Comserv
#   perl script/migrate_legacy_menu_css.pl [--dry-run] [--verbose] [--force] [--sitename=Shanta]
#
# What it does:
#   1. Seeds SiteMenuOverride from %NAV_MENU_CATALOG (if no DB rows exist for site)
#   2. Migrates custom CSS from root/static/css/themes/*.css into user_preferences (site_custom_css_*)
#   3. Logs mode (legacy → DB) and volume status
#
use strict;
use warnings;
use Getopt::Long;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Comserv;
use Comserv::Controller::Navigation;
use File::Slurp;
use JSON qw(encode_json);

my ($dry_run, $verbose, $force, $sitename) = (0, 0, 0, 'default');
GetOptions(
    'dry-run'   => \$dry_run,
    'verbose'   => \$verbose,
    'force'     => \$force,
    'sitename=s'=> \$sitename,
) or die "Usage: $0 [--dry-run] [--verbose] [--force] [--sitename=NAME]\n";

my $c = Comserv->new;  # minimal catalyst context for models
my $nav = Comserv::Controller::Navigation->new;

print "=== Comserv Legacy → DB Migration ===\n";
print "Site: $sitename | Dry-run: $dry_run | Force: $force\n\n";

# 1. Menu migration
my $override_rs = $c->model('DBEncy')->resultset('SiteMenuOverride');
my $existing = $override_rs->search({ site_name => $sitename, is_included => 1 })->count;

if ($existing > 0 && !$force) {
    print "✓ DB menu already has $existing rows for '$sitename' — skipping menu seed (use --force to override)\n";
} else {
    print "→ Seeding DB menu from legacy catalog for '$sitename'...\n";
    my $pos = 10;
    my $seeded = 0;
    for my $entry (@{ $nav->nav_menu_catalog }) {
        next if $entry->{legacy};
        my $data = {
            site_name       => $sitename,
            stock_key       => 'legacy_' . $entry->{category},
            custom_category => $entry->{category},
            custom_submenu  => $entry->{label},
            sort_order      => $pos,
            is_included     => 1,
            created_by      => 'migrate_legacy_menu_css',
            notes           => 'Migrated from legacy NAV_MENU_CATALOG',
        };
        if ($dry_run) {
            print "  [dry] would create: $entry->{category}\n" if $verbose;
        } else {
            $override_rs->update_or_create($data);
            $seeded++;
        }
        $pos += 10;
    }
    print "✓ Seeded $seeded menu categories into DB\n";
}

# 2. CSS / Theme migration (example: take first custom theme file as site_custom_css)
my $theme_dir = "$Bin/../root/static/css/themes";
my $css_pref_key = "site_custom_css_$sitename";
my $pref_rs = $c->model('DBEncy')->resultset('UserPreference');

if (-d $theme_dir) {
    my @css_files = glob("$theme_dir/*.css");
    if (@css_files) {
        my $source = $css_files[0];  # pick first as example
        my $content = read_file($source);
        print "→ Found theme file: $source\n";
        if ($dry_run) {
            print "  [dry] would store " . length($content) . " bytes as $css_pref_key\n";
        } else {
            $pref_rs->update_or_create({
                user_id    => 0,
                pref_key   => $css_pref_key,
                pref_value => $content,
            });
            print "✓ Migrated custom CSS from $source into DB ($css_pref_key)\n";
        }
    } else {
        print "ℹ No .css files found in $theme_dir — nothing to migrate\n";
    }
} else {
    print "ℹ Theme directory $theme_dir does not exist\n";
}

print "\n=== Migration complete ===\n";
print "Run 'docker volume ls | grep comserv' on host to verify named volumes.\n";
print "After migration, set DB as single source and remove legacy filesystem reliance.\n";
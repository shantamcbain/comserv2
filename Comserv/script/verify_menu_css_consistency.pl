#!/usr/bin/env perl
#
# verify_menu_css_consistency.pl — Check DB-driven menu + CSS across environments
#
# Usage: perl script/verify_menu_css_consistency.pl [--sitename=Shanta] [--verbose]
#
use strict;
use warnings;
use Getopt::Long;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Comserv;

my ($sitename, $verbose) = ('default', 0);
GetOptions('sitename=s' => \$sitename, 'verbose' => \$verbose);

my $c = Comserv->new;
my $nav = Comserv::Controller::Navigation->new;

print "=== Comserv Menu + CSS Consistency Check ===\n";
print "Site: $sitename\n\n";

# 1. Menu source decision
my $has_db = $nav->_has_db_menu_data($c);
my $mode = $has_db ? 'DB-DRIVEN' : 'LEGACY (fallback)';
print "Menu Mode: $mode\n";
print "  DB rows (SiteMenuOverride): " . ($has_db ? 'YES' : 'NO') . "\n";

# 2. CSS source
my $css_key = "site_custom_css_$sitename";
my $pref = $c->model('DBEncy')->resultset('UserPreference')->find({
    user_id => 0, pref_key => $css_key
});
print "Custom CSS: " . ($pref ? 'DB (' . length($pref->pref_value) . ' bytes)' : 'NONE (using css.tt defaults)') . "\n";

# 3. Volume status (simple check)
my @paths = (
    '/opt/comserv/root/static',
    '/opt/comserv/root/LegacyStaticPages',
    '/opt/comserv/root/static/css/themes',
);
foreach my $p (@paths) {
    my $exists = -d $p ? 'OK' : 'MISSING';
    print "Volume path $p: $exists\n";
}

print "\n✓ Consistency check complete. Mode logged for debugging.\n";
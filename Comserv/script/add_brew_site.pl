#!/usr/bin/env perl
# Create Brew SiteName, map brew.computersystemconsulting.ca, enable brew addon module.
# Any brew.<parent-domain> hostname is also resolved via Site.pm SUBDOMAIN_SITE_PREFIX.
#
#   perl script/add_brew_site.pl
#   perl script/add_brew_site.pl --dry-run
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use JSON::MaybeXS qw(encode_json decode_json);
use File::Slurp qw(read_file write_file);
use DBI;

use Comserv::Model::RemoteDB;
use Catalyst::Utils;

my $dry_run = grep { $_ eq '--dry-run' } @ARGV;

sub say_dry { my ($msg) = @_; print $dry_run ? "[dry-run] $msg\n" : "$msg\n" }

my $conn = Comserv::Model::RemoteDB->new->get_connection('DBEncy')
    or die "Cannot get DBEncy connection (check secrets/dbi and RemoteDB config)\n";

my $dsn = "dbi:mysql:database=$conn->{database};host=$conn->{host};port=" . ($conn->{port} || 3306);
my $dbh  = DBI->connect($dsn, $conn->{username}, $conn->{password},
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 })
    or die "DB connect failed: $DBI::errstr\n";

say_dry "Connected to $conn->{database} on $conn->{host}";

my $site_name = 'Brew';
my $domain    = 'brew.computersystemconsulting.ca';

my ($site_id) = $dbh->selectrow_array('SELECT id FROM sites WHERE name = ?', undef, $site_name);

unless ($site_id) {
    say_dry "Creating site $site_name (home_view=Brew)";
    unless ($dry_run) {
        $dbh->do(q{
            INSERT INTO sites (
                name, description, affiliate, pid, auth_table, home_view, css_view_name,
                mail_from, mail_to, mail_to_discussion, mail_to_admin, mail_to_user, mail_to_client, mail_replyto,
                site_display_name, app_logo, app_logo_alt, app_logo_width, app_logo_height,
                document_root_url, link_target, image_root_url, http_header_description, http_header_keywords
            ) VALUES (
                ?, 'Brewhouse management', 0, 0, 'users', 'Brew', 'default',
                'helpdesk@computersystemconsulting.ca', 'helpdesk@computersystemconsulting.ca',
                'helpdesk@computersystemconsulting.ca', 'helpdesk@computersystemconsulting.ca',
                'helpdesk@computersystemconsulting.ca', 'helpdesk@computersystemconsulting.ca',
                'helpdesk@computersystemconsulting.ca',
                'Brew — Brewhouse', '/static/images/default_logo.png', 'Brew', 200, 100,
                '/', '_self', '/static/images/', 'Brew brewhouse', 'brew,brewhouse'
            )
        }, undef, $site_name);
        ($site_id) = $dbh->selectrow_array('SELECT id FROM sites WHERE name = ?', undef, $site_name);
    }
} else {
    say_dry "Site $site_name exists (id=$site_id)";
    unless ($dry_run) {
        $dbh->do('UPDATE sites SET home_view = ? WHERE id = ?', undef, 'Brew', $site_id);
    }
}

my ($has_domain) = $dry_run ? (0) : $dbh->selectrow_array(
    'SELECT id FROM sitedomain WHERE domain = ?', undef, $domain
);
if ($has_domain) {
    say_dry "OK (exists): $domain";
} else {
    say_dry "ADD sitedomain: $domain -> site_id $site_id";
    unless ($dry_run) {
        $dbh->do('INSERT INTO sitedomain (site_id, domain) VALUES (?, ?)', undef, $site_id, $domain);
    }
}

for my $mod (qw(brew accounting)) {
    my ($has_mod) = $dry_run ? (0) : $dbh->selectrow_array(
        'SELECT id FROM site_modules WHERE sitename = ? AND module_name = ?',
        undef, $site_name, $mod
    );
    if ($has_mod) {
        say_dry "OK site_modules: $mod";
    } else {
        say_dry "ADD site_modules: $site_name / $mod enabled=1";
        unless ($dry_run) {
            $dbh->do(
                'INSERT INTO site_modules (sitename, module_name, enabled) VALUES (?, ?, 1)',
                undef, $site_name, $mod
            );
        }
    }
}

unless ($dry_run) {
    my $theme_file = Catalyst::Utils::home('Comserv') . '/root/static/config/theme_definitions.json';
    if (-f $theme_file) {
        my $cfg = decode_json(read_file($theme_file));
        $cfg->{site_themes} ||= {};
        $cfg->{site_themes}{brew} = 'brew';
        $cfg->{themes}{brew} ||= {
            name        => 'Brew Theme',
            description => 'Brewhouse amber/brown palette',
            variables   => {
                'primary-color'    => '#6d4c41',
                'secondary-color'  => '#fff8e1',
                'accent-color'     => '#ff8f00',
                'background-color' => '#fafafa',
                'text-color'       => '#3e2723',
                'border-color'     => '#d7ccc8',
                'nav-bg'           => '#5d4037',
                'nav-text'         => '#ffffff',
                'link-color'       => '#e65100',
                'header-font'      => 'Verdana, Helvetica, sans-serif',
                'body-font'        => 'Verdana, Helvetica, sans-serif',
            },
        };
        write_file($theme_file, encode_json($cfg));
        say_dry "Updated theme_definitions.json";
    }
}

print "\nDone.\n";
print "  brew.computersystemconsulting.ca — explicit sitedomain\n";
print "  brew.<any-domain> — automatic (Site.pm prefix → Brew)\n";
print "  App: /brew (home_view Brew)\n";

# Seed the reusable Brew accounting/BOM/ingredient catalog (with sample prices) for the example site.
# This is the "accounting part which includes boms" template applied to the Brew demo.
# Recipes stay optional (real legacy data is browsable; new users choose what to import).
unless ($dry_run) {
    my $seed_script = "$Bin/seed_brew_catalog.pl";
    if (-x $seed_script || -f $seed_script) {
        print "\nSeeding Brew ingredient catalog + example BOM + prices for sitename=Brew...\n";
        system($^X, $seed_script, '--sitename', 'Brew') == 0
            or warn "seed_brew_catalog.pl exited non-zero (prices may still be partial)\n";
    } else {
        print "\n(Seed script not found at $seed_script — run manually: perl script/seed_brew_catalog.pl --sitename Brew)\n";
    }
} else {
    print "\n[dry-run] Would run: perl script/seed_brew_catalog.pl --sitename Brew\n";
}
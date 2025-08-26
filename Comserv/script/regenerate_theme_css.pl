#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Catalyst::Test 'Comserv';
use Comserv::Util::ThemeManager;

print "Regenerating theme CSS files...\n";

# Create a context object
my ($res, $c) = ctx_request('/');

# Create a ThemeManager instance
my $theme_manager = Comserv::Util::ThemeManager->new;

# Generate all theme CSS files
my $result = $theme_manager->generate_all_theme_css($c);

if ($result) {
    print "Theme CSS files regenerated successfully.\n";
} else {
    print "Error regenerating theme CSS files.\n";
}
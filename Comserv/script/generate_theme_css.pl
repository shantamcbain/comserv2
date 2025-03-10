#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Util::ThemeManager;
use Catalyst::Test 'Comserv';

# Initialize logging
use Comserv::Util::Logging;
Comserv::Util::Logging::init();

# Create a mock context
my $c = Catalyst::Test::get_context();

# Create a theme manager
my $theme_manager = Comserv::Util::ThemeManager->new;

# Generate CSS files for all themes
print "Generating CSS files for all themes...\n";
my $result = $theme_manager->generate_all_theme_css($c);

if ($result) {
    print "Successfully generated CSS files for all themes.\n";
} else {
    print "Error generating CSS files for all themes.\n";
}
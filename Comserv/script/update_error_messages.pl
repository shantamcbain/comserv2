#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

# Path to the Site.pm file
my $site_pm = "$FindBin::Bin/../lib/Comserv/Model/Site.pm";

# Read the file
open my $in, '<', $site_pm or die "Cannot open $site_pm for reading: $!";
my $content = do { local $/; <$in> };
close $in;

# Replace the error message with a link to the add_theme_column page
$content =~ s/The theme feature requires a database update\. Please run the add_theme_column\.pl script\./The theme feature requires a database update. <a href='\/admin\/add_theme_column'>Click here to add the theme column<\/a>./g;

# Write the updated content back to the file
open my $out, '>', $site_pm or die "Cannot open $site_pm for writing: $!";
print $out $content;
close $out;

print "Updated error messages in $site_pm\n";
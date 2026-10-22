#!/usr/bin/perl
use strict;
use warnings;

my $file_path = "../lib/Comserv/Controller/Inventory.pm";
my $content = "";

# Read the entire file
open(my $fh, "<", $file_path) or die "Cannot open $file_path: $!";
$content = <$fh>;
close($fh);

# Fix the Helpers section by adding the _sitename function
# Find the Helpers section header and the email_config method
if ($content =~ /# -------------------------------------------------------------------------\n# Helpers\n# -------------------------------------------------------------------------\n(\s*)# Email configuration action for the Inventory controller\nsub email_config :Path\(\'\/Inventory\/email-config\') :Args\(0\) {/) {
    my $indent = $1;
    # Replace with the fixed version
    $content =~ s/# -------------------------------------------------------------------------\n# Helpers\n# -------------------------------------------------------------------------\n(\s*)# Email configuration action for the Inventory controller\nsub email_config :Path\(\'\/Inventory\/email-config\') :Args\(0\) {/sub _sitename {\n$indent    my ($self, $c) = @_;\n$indent    return $c->session->{SiteName} || \'default\';\n$indent}\n\n$indent}# Email configuration action for the Inventory controller\nsub email_config :Path\(\'\/Inventory\/email-config\') :Args\(0\)/};
    
    # Write the fixed content back to the file
    open(my $out_fh, ">", $file_path) or die "Cannot write to $file_path: $!";
    print $out_fh $content;
    close($out_fh);
    
    print "File fixed successfully!\n";
} else {
    print "Could not find the pattern to fix in the file.\n";
    exit 1;
}

#!/usr/bin/perl
use strict;

my $file_path = "../lib/Comserv/Controller/Inventory.pm";
my $content = "";

# Read the file
open(my $fh, "<", $file_path) or die "Cannot open $file_path: $!";
$content = <$fh>;
close($fh);

# Fix the email navigation code in auto method
$content =~ s/my \$email_navigation = \$c->navigation;/my \$email_navigation = \$c->navigation;/;

# Fix the auto method - replace the email navigation code with simplified version
$content =~ s/if \(\$email_navigation\) {\n    \$email_navigation->add\(\{[^}]+\}\);\n}/# Email navigation setup moved to comserv_navigation plugin integration\n    # Email configuration navigation is automatically handled through Comserv's navigation system\n    # See Comserv::Util::ModelCatalog for navigation configuration\n    \$self->logging->log_with_details(\$c, 'info', __FILE__, __LINE__, 'auto',\n        'Email navigation setup deferred to Comserv navigation system');/;

# Add the missing helper functions
if ($content =~ /# -------------------------------------------------------------------------\n# Helpers\n# -------------------------------------------------------------------------\n(\s*)/) {
    my $indent = $1;
    $content =~ s/(# -------------------------------------------------------------------------\n# Helpers\n# -------------------------------------------------------------------------\n\s*)/\$1sub _sitename {\n\$indent    my (\$self, \$c) = @_;\n\$indent    return \$c->session->{SiteName} || '\''default'\'';\n}\n\n\$indentsub _schema {\n\$indent    my (\$self, \$c) = @_;\n\$indent    require Comserv::Util::ModelCatalog;\n\$indent    return Comserv::Util::ModelCatalog->get_model(\$c);\n};\n/;
}

# Write back to file
open(my $out_fh, ">", $file_path) or die "Cannot write to $file_path: $!";
print $out_fh $content;
close($out_fh);

print "File fixed successfully!\n";

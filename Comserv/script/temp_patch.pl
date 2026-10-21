#!/usr/bin/perl
use strict;

my $file_path = "../lib/Comserv/Controller/Inventory.pm";
my $content = "";

# Read the file
open(my $fh, "<", $file_path) or die "Cannot open $file_path: $!";
$content = <$fh>;
close($fh);

# Insert the _sitename and _schema helper functions
if ($content =~ /# -------------------------------------------------------------------------\n# Helpers\n# -------------------------------------------------------------------------\n/) {
    $content =~ s/(# -------------------------------------------------------------------------\n# Helpers\n# -------------------------------------------------------------------------\n)/(\$1sub _sitename {\n    my ($self, \$c) = @_;\n    return \$c->session->{SiteName} || '\''default'\'';\n}\n\nsub _schema {\n    my (\$self, \$c) = @_;\n    require Comserv::Util::ModelCatalog;\n    return Comserv::Util::ModelCatalog->get_model(\$c);\n})\n/;
    
    # Write back to file
    open(my $out_fh, ">", $file_path) or die "Cannot write to $file_path: $!";
    print $out_fh $content;
    close($out_fh);
    
    print "Helper functions added successfully!\n";
} else {
    print "Could not find Helpers section in file.\n";
    exit 1;
}

package Comserv::Util::SiteClone;

use strict;
use warnings;

# Staging workflow for migrating an existing website into the CSC page DB system.
# Full clone-from-URL automation is planned; Sunfire is the first manual migration.

sub migration_workflow_steps {
    return (
        'Applicant provides existing_site_url on hosting signup',
        'Admin provisions staging subdomain on the referring partner site',
        'Pages and theme seeded from source site (CSS → theme_definitions, content → page table)',
        'Site owner edits pages via Admin → Pages with AI assistance',
        'Admin attaches public domain; after DNS propagation the site goes live',
    );
}

# Build staging hostname: {sitename}.{parent_domain}
sub staging_hostname {
    my (%args) = @_;
    my $site   = lc( $args{sitename} // '' );
    my $parent = lc( $args{parent_domain} // '' );
    $site   =~ s/^\s+|\s+$//g;
    $parent =~ s/^\s+|\s+$//g;
    return '' unless $site && $parent;
    return "$site.$parent";
}

1;
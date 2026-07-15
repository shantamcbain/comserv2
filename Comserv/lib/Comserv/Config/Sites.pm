package Comserv::Config::Sites;

use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(get_site_db_connection);

=head1 NAME

Comserv::Config::Sites - Site-to-database connection mapping

=head1 SYNOPSIS

    use Comserv::Config::Sites qw(get_site_db_connection);
    my $cfg = get_site_db_connection('CSC');
    # Returns { db_name => 'ency', preferred_hosts => [...], server_group => 'prod01' }

=head1 DESCRIPTION

Maps site names (CSC, USBM, etc.) to their database configuration:
which database they use, which hosts to prefer, and which server group
the connections belong to. Extend by adding new entries to C<%SITE_DB_CONFIG>.

=cut

our %SITE_DB_CONFIG = (
    CSC   => { db_name => 'ency',   preferred_hosts => ['192.168.1.198', '172.30.161.222'], server_group => 'prod01' },
    USBM  => { db_name => 'ency',   preferred_hosts => ['192.168.1.198', '172.30.161.222'], server_group => 'prod01' },
    # Add new sites here in the future. Each entry can specify a different db_name,
    # different hosts, or a different server_group.
    # NOTE: db_name override is only needed when a site uses a non-standard database.
    # Site-specific overrides from the Site table take precedence at runtime.
);

=head2 get_site_db_connection

    my $cfg = get_site_db_connection($sitename);

Returns the config hashref for the given site name, or undef if the site
is not configured. The returned hashref has keys:

=over

=item * C<db_name> — the database field to match in connection configs

=item * C<preferred_hosts> — ordered list of host IPs to try (optional)

=item * C<server_group> — filter on the server_group field in secrets JSON (optional)

=back

=cut

sub get_site_db_connection {
    my ($sitename) = @_;
    return $SITE_DB_CONFIG{$sitename} || undef;
}

1;
package Comserv::Util::HostingAccount;

use strict;
use warnings;

# Strip scheme, path, port, and leading www. Returns lowercase hostname or ''.
sub normalize_hostname {
    my ($host) = @_;
    return '' unless defined $host && $host ne '';
    $host = lc $host;
    $host =~ s/^\s+|\s+$//g;
    $host =~ s{^https?://}{};
    $host =~ s{/.*$}{};
    $host =~ s/:\d+$//;
    $host =~ s/^www\.//;
    return $host;
}

# Build the public hostname for a hosting_accounts row.
# Signup often stores subdomain prefix in domain + parent in parent_domain.
sub resolve_hostname {
    my ($ha) = @_;
    return '' unless $ha;

    my $raw    = normalize_hostname( $ha->domain // '' );
    my $type   = lc( $ha->domain_type // 'subdomain' );
    my $parent = normalize_hostname( $ha->parent_domain // '' );
    my $site   = lc( $ha->sitename // '' );
    $site =~ s/^\s+|\s+$//g;

    if ( $type eq 'subdomain' ) {
        return $raw if $raw =~ /\./ && $raw ne '';
        if ( $parent ne '' ) {
            my $prefix = $raw ne '' ? $raw : $site;
            return "$prefix.$parent" if $prefix ne '';
        }
    }

    return $raw if $raw ne '';
    return '';
}

# True when hostname is a public DNS name (not .local, dev TLD, localhost, IP, or bare label).
sub is_public_dns_domain {
    my ($domain) = @_;
    $domain = normalize_hostname($domain);
    return 0 unless $domain ne '';
    return 0 unless $domain =~ /\./;
    return 0 if $domain eq 'localhost';
    return 0 if $domain =~ /^(?:\d{1,3}\.){3}\d{1,3}$/;
    return 0 if $domain =~ /^[0-9a-f:]+$/ && $domain =~ /:/;
    return 0 if $domain =~ /\.(?:local|test|dev|lan|zero|internal|localhost)$/;
    return 0 if $domain =~ /^(?:127|10|172\.(?:1[6-9]|2\d|3[01])|192\.168)\./;
    return 1;
}

sub public_url {
    my ($ha) = @_;
    my $host = resolve_hostname($ha);
    return '' unless $host && is_public_dns_domain($host);
    return "https://$host";
}

our @CSC_PARTNER_ROOTS = qw(
    computersystemconsulting.ca
    usbm.ca
    weaverbeck.com
    beemaster.ca
    forager.com
);

our @CSC_INFRA_PREFIXES = qw(dev zero workstation helpdesk);

# Public customer subdomain on a CSC partner root (not internal CSC infra).
sub is_csc_partner_public_host {
    my ($hostname) = @_;
    $hostname = normalize_hostname($hostname);
    return 0 unless is_public_dns_domain($hostname);
    for my $root (@CSC_PARTNER_ROOTS) {
        next unless $hostname =~ /\.\Q$root\E\z/;
        my ($prefix) = ( $hostname =~ /^([^.]+)\./ );
        return 0 if $prefix && grep { lc($prefix) eq $_ } @CSC_INFRA_PREFIXES;
        return 1;
    }
    return 0;
}

# Extract "Existing site URL: ..." from hosting_accounts.notes (signup / migration field).
sub extract_existing_site_url {
    my ($notes) = @_;
    return '' unless defined $notes && $notes ne '';
    if ($notes =~ /^Existing site URL:\s*(\S+)/m) {
        return $1;
    }
    if ($notes =~ /^Migrated from:\s*(\S+)/m) {
        return $1;
    }
    return '';
}

# Set or replace the existing-site URL line in notes.
sub merge_notes_with_existing_site_url {
    my ($notes, $url) = @_;
    $notes //= '';
    $url = '' unless defined $url;
    $url =~ s/^\s+|\s+$//g;
    my @lines = grep { $_ !~ /^(?:Existing site URL|Migrated from):/ } split /\n/, $notes;
    @lines = grep { $_ ne '' } @lines;
    if ($url ne '') {
        push @lines, "Existing site URL: $url";
    }
    return join("\n", @lines);
}

1;
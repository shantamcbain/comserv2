#!/usr/bin/perl
# mail_invoice_classify.pl - Classify mail messages as invoices
# Usage:
#   cd Comserv && perl script/mail_invoice_classify.pl
#   perl mail_invoice_classify.pl --source maildir

use strict;
use warnings;
use lib 'Comserv/lib';
use Comserv::Util::MailInvoiceClassifier;
use JSON;
use File::Spec;
use File::Path;
use Getopt::Long;
use Comserv::Util::Logging;

my $source = 'maildir';
my $first_run = 1;
my $output_file;
my $imap_server = 'localhost';
my $imap_port = 143;
my $imap_ssl = 0;
my $imap_user = 'shanta';
my $imap_pass = '';
my $dry_run = 0;
my $help = 0;

GetOptions(
    'source=s'    => \$source,
    'first-run'   => \$first_run,
    'output=s'    => \$output_file,
    'imap-server=s' => \$imap_server,
    'imap-port=i' => \$imap_port,
    'imap-ssl=i'  => \$imap_ssl,
    'imap-user=s' => \$imap_user,
    'imap-pass=s' => \$imap_pass,
    'dry-run'     => \$dry_run,
    'help'        => \$help,
) or die "Usage: $0 --help\n";

if ($help) {
    print <<HELP;
Mail Invoice Classifier
=======================
Scans mail messages and classifies them as invoices by category.

Usage: $0 [options]

Options:
  --source=s        Mail source: 'maildir' (default) or 'imap'
  --first-run       Force full rescan (overwrite existing JSON)
  --output=s        Output JSON file path
  --imap-server=s   IMAP server hostname (default: localhost)
  --imap-port=i     IMAP port (default: 143)
  --imap-ssl=i      Use SSL (0 or 1, default: 0)
  --imap-user=s     IMAP username (default: shanta)
  --imap-pass=s     IMAP password
  --dry-run         Show what would be done without writing files
  --help            Show this help message

Examples:
  cd Comserv && perl script/mail_invoice_classify.pl
  perl script/mail_invoice_classify.pl --source imap --imap-server 3d.local --imap-port 993 --imap-ssl 1
  perl script/mail_invoice_classify.pl --first-run --output /path/to/invoices.json

Output:
  Comserv/root/data/invoices/classified_invoices.json
  Categories: personal, csc_internet, hosting, domain, 3d_filament, hardware, other
HELP
    exit 0;
}

# Initialize classifier
my $classifier = Comserv::Util::MailInvoiceClassifier->new(
    output_dir => 'Comserv/root/data/invoices',
);

# Determine output file
my $outfile = $output_file || 'Comserv/root/data/invoices/classified_invoices.json';

if ($dry_run) {
    print "DRY RUN: Would scan mail from source=$source\n";
    print "DRY RUN: Output would be written to: $outfile\n";
    print "DRY RUN: First run: " . ($first_run ? 'yes' : 'no') . "\n";
    if ($source eq 'imap') {
        print "DRY RUN: IMAP server: $imap_server:$imap_port (SSL=$imap_ssl)\n";
    }
    exit 0;
}

# Run classification
my $result;
eval {
    $result = $classifier->classify_all_mail(
        source => $source,
        imap_server => $imap_server,
        imap_port => $imap_port,
        imap_ssl => $imap_ssl,
        imap_user => $imap_user,
        imap_pass => $imap_pass,
        output_file => $outfile,
        first_run => $first_run,
    );
};
if ($@) {
    print STDERR "ERROR: Classification failed: $@\n";
    exit 1;
}

# Print summary
my $meta = $result->{metadata};
print "Classification complete.\n";
print "  Source: $meta->{source}\n";
print "  Messages scanned: $meta->{total_messages_scanned}\n";
print "  First run: " . ($meta->{first_run} ? 'yes' : 'no') . "\n";
print "  Output: $outfile\n";
print "  Categories:\n";
foreach my $cat (keys %{$result->{categories}}) {
    my $c = $result->{categories}{$cat};
    print "    $cat (" . $c->{label} . "): " . $c->{count} . " messages\n";
}

# Write state file for daily runs
my $state_file = 'Comserv/root/data/invoices/last_classify_state.json';
my %state = (
    last_run => scalar(localtime),
    source => $source,
    total_scanned => $meta->{total_messages_scanned},
    last_output => $outfile,
);
open my $sfh, '>', $state_file or die "Cannot write $state_file: $!";
print $sfh JSON->new->utf8->pretty->encode(\%state);
close $sfh;

print "\nState saved to $state_file\n";

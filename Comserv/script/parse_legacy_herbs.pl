#!/usr/bin/env perl
#
# parse_legacy_herbs.pl
#
# Parses legacy ENCY .htm herb pages from LegacyStaticPages/ency/
# and seeds the ency_herb_tb table in shanta_forager database.
#
# Protocol: run with --dry-run first to review, then without to seed.
# Admin must have run schema compare to create ency_herb_tb before seeding.
#
# Usage:
#   perl parse_legacy_herbs.pl --dry-run
#   perl parse_legacy_herbs.pl --user=shanta_forager --password=SECRET
#   perl parse_legacy_herbs.pl --file=usbmNettle.htm --dry-run

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use DBI;
use File::Basename qw(basename);
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

my $host     = $ENV{DB_HOST}     || '192.168.1.198';
my $port     = $ENV{DB_PORT}     || 3306;
my $dbname   = $ENV{DB_NAME}     || 'shanta_forager';
my $user     = $ENV{DB_USER}     || 'shanta_forager';
my $pass     = $ENV{DB_PASS}     || '';
my $dry_run  = 0;
my $help     = 0;
my $single   = '';
my $legacy_dir;

GetOptions(
    'host=s'      => \$host,
    'port=i'      => \$port,
    'database=s'  => \$dbname,
    'user=s'      => \$user,
    'password=s'  => \$pass,
    'dry-run'     => \$dry_run,
    'file=s'      => \$single,
    'dir=s'       => \$legacy_dir,
    'help|h'      => \$help,
) or die "Usage: $0 [options]\n";

$legacy_dir ||= "$Bin/../root/LegacyStaticPages/ency";

if ($help) {
    print <<'HELP';
parse_legacy_herbs.pl - Seed ency_herb_tb from legacy .htm herb pages

Options:
  --host       DB host (default: 192.168.1.198)
  --port       DB port (default: 3306)
  --database   DB name (default: shanta_forager)
  --user       DB user
  --password   DB password
  --dry-run    Print parsed data without writing to DB
  --file=FILE  Process a single file only (basename, e.g. usbmNettle.htm)
  --dir=DIR    Override legacy pages directory
  --help       Show this help

HELP
    exit 0;
}

# Herb pages: named usbm*.htm files that are NOT formula pages (usbmf*.htm)
# and NOT index/structural pages
my @SKIP = qw(
    usbmformula.htm usbmherb.htm usbmgg.htm usbmhl.htm usbmhya.htm
    usbmpd.htm usbman.htm usbm9.htm
);
my %skip = map { lc($_) => 1 } @SKIP;

my @files;
if ($single) {
    @files = ("$legacy_dir/$single");
} else {
    opendir my $dh, $legacy_dir or die "Cannot open $legacy_dir: $!";
    @files = map  { "$legacy_dir/$_" }
             grep { /^usbm[^f]/i && /\.htm$/i && !$skip{ lc($_) } }
             readdir $dh;
    closedir $dh;
    @files = sort @files;
}

my $dbh;
unless ($dry_run) {
    $dbh = DBI->connect(
        "DBI:mysql:database=$dbname;host=$host;port=$port",
        $user, $pass,
        { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
    ) or die "DB connect failed: $DBI::errstr\n";
}

my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
my $inserted = 0;
my $skipped  = 0;

for my $file (@files) {
    my $fname = basename($file);
    my $herb  = parse_herb_file($file);

    unless ($herb->{botanical_name} || $herb->{common_names}) {
        warn "SKIP (no botanical/common name parsed): $fname\n";
        $skipped++;
        next;
    }

    if ($dry_run) {
        print "\n=== $fname ===\n";
        for my $k (sort keys %$herb) {
            my $v = $herb->{$k} // '';
            $v =~ s/\n/ | /g;
            print "  $k: $v\n" if $v;
        }
        next;
    }

    # Check for duplicate by botanical_name
    my ($exists) = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM ency_herb_tb WHERE botanical_name = ?',
        undef, $herb->{botanical_name} // ''
    );
    if ($exists) {
        warn "SKIP (already exists): $fname ($herb->{botanical_name})\n";
        $skipped++;
        next;
    }

    eval {
        $dbh->do(
            'INSERT INTO ency_herb_tb
            (botanical_name, key_name, common_names, parts_used, ident_character,
             stem, leaves, flowers, root, fruit, taste, odour,
             distribution, constituents, solvents, therapeutic_action,
             medical_uses, homiopathic, chinese, contra_indications,
             preparation, dosage, administration, formulas,
             vetrinary, non_med, culinary, cultivation, sister_plants,
             history, harvest, reference, url,
             username_of_poster, group_of_poster, date_time_posted, share, sitename)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            undef,
            $herb->{botanical_name}     // '',
            $herb->{key_name}           // '',
            $herb->{common_names}       // '',
            $herb->{parts_used}         // '',
            $herb->{ident_character}    // '',
            $herb->{stem}               // '',
            $herb->{leaves}             // '',
            $herb->{flowers}            // '',
            $herb->{root}               // '',
            $herb->{fruit}              // '',
            $herb->{taste}              // '',
            $herb->{odour}              // '',
            $herb->{distribution}       // '',
            $herb->{constituents}       // '',
            $herb->{solvents}           // '',
            $herb->{therapeutic_action} // '',
            $herb->{medical_uses}       // '',
            $herb->{homiopathic}        // '',
            $herb->{chinese}            // '',
            $herb->{contra_indications} // '',
            $herb->{preparation}        // '',
            $herb->{dosage}             // '',
            $herb->{administration}     // '',
            $herb->{formulas}           // '',
            $herb->{vetrinary}          // '',
            $herb->{non_med}            // '',
            $herb->{culinary}           // '',
            $herb->{cultivation}        // '',
            $herb->{sister_plants}      // '',
            $herb->{history}            // '',
            $herb->{harvest}            // '',
            $herb->{reference}          // '',
            "/ENCY/legacy/$fname",
            'legacy_import',
            'admin',
            $now,
            1,
            'ENCY',
        );
        print "INSERTED: $fname ($herb->{botanical_name})\n";
        $inserted++;
    };
    if ($@) {
        warn "ERROR inserting $fname: $@\n";
        $skipped++;
    }
}

if ($dry_run) {
    print "\n--- DRY RUN: " . scalar(@files) . " files parsed ($skipped skipped) ---\n";
} else {
    print "\nDone: $inserted inserted, $skipped skipped.\n";
    $dbh->disconnect;
}

# ─── Parser ────────────────────────────────────────────────────────────────────

sub parse_herb_file {
    my ($file) = @_;
    open my $fh, '<:encoding(iso-8859-1)', $file or do {
        warn "Cannot open $file: $!\n";
        return {};
    };
    my $html = do { local $/; <$fh> };
    close $fh;

    # Strip Wayback Machine wrapper scripts
    $html =~ s{<script[^>]*>.*?</script>}{}gsi;
    $html =~ s{<!-- End Wayback.*?-->}{}gsi;

    my %h;

    # Extract title for key_name fallback
    if ($html =~ m{<title>([^<]+)</title>}i) {
        my $title = strip_html($1);
        $h{key_name} = lc($title);
        $h{key_name} =~ s/[^a-z0-9_\s]//g;
        $h{key_name} =~ s/\s+/_/g;
        $h{key_name} = substr($h{key_name}, 0, 50);
    }

    # Main field extraction: <li><b>FIELD NAME:</b> value
    my @field_map = (
        [ qr/BOTANICAL\s+NAMES?/i,          'botanical_name'     ],
        [ qr/COMMON\s+NAMES?/i,             'common_names'       ],
        [ qr/PHARMACOPEIAL\s+NAMES?/i,      'comments'           ],
        [ qr/IDENTIFYING\s+CHAR/i,          'ident_character'    ],
        [ qr/DISTRIBUTION/i,                'distribution'       ],
        [ qr/PARTS?\s+USED/i,               'parts_used'         ],
        [ qr/BODY\s+PARTS?\s+AFFECTED/i,    'comments'           ],
        [ qr/CONSTITUENTS?/i,               'constituents'       ],
        [ qr/SOLVENTS?/i,                   'solvents'           ],
        [ qr/THERAPEUTIC\s+ACTION/i,        'therapeutic_action' ],
        [ qr/ASTROLOGICAL/i,                '_skip'              ],
        [ qr/NUMEROLOGICAL/i,               '_skip'              ],
        [ qr/MEDICAL\s+USES?/i,             'medical_uses'       ],
        [ qr/HOMEO?PATH/i,                  'homiopathic'        ],
        [ qr/CHINESE/i,                     'chinese'            ],
        [ qr/CONTRA.?INDICATION/i,          'contra_indications' ],
        [ qr/PREPARATION/i,                 'preparation'        ],
        [ qr/DOSAGE/i,                      'dosage'             ],
        [ qr/ADMINISTRATION/i,              'administration'     ],
        [ qr/NOTES?/i,                      'comments'           ],
        [ qr/FORMULAS?/i,                   'formulas'           ],
        [ qr/CONGENIAL\s+COMB/i,           'comments'           ],
        [ qr/VETERINARY/i,                  'vetrinary'          ],
        [ qr/NON\s+MEDICAL/i,               'non_med'            ],
        [ qr/CULINARY/i,                    'culinary'           ],
        [ qr/CULTIVATION/i,                 'cultivation'        ],
        [ qr/SISTER\s+PLANT/i,             'sister_plants'      ],
        [ qr/HISTORY/i,                     'history'            ],
        [ qr/HARVEST/i,                     'harvest'            ],
        [ qr/REFERENCE/i,                   'reference'          ],
        [ qr/BEE\s+PASTURE/i,              'apis'               ],
        [ qr/NECTAR/i,                      'nectar'             ],
        [ qr/POLLEN/i,                      'pollen'             ],
    );

    # Detect format: table-based (older pages) vs list-based (newer Dreamweaver pages)
    my $is_table_format = $html =~ m{<td>[^<]*BOTANICAL\s+NAMES?[^<]*</td>}si
                       || $html =~ m{<font[^>]*>\s*(?:<b>)?\s*BOTANICAL\s+NAMES?}si;

    if ($is_table_format) {
        # Table format: <tr><td>FIELD:</td><td>Value</td></tr>
        while ($html =~ m{<tr[^>]*>\s*<td[^>]*>\s*<font[^>]*>([^<]+)</font>\s*</td>\s*<td[^>]*>(.*?)</td>}gsi) {
            my ($label, $content) = ($1, $2);
            $label =~ s/^\s+|\s+$//g;
            $label =~ s/:$//;
            my $text = strip_html($content);
            $text =~ s/^&nbsp;//;
            $text =~ s/^\s+|\s+$//g;
            next unless $text;
            for my $rule (@field_map) {
                my ($pat, $field) = @$rule;
                next unless $label =~ $pat;
                next if $field eq '_skip';
                if ($field eq 'comments' && $h{comments}) {
                    $h{comments} .= "\n$label: $text";
                } elsif (!$h{$field}) {
                    $h{$field} = $text;
                }
                last;
            }
        }
        # Also try <tr><td>FIELD:</td><td>Value</td> without font tags
        while ($html =~ m{<tr[^>]*>\s*<td[^>]*>\s*([A-Z][A-Z\s\-/]+:)\s*</td>\s*<td[^>]*>(.*?)</td>}gsi) {
            my ($label, $content) = ($1, $2);
            $label =~ s/:\s*$//;
            $label =~ s/^\s+|\s+$//g;
            my $text = strip_html($content);
            $text =~ s/^&nbsp;//;
            $text =~ s/^\s+|\s+$//g;
            next unless $text;
            for my $rule (@field_map) {
                my ($pat, $field) = @$rule;
                next unless $label =~ $pat;
                next if $field eq '_skip';
                $h{$field} ||= $text;
                last;
            }
        }
        # 3-column table: label | spacer | value
        while ($html =~ m{<tr[^>]*>\s*<td[^>]*>\s*<font[^>]*>(?:<b>)?([^<]+)(?:</b>)?\s*</font>\s*</td>\s*<td[^>]*>\s*&nbsp;\s*</td>\s*<td[^>]*>(.*?)</td>}gsi) {
            my ($label, $content) = ($1, $2);
            $label =~ s/:\s*$//;
            $label =~ s/^\s+|\s+$//g;
            my $text = strip_html($content);
            $text =~ s/^[\s&nbsp;]+|[\s&nbsp;]+$//g;
            next unless $text;
            for my $rule (@field_map) {
                my ($pat, $field) = @$rule;
                next unless $label =~ $pat;
                next if $field eq '_skip';
                $h{$field} ||= $text;
                last;
            }
        }
        # Extract herb name from <h1> as fallback for botanical_name
        if (!$h{botanical_name} && $html =~ m{<h1[^>]*>([^<]+)</h1>}si) {
            my $h1 = strip_html($1);
            $h1 =~ s/^\s+|\s+$//g;
            # Match "Genus Species: Common name" or "Genus Species"
            if ($h1 =~ /^([A-Z][a-z]+\s+[A-Za-z]+)/) {
                $h{botanical_name} ||= $1;
            }
        }
    }

    # Parse list items with bold/strong field names
    while ($html =~ m{<li[^>]*>\s*<(?:b|strong)>\s*([^<:]+?)\s*:?\s*</(?:b|strong)>\s*(.*?)(?=<li[^>]*>\s*<(?:b|strong)>|</ul>|$)}gsi) {
        my ($label, $content) = ($1, $2);
        $label =~ s/^\s+|\s+$//g;

        for my $rule (@field_map) {
            my ($pat, $field) = @$rule;
            next unless $label =~ $pat;
            next if $field eq '_skip';
            my $text = extract_field_text($label, $content, $html);
            if ($field eq 'comments' && $h{comments}) {
                $h{comments} .= "\n$label: $text";
            } elsif (!$h{$field}) {
                $h{$field} = $text;
            }
            last;
        }
    }

    # Extract sub-fields from IDENTIFYING CHARACTERISTICS nested <ul>
    # Parse directly from HTML using <li> as delimiter to handle empty fields
    if ($html =~ m{<b>\s*IDENTIFYING\s+CHAR[^<]*</b>\s*(.*?)</ul>}si) {
        my $ic_block = $1;
        # Split on <li> tags to get individual sub-items
        my @items = split /<li>/i, $ic_block;
        my %sub_map = (
            qr/^\s*STEM:/i    => 'stem',
            qr/^\s*LEAVES?:/i => 'leaves',
            qr/^\s*FLOWERS?:/i=> 'flowers',
            qr/^\s*ROOT:/i    => 'root',
            qr/^\s*FRUIT:/i   => 'fruit',
            qr/^\s*TASTE:/i   => 'taste',
            qr/^\s*ODOU?R:/i  => 'odour',
        );
        for my $item (@items) {
            my $text = strip_html($item);
            $text =~ s/^\s+|\s+$//g;
            next unless $text;
            for my $pat (keys %sub_map) {
                if ($text =~ $pat) {
                    my $field = $sub_map{$pat};
                    (my $val = $text) =~ s/$pat\s*//i;
                    $val =~ s/^\s+|\s+$//g;
                    $h{$field} = $val if $val && !$h{$field};
                    last;
                }
            }
        }
    }

    # botanical_name: keep first name only if comma-separated list
    if ($h{botanical_name}) {
        $h{botanical_name} = strip_html($h{botanical_name});
        $h{botanical_name} =~ s/^\s+|\s+$//g;
        # Use the first listed name as canonical
        ($h{botanical_name}) = split /[;,\n]/, $h{botanical_name};
        $h{botanical_name} =~ s/^\s+|\s+$//g;
    }

    # key_name from botanical_name if we have one
    if ($h{botanical_name} && !$h{key_name}) {
        $h{key_name} = lc($h{botanical_name});
        $h{key_name} =~ s/[^a-z0-9\s]//g;
        $h{key_name} =~ s/\s+/_/g;
        $h{key_name} = substr($h{key_name}, 0, 50);
    }

    # Clean all text fields
    for my $k (keys %h) {
        next unless defined $h{$k};
        $h{$k} = strip_html($h{$k});
        $h{$k} =~ s/^\s+|\s+$//g;
        $h{$k} =~ s/\s{3,}/ /g;
        $h{$k} = '' unless $h{$k} =~ /\S/;
    }

    return \%h;
}

sub extract_field_text {
    my ($label, $content, $full_html) = @_;
    # For multi-line fields (DOSAGE, FORMULAS, etc.) grab inner <ul> lists too
    my $text = $content;
    $text =~ s/^\s+|\s+$//g;
    return strip_html($text);
}

sub strip_html {
    my ($html) = @_;
    return '' unless defined $html;
    $html =~ s/<[^>]+>//g;
    $html =~ s/&amp;/&/g;
    $html =~ s/&lt;/</g;
    $html =~ s/&gt;/>/g;
    $html =~ s/&nbsp;/ /g;
    $html =~ s/&#\d+;//g;
    $html =~ s/&[a-z]+;//g;
    $html =~ s/\s+/ /g;
    $html =~ s/^\s+|\s+$//g;
    return $html;
}

1;

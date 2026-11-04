#!/usr/bin/perl
# scan_credential_literals.pl — flag credential literals in a blob on stdin.
# Prints "rule<TAB>line" per hit and nothing else. Never prints the value.
# Covers the forms a copied DB password actually takes, which gitleaks's
# default rules miss because none of them name the field "password":
#   mysql/mariadb/mysqldump client -p flag with a quoted value (mysql-cli-password-flag)
#   DBI connect call, third argument a quoted token (dbi-connect-positional-password)
# A shell variable or a placeholder is not a literal and does not match.
# Do not put a quoted example of either form in this file: the rules above
# match it, and the commit is refused.
use strict;
use warnings;

while ( my $line = <STDIN> ) {
    my $n = $.;
    if ( $line =~ /\b(?:mysql|mariadb|mysqldump)\b[^|\n]{0,240}?-[pP](['"])([^\$'"]{6,})\1/i ) {
        print "mysql-cli-password-flag\t$n\n";
    }
    if ( $line =~ /DBI\s*->\s*connect\s*\(\s*(?:\$\w+|(['"])[^'"]*\1)\s*,\s*(?:\$\w+|(['"])[^'"]*\2)\s*,\s*(['"])[^'"\s\$\@%]{6,}\3/i ) {
        print "dbi-connect-positional-password\t$n\n";
    }
}
exit 0;

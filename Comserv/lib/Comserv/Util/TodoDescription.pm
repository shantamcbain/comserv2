package Comserv::Util::TodoDescription;

# Standard todo description layout (Nov 2026). One format used identically by the
# web form, bots and Chat with AI. Documented in
# root/Documentation/TodoDescriptionStandard.md.
#
#   ## What to do
#   <one or two sentences>
#
#   ## Steps
#   1. ...
#
#   ## How-to docs
#   - /Documentation/...
#
#   ## Form to complete
#   - /path/to/form
#
#   ## Done when
#   <acceptance check>

use strict;
use warnings;

our @SECTIONS = ('What to do', 'Steps', 'How-to docs', 'Form to complete', 'Done when');
our %KEY = ('What to do' => 'what', 'Steps' => 'steps', 'How-to docs' => 'docs',
            'Form to complete' => 'form', 'Done when' => 'done_when');

# Empty template (what the "Use standard layout" button inserts).
sub template { return render(undef) }

# render(what => str, steps => [..], docs => [..], form => [..] | str, done_when => str)
sub render {
    my ($class, %a) = @_;
    my @out;
    for my $title (@SECTIONS) {
        my $v = $a{ $KEY{$title} };
        my $body;
        if ($title eq 'Steps') {
            my @s = ref $v eq 'ARRAY' ? @$v : (defined $v && length $v ? ($v) : ());
            my $i = 0;
            $body = @s ? join("\n", map { ++$i . ". $_" } @s) : '1. ';
        } elsif ($title eq 'How-to docs' || $title eq 'Form to complete') {
            my @s = ref $v eq 'ARRAY' ? @$v : (defined $v && length $v ? ($v) : ());
            @s = grep { _app_link_ok($_) } @s;
            $body = @s ? join("\n", map { "- $_" } @s) : '- ';
        } else {
            $body = defined $v ? $v : '';
        }
        push @out, "## $title\n$body";
    }
    return join("\n\n", @out) . "\n";
}

# parse($text) -> { what, steps => [..], docs => [..], form => [..], done_when, standard => 0|1 }
sub parse {
    my ($class, $text) = @_;
    my %r = (steps => [], docs => [], form => [], standard => 0);
    return \%r unless defined $text;
    my $cur;
    my %buf;
    for my $line (split /\r?\n/, $text) {
        if ($line =~ /^##\s*(.+?)\s*$/ && $KEY{$1}) { $cur = $KEY{$1}; $buf{$cur} //= []; next }
        push @{ $buf{$cur} }, $line if $cur;
    }
    $r{standard} = (grep { exists $buf{$_} } qw(what steps)) == 2 ? 1 : 0;
    for my $k (qw(what done_when)) {
        my $t = join("\n", @{ $buf{$k} || [] }); $t =~ s/^\s+|\s+$//g; $r{$k} = $t;
    }
    for my $l (@{ $buf{steps} || [] }) { push @{ $r{steps} }, $1 if $l =~ /^\s*\d+[.)]\s*(\S.*)$/ }
    for my $k (qw(docs form)) {
        for my $l (@{ $buf{$k} || [] }) { push @{ $r{$k} }, $1 if $l =~ /^\s*[-*]\s*(\S.*)$/ }
    }
    return \%r;
}

# Links in the standard layout must be app paths (/...) or http(s) URLs to an app
# host; javascript:, data: and the like are dropped.
sub _app_link_ok {
    my ($v) = @_;
    return 0 unless defined $v && length $v;
    return 1 if $v =~ m{^/[^/\s]} || $v eq '/';
    return 1 if $v =~ m{^https?://[^\s"<>]+$};
    return 0 if $v =~ /^[a-z][a-z0-9+.-]*:/i;
    return 1;     # plain text (e.g. a doc title) is fine
}

1;

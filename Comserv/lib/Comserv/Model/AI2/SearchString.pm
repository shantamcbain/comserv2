package Comserv::Model::AI2::SearchString;

# Augments a raw user query with domain context for better web search results.
# Called by the 3d browse controller (and any inventory search surface) to
# get a search-engine-optimised query string.
#
# The 3d controller asks this aisystem module to create the search string,
# then passes it back to aisystem (_do_web_search) for execution.

use strict;
use warnings;
use Try::Tiny;
use Comserv::Util::Logging;

=head2 augment

  my $augmented = SearchString->augment(
      raw_query => 'dragon articulated',
      context   => '3d_model',
      tags      => 'fantasy toy',
      name      => 'Crystal Dragon',
  );

Returns an augmented query string like:
  "3d model STL printable Crystal Dragon dragon articulated fantasy toy"

Context options: 3d_model, inventory_item, general

=cut

sub augment {
    my ($class, %args) = @_;
    my $raw     = $args{raw_query} // '';
    my $context = $args{context}   // 'general';
    my $tags    = $args{tags}      // '';
    my $name    = $args{name}      // '';

    $raw =~ s/^\s+|\s+$//g;

    my @parts;

    # Domain prefix — ensures search engines understand we want 3D-printable models
    if ($context eq '3d_model') {
        push @parts, '3d model STL printable';
    }
    elsif ($context eq 'inventory_item') {
        push @parts, 'product item';
    }

    # Model name (most specific identifier) goes next
    if (length $name && $name ne $raw) {
        push @parts, $name;
    }

    # User's raw query
    push @parts, $raw if length $raw;

    # Tags for relevance
    if (length $tags) {
        my @tag_words = grep { length($_) > 1 } split(/\s*,\s*|\s+/, $tags);
        push @parts, @tag_words if @tag_words;
    }

    my $augmented = join(' ', @parts);
    $augmented =~ s/\s+/ /g;
    $augmented =~ s/^\s+|\s+$//g;

    return length($augmented) ? $augmented : $raw;
}

1;
package Comserv::Util::FocusRanking;

use strict;
use warnings;

=head1 NAME

Comserv::Util::FocusRanking - site-agnostic ranking + filter toolkit for todo lists.

=head1 WHY

The Focus Queue scoring and Role/Site/Project filtering were originally entangled in
C<Comserv::Controller::Planning> (the CSC planning page) and in client JS. That confined
the logic to one view. This module is the SHARED, SITE-AGNOSTIC home for both:

  * score_todo  - the computed importance score (delegates to TodoRanking)
  * passes_filters - pure Role/Site/Project predicate, mirrors the Focus Queue filter

Any controller (CSC planning, BMaster calendar, a future weather-aware view, etc.) calls
these with its own sitename / selected filters. No C<is_csc> gating lives here.

See project 240 TODOLIST-UI, Phase 5 / 5b / 6.

=cut

use parent qw(Exporter);
our @EXPORT_OK = qw(score_todo passes_filters);

# Scoring is owned by TodoRanking (single source of truth for ap_score).
use Comserv::Util::TodoRanking ();

# ----------------------------------------------------------------------------
# passes_filters( \%todo_attrs, \%filter_ctx )
#
# Pure, site-agnostic equivalent of the Focus Queue client filter
# (daily-plan.js applyAllFilters). Returns 1 if the todo should be visible,
# given the selected Role/Site/Project sets.
#
#   %todo_attrs = {
#       role_cats   => 'general,developer',   # comma-separated
#       sitename    => 'CSC',
#       project_id  => 235,
#   }
#   %filter_ctx = {
#       all_roles    => { general=>1, developer=>1, ... },  # every role the viewer can pick
#       checked_roles=> { developer=>1 },                    # roles the viewer selected
#       site_filtered=> 0|1,        # true when not all sites are selected
#       checked_sites=> { CSC=>1 },
#       proj_filtered=> 0|1,        # true when not all projects are selected
#       checked_projects=> { 235=>1, 240=>1 },
#   }
#
# Semantics (mirrors the JS):
#   - 'general' cards always show.
#   - a card role the viewer does NOT have in all_roles still shows (lenient).
#   - a card role the viewer has shows only if it is in checked_roles.
#   - site/project: shown when that dimension is not filtered, or the value is selected.
# ----------------------------------------------------------------------------
sub passes_filters {
    my ($t, $ctx) = @_;
    $t   //= {};
    $ctx //= {};

    # Role
    my $all_roles = $ctx->{all_roles} || {};
    my %checked   = %{ $ctx->{checked_roles} || {} };
    my $show_role = 1;
    my @crs = split /,/, ($t->{role_cats} // 'general');
    my $role_ok = 0;
    for my $cr (@crs) {
        $cr =~ s/^\s+|\s+$//g;
        next if $cr eq '';
        if ($cr eq 'general') { $role_ok = 1; last; }
        if (!exists $all_roles->{$cr}) { $role_ok = 1; last; }   # lenient: unknown role shows
        if ($checked{$cr}) { $role_ok = 1; last; }
    }
    $show_role = $role_ok;

    # Site
    my $show_site = 1;
    if ($ctx->{site_filtered}) {
        my $cs = $ctx->{checked_sites} || {};
        $show_site = $cs->{ $t->{sitename} // '' } ? 1 : 0;
    }

    # Project
    my $show_proj = 1;
    if ($ctx->{proj_filtered}) {
        my $cp = $ctx->{checked_projects} || {};
        $show_proj = $cp->{ $t->{project_id} // '' } ? 1 : 0;
    }

    return ($show_role && $show_site && $show_proj) ? 1 : 0;
}

# Re-export the scorer so callers import from one place.
sub score_todo {
    return Comserv::Util::TodoRanking::score_todo(@_);
}

1;

__END__

=head1 AUTHOR

Comserv2 planning system - project 240 TODOLIST-UI.

=head1 LICENSE

Same as Comserv2.

package Comserv::Util::Priority;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(priority_options priority_bands default_priority);

=head1 PRIORITY SCALE (1-10) — agreed 2026-08-01

Single source of truth for todo/project priority. Every dropdown renders from
C<priority_options>, so changing a label here changes it everywhere.

The scale bands work by TYPE of work, not just urgency:

  1     Blocker — security, data loss, site/system broken. Stop everything.
  2-3   Active development — committed to the current phase.
  4-5   Planned development — agreed but not yet scheduled.
  6-7   Data entry, verification, content work.
  8-9   Nice to have / someday.
  10    Recurring or routine (daily-plan entries, breaks, standing items).

Note on 10: it is NOT "wishlist" — the recurring daily-plan entries use it.
Wishlist/someday items belong at 8-9.

Do NOT default new todos to 1. See C<default_priority>.

=cut

sub priority_options {
    return {
        1  => 'P1: Blocker — security, data loss, or site down; stop everything',
        2  => 'P2: Active dev — committed to current phase, in flight',
        3  => 'P3: Active dev — committed to current phase, next up',
        4  => 'P4: Planned dev — agreed, awaiting scheduling',
        5  => 'P5: Planned dev — backlog, not yet scheduled',
        6  => 'P6: Data entry / verification — needed, routine effort',
        7  => 'P7: Data entry / content — address when capacity allows',
        8  => 'P8: Nice to have — no immediate impact',
        9  => 'P9: Someday / maybe',
        10 => 'P10: Recurring / routine — daily plan and standing items',
    };
}

=head2 priority_bands

Grouping used for reporting and bulk triage.

=cut

sub priority_bands {
    return {
        blocker      => [1],
        active_dev   => [2, 3],
        planned_dev  => [4, 5],
        data_entry   => [6, 7],
        someday      => [8, 9],
        recurring    => [10],
    };
}

=head2 default_priority

Default for newly created todos. Deliberately NOT 1 — defaulting to 1 is what
left 91% of the open backlog at priority 1 and made the field meaningless.
New work starts as planned development until someone judges otherwise.

=cut

sub default_priority { return 5 }

1;

package Comserv::Util::AppTime;
use strict;
use warnings;
use Carp qw(croak);

# =============================================================================
# Canonical application time (ONE system for the whole app)
#
# STORE: always UTC wall-clock as 'YYYY-MM-DD HH:MM:SS' (naive DATETIME, no Z).
# DISPLAY: convert that stored UTC value to the current user's timezone.
#
# Do not use bare localtime / strftime(localtime) / DateTime->now without a zone
# for timestamps that are written to the DB or shown to users. Call this module.
#
# Resolution order for user TZ (timezone_for):
#   1. $c->session->{timezone}
#   2. user preference key ui.timezone
#   3. user_schedule_settings.timezone for session username
#   4. $ENV{COMSERV_DEFAULT_USER_TZ} or site default America/Vancouver
#   5. UTC
# =============================================================================

our $VERSION = '1.00';

our $DEFAULT_USER_TZ = $ENV{COMSERV_DEFAULT_USER_TZ} || 'America/Vancouver';
our $STORAGE_TZ      = 'UTC';
our $DEFAULT_FMT     = '%Y-%m-%d %H:%M:%S';
our $DISPLAY_FMT     = '%Y-%m-%d %H:%M:%S %Z';

my $_dt_loaded;

sub _load_dt {
    return 1 if $_dt_loaded;
    require DateTime;
    require DateTime::TimeZone;
    $_dt_loaded = 1;
    return 1;
}

sub new { bless {}, shift }

# ---- write / storage --------------------------------------------------------

# UTC now as DATETIME string for DB columns (created_at, started_at, …).
sub now_utc {
    my ($class) = @_;
    _load_dt();
    return DateTime->now( time_zone => $STORAGE_TZ )->strftime($DEFAULT_FMT);
}

# Alias used by controllers replacing ad-hoc _now().
sub stamp { shift->now_utc }

# DateTime object in UTC (for arithmetic).
sub now_dt {
    my ($class) = @_;
    _load_dt();
    return DateTime->now( time_zone => $STORAGE_TZ );
}

# UTC time-of-day HH:MM:SS (log start_time/end_time storage).
sub now_hms_utc {
    my ($class) = @_;
    _load_dt();
    return DateTime->now( time_zone => $STORAGE_TZ )->hms;
}

# Short HH:MM in UTC (legacy log form defaults).
sub now_hm_utc {
    my ($class) = @_;
    my $hms = $class->now_hms_utc;
    return substr( $hms, 0, 5 );
}

# DateTime "now" in the viewer's zone (calendar math, "today" highlighting).
sub now_user_dt {
    my ( $class, $c ) = @_;
    _load_dt();
    my $tz = $class->timezone_for($c);
    return DateTime->now( time_zone => $tz );
}

# HH:MM:SS in viewer zone (UI defaults that should match wall clock).
sub now_user_hms {
    my ( $class, $c ) = @_;
    return $class->now_user_dt($c)->hms;
}

sub now_user_hm {
    my ( $class, $c ) = @_;
    return substr( $class->now_user_hms($c), 0, 5 );
}

# YYYY-MM-DD in viewer zone + N days (due-date defaults).
sub ymd_plus_days_for {
    my ( $class, $c, $days ) = @_;
    $days = 0 unless defined $days;
    return $class->now_user_dt($c)->clone->add( days => 0 + $days )->ymd;
}

# Convert wall-clock HH:MM[:SS] in the viewer's zone (on "today") to UTC HMS.
# Used when a form collects local time-of-day for TIME columns stored as UTC.
sub hms_user_to_utc {
    my ( $class, $c, $hms ) = @_;
    return $class->now_hms_utc unless defined $hms && length $hms;
    $hms =~ s/^\s+|\s+$//g;
    my ( $H, $M, $S ) = ( 0, 0, 0 );
    if ( $hms =~ /^(\d{1,2}):(\d{2})(?::(\d{2}))?/ ) {
        ( $H, $M, $S ) = ( 0 + $1, 0 + $2, 0 + ( $3 // 0 ) );
    }
    else {
        return $class->now_hms_utc;
    }
    _load_dt();
    my $tz = $class->timezone_for($c);
    my $local = DateTime->now( time_zone => $tz )->set(
        hour   => $H,
        minute => $M,
        second => $S,
        nanosecond => 0,
    );
    return $local->clone->set_time_zone($STORAGE_TZ)->hms;
}

# Convert stored UTC HMS back to viewer wall-clock HH:MM:SS for form display.
sub hms_utc_to_user {
    my ( $class, $c, $hms ) = @_;
    return '' unless defined $hms && length $hms;
    $hms =~ s/^\s+|\s+$//g;
    my ( $H, $M, $S ) = ( 0, 0, 0 );
    if ( $hms =~ /^(\d{1,2}):(\d{2})(?::(\d{2}))?/ ) {
        ( $H, $M, $S ) = ( 0 + $1, 0 + $2, 0 + ( $3 // 0 ) );
    }
    else {
        return "$hms";
    }
    _load_dt();
    my $tz = $class->timezone_for($c);
    my $utc = DateTime->now( time_zone => $STORAGE_TZ )->set(
        hour   => $H,
        minute => $M,
        second => $S,
        nanosecond => 0,
    );
    return $utc->clone->set_time_zone($tz)->hms;
}

# UTC calendar date YYYY-MM-DD (ticket numbers, UTC day buckets).
sub today_utc_ymd {
    my ($class) = @_;
    return substr( $class->now_utc, 0, 10 );
}

# Compact YYYYMMDD for ticket numbers etc.
sub today_utc_ymd_compact {
    my ($class) = @_;
    my $d = $class->today_utc_ymd;
    $d =~ s/-//g;
    return $d;
}

# Format an epoch second as UTC DATETIME string.
sub from_epoch_utc {
    my ( $class, $epoch ) = @_;
    return unless defined $epoch && $epoch =~ /^-?\d+(?:\.\d+)?$/;
    _load_dt();
    return DateTime->from_epoch( epoch => $epoch, time_zone => $STORAGE_TZ )
        ->strftime($DEFAULT_FMT);
}

# ---- parse stored values ----------------------------------------------------

# Treat a naive 'YYYY-MM-DD[ HH:MM:SS]' as UTC (canonical). Returns DateTime or undef.
# $opts->{assume_tz} — only for explicit legacy repair (do not use for normal reads).
sub parse_stored {
    my ( $class, $value, $opts ) = @_;
    return unless defined $value && length $value;
    return $value if ref $value && $value->isa('DateTime');

    $value =~ s/^\s+|\s+$//g;
    $value =~ s/T/ /;
    $value =~ s/Z$//i;
    $value =~ s/([+-]\d{2}:?\d{2})$//;    # drop offset if present; we re-zone below

    my ( $date, $time ) = split /\s+/, $value, 2;
    return unless $date && $date =~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my ( $y, $m, $d ) = ( $1, $2, $3 );
    $time ||= '00:00:00';
    my ( $H, $M, $S ) = ( 0, 0, 0 );
    if ( $time =~ /^(\d{1,2}):(\d{2})(?::(\d{2}))?/ ) {
        ( $H, $M, $S ) = ( $1, $2, $3 // 0 );
    }

    _load_dt();
    my $tz_name = ( $opts && $opts->{assume_tz} ) ? $opts->{assume_tz} : $STORAGE_TZ;
    my $dt;
    eval {
        $dt = DateTime->new(
            year       => $y,
            month      => $m,
            day        => $d,
            hour       => $H,
            minute     => $M,
            second     => $S,
            time_zone  => $tz_name,
        );
        $dt->set_time_zone($STORAGE_TZ) if $tz_name ne $STORAGE_TZ;
        1;
    } or return;
    return $dt;
}

# ---- user timezone ----------------------------------------------------------

sub is_valid_tz {
    my ( $class, $name ) = @_;
    return 0 unless defined $name && length $name;
    _load_dt();
    my $ok = eval { DateTime::TimeZone->new( name => $name ); 1 };
    return $ok ? 1 : 0;
}

sub normalize_tz {
    my ( $class, $name ) = @_;
    return $DEFAULT_USER_TZ unless defined $name && length $name;
    return $name if $class->is_valid_tz($name);
    # common aliases
    return 'America/Vancouver' if $name =~ /^(PT|PST|PDT|Pacific)$/i;
    return 'America/Los_Angeles' if $name =~ /^(US\/Pacific)$/i;
    return 'UTC' if $name =~ /^(UTC|GMT|Z)$/i;
    return $DEFAULT_USER_TZ;
}

# Resolve viewer timezone for this request (cached on stash).
sub timezone_for {
    my ( $class, $c ) = @_;
    return $DEFAULT_USER_TZ unless $c;

    if ( my $cached = $c->stash->{_app_time_tz} ) {
        return $cached;
    }

    my $tz;

    # 1. Session override (fast, settable without DB)
    if ( my $s = $c->session->{timezone} ) {
        $tz = $s if $class->is_valid_tz($s);
    }

    # 2. User preference ui.timezone
    if ( !$tz && $c->session->{user_id} ) {
        eval {
            require Comserv::Util::UserPreferences;
            my $pref = Comserv::Util::UserPreferences->new->get(
                $c, $c->session->{user_id}, 'ui.timezone'
            );
            $tz = $pref if defined $pref && $class->is_valid_tz($pref);
            1;
        };
    }

    # 3. Schedule settings row for this username
    if ( !$tz && ( my $user = $c->session->{username} ) ) {
        eval {
            my $schema = $c->model('DBEncy');
            my $row    = $schema->resultset('UserScheduleSettings')->search(
                { username => $user },
                { rows     => 1 }
            )->first;
            if ( $row && $row->timezone && $class->is_valid_tz( $row->timezone ) ) {
                $tz = $row->timezone;
            }
            1;
        };
    }

    $tz = $class->normalize_tz( $tz // $DEFAULT_USER_TZ );
    $c->stash->{_app_time_tz} = $tz;
    $c->stash->{user_timezone} = $tz;
    return $tz;
}

# User-local calendar date (planning "today").
sub today_ymd_for {
    my ( $class, $c ) = @_;
    _load_dt();
    my $tz = $class->timezone_for($c);
    return DateTime->now( time_zone => $tz )->ymd;
}

# ---- display ----------------------------------------------------------------

# Format a stored UTC value for the viewer.
# $fmt optional strftime; default includes %Z so the zone is visible.
sub format_for_display {
    my ( $class, $value, $tz_or_c, $fmt ) = @_;
    return '' unless defined $value && ( ref $value || length $value );

    my $tz;
    if ( ref $tz_or_c && eval { $tz_or_c->can('session') } ) {
        $tz = $class->timezone_for($tz_or_c);
    }
    else {
        $tz = $class->normalize_tz( $tz_or_c // $DEFAULT_USER_TZ );
    }
    $fmt ||= $DISPLAY_FMT;

    my $dt = $class->parse_stored($value);
    return '' unless $dt;

    eval {
        $dt = $dt->clone->set_time_zone($tz);
        1;
    } or do {
        # fall back to UTC string if TZ invalid mid-flight
        return $dt->strftime($DEFAULT_FMT) . ' UTC';
    };
    return $dt->strftime($fmt);
}

# Convenience: format using request context.
sub display {
    my ( $class, $c, $value, $fmt ) = @_;
    return $class->format_for_display( $value, $c, $fmt );
}

# Format "now" in user TZ (debug headers, footers).
sub now_display {
    my ( $class, $c, $fmt ) = @_;
    return $class->format_for_display( $class->now_utc, $c, $fmt );
}

# Elapsed hours between two stored UTC stamps (for print runtime).
sub hours_between {
    my ( $class, $start, $end ) = @_;
    my $a = $class->parse_stored($start) or return;
    my $b = $class->parse_stored( $end // $class->now_utc ) or return;
    my $secs = $b->epoch - $a->epoch;
    return sprintf( '%.2f', $secs / 3600 );
}

# Ensure stash has user_timezone for TT filters (call once per request from Root).
sub inject_request {
    my ( $class, $c ) = @_;
    return unless $c;
    my $tz = $class->timezone_for($c);
    $c->stash->{user_timezone}     = $tz;
    $c->stash->{app_time_storage}  = $STORAGE_TZ;
    $c->stash->{app_time_now_utc}  = $class->now_utc;
    $c->stash->{app_time_now_user} = $class->now_display( $c, $DISPLAY_FMT );
    return $tz;
}

1;

__END__

=head1 NAME

Comserv::Util::AppTime - single UTC storage + user-TZ display clock

=head1 SYNOPSIS

  use Comserv::Util::AppTime;

  # WRITE (always UTC)
  my $now = Comserv::Util::AppTime->now_utc;
  $row->update({ started_at => $now, completed_at => $now });

  # DISPLAY (user zone)
  my $shown = Comserv::Util::AppTime->display($c, $row->started_at);
  # TT: [% job.started_at | user_time %]

=head1 RULES

=over 4

=item * DB DATETIME columns hold UTC, no timezone suffix.

=item * Never strftime(localtime) for persisted stamps.

=item * "Today" for UI calendars = today_ymd_for($c), not DateTime->today.

=back

=cut

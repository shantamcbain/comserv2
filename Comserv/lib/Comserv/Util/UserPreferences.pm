package Comserv::Util::UserPreferences;

use strict;
use warnings;
use JSON qw(encode_json);
use Comserv::Util::Logging;

# Known keys — extend as new per-user settings are added.
our %ALLOWED_KEYS = (
    'calendar.site_colors'    => 'object',
    'calendar.fixed_lane_pct' => 'number',
    'ui.theme_override'       => 'string',
);

sub new { bless {}, shift }

sub logging { Comserv::Util::Logging->instance }

sub _schema {
    my ($self, $c) = @_;
    my $schema;
    eval { $schema = $c->model('DBEncy')->schema };
    return $schema;
}

sub table_available {
    my ($self, $c) = @_;
    my $schema = $self->_schema($c) or return 0;
    eval { $schema->source('UserPreference')->name; 1 } or return 0;
}

sub validate_value {
    my ($self, $key, $value) = @_;
    return 0 unless exists $ALLOWED_KEYS{$key};

    if ($key eq 'calendar.site_colors') {
        return 0 unless ref $value eq 'HASH';
        for my $site (keys %$value) {
            return 0 if length($site) > 64;
            return 0 unless ($value->{$site} // '') =~ /^#[0-9A-Fa-f]{6}$/;
        }
        return 1;
    }

    if ($key eq 'calendar.fixed_lane_pct') {
        my $n = $value;
        $n = 0 + $n if defined $n;
        return defined $n && $n >= 8 && $n <= 45;
    }

    if ($key eq 'ui.theme_override') {
        return 1 if !defined $value || $value eq '';
        return $value =~ /^[a-zA-Z0-9_-]{1,64}$/;
    }

    return 0;
}

sub get_all {
    my ($self, $c, $user_id) = @_;
    return {} unless $user_id;

    if (my $cached = $c->stash->{_user_prefs_cache}) {
        return $cached->{prefs} if ($cached->{uid} // '') eq $user_id;
    }

    my %prefs;
    return \%prefs unless $self->table_available($c);

    eval {
        my $schema = $self->_schema($c) or die "no schema\n";
        my $rs = $schema->resultset('UserPreference')->search(
            { user_id => $user_id },
            { order_by => 'pref_key' },
        );
        while (my $row = $rs->next) {
            $prefs{ $row->pref_key } = $row->decoded_value;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'get_all', "Could not load user preferences: $@");
    }

    $c->stash->{_user_prefs_cache} = { uid => $user_id, prefs => \%prefs };
    return \%prefs;
}

sub get {
    my ($self, $c, $user_id, $key) = @_;
    return unless $user_id && $key && exists $ALLOWED_KEYS{$key};
    my $all = $self->get_all($c, $user_id);
    return $all->{$key};
}

sub set_many {
    my ($self, $c, $user_id, $incoming) = @_;
    return { ok => 0, error => 'Login required' } unless $user_id;
    return { ok => 0, error => 'Invalid payload' }
        unless $incoming && ref $incoming eq 'HASH' && keys %$incoming;

    return { ok => 0, error => 'Preferences table not available — run schema compare' }
        unless $self->table_available($c);

    my @errors;
    my $schema = $self->_schema($c);
    my $rs     = $schema->resultset('UserPreference');

    eval {
        for my $key (sort keys %$incoming) {
            unless (exists $ALLOWED_KEYS{$key}) {
                push @errors, "Unknown preference: $key";
                next;
            }
            my $val = $incoming->{$key};

            if ($key eq 'ui.theme_override' && (!defined $val || $val eq '')) {
                $rs->search({ user_id => $user_id, pref_key => $key })->delete;
                next;
            }

            if ($key eq 'calendar.site_colors' && ref $val eq 'HASH' && !keys %$val) {
                $rs->search({ user_id => $user_id, pref_key => $key })->delete;
                next;
            }

            unless ($self->validate_value($key, $val)) {
                push @errors, "Invalid value for $key";
                next;
            }

            if ($key eq 'ui.theme_override') {
                my $themes = eval { $c->model('ThemeConfig')->get_all_themes($c) } || {};
                unless ($val eq 'default' || (ref $themes eq 'HASH' && exists $themes->{$val})) {
                    push @errors, "Unknown theme: $val";
                    next;
                }
            }

            my $row = $rs->find_or_create({ user_id => $user_id, pref_key => $key });
            $row->set_encoded_value($val);
            $row->update;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'set_many', "Failed saving user preferences: $@");
        return { ok => 0, error => 'Save failed' };
    }

    delete $c->stash->{_user_prefs_cache};
    my $prefs = $self->get_all($c, $user_id);

    return {
        ok     => @errors ? 0 : 1,
        prefs  => $prefs,
        errors => \@errors,
        ( @errors ? (error => join('; ', @errors)) : () ),
    };
}

1;
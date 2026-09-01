package Comserv::View::TT;
use Moose;
use namespace::autoclean;
use JSON::MaybeXS ();
use HTML::Entities qw(decode_entities encode_entities);
extends 'Catalyst::View::TT';

__PACKAGE__->config(
    TEMPLATE_EXTENSION => '.tt',
    render_die => 1,
    WRAPPER => 'layout.tt',
    PLUGIN_BASE => 'Template::Plugin',
    PLUGINS     => { DateTime => {} },
    ENCODING => 'UTF-8',
    FILTERS => {
        json => sub {
            my $val = shift;
            return JSON::MaybeXS->new(utf8 => 0, allow_nonref => 1)->encode($val);
        },
        js => sub {
            my $text = shift;
            $text =~ s/\\/\\\\/g;
            $text =~ s/'/\\'/g;
            $text =~ s/"/\\"/g;
            $text =~ s/\n/\\n/g;
            $text =~ s/\r/\\r/g;
            return $text;
        },
        ref_links => sub {
            my $text = shift;
            $text =~ s/\s*\[(?:ref\?)?\?\]\s*//g;
            $text =~ s/\s*\[\d+\]\s*//g;
            $text =~ s{&}{&amp;}g;
            $text =~ s{<}{&lt;}g;
            $text =~ s{>}{&gt;}g;
            return $text;
        },
        # Decode stored HTML entities, then escape for safe UTF-8 menu labels
        nav_label => sub {
            my $text = shift;
            return '' unless defined $text;
            $text = decode_entities($text);
            return encode_entities( $text, '<>&"' );
        },
        # Stored UTC DATETIME → viewer timezone (Comserv::Util::AppTime).
        # Usage: [% row.created_at | user_time %]
        # Optional format: [% row.created_at | user_time('%Y-%m-%d %H:%M') %]
        user_time => [
            sub {
                my ( $context, $fmt ) = @_;
                return sub {
                    my $val = shift;
                    return '' unless defined $val && length $val;
                    my $out;
                    eval {
                        require Comserv::Util::AppTime;
                        my $tz;
                        my $st = eval { $context->stash };
                        if ($st) {
                            $tz = eval { $st->get('user_timezone') } if $st->can('get');
                            $tz = $st->{user_timezone} if !defined $tz && ref $st eq 'HASH';
                        }
                        $tz ||= $Comserv::Util::AppTime::DEFAULT_USER_TZ || 'America/Vancouver';
                        $out = Comserv::Util::AppTime->format_for_display( $val, $tz, $fmt );
                        1;
                    } or return $val;
                    return defined $out ? $out : $val;
                };
            },
            1,
        ],
    },
);
# Register the format_time filter
$Template::Stash::SCALAR_OPS->{format_time} = sub {
    my $seconds = shift;
    my $hours = int($seconds / 3600);
    my $minutes = int(($seconds % 3600) / 60);
    return sprintf("%02d:%02d", $hours, $minutes);
};

# workstation-prod-local bind-mounts ./Comserv over /opt/comserv. Saving a .tt
# while TT compiles it produces: parse error / unexpected end of input.
# That is NOT a source defect (ai/index.tt is complete). Retry once after a
# short wait so the finished write is what we compile. Caller of the retry
# (this method) logs both outcomes — see _log_tt.
sub is_truncated_parse_error {
    my ($err) = @_;
    return 0 unless defined $err && length $err;
    return ($err =~ /parse error/i && $err =~ /unexpected end of input/i) ? 1 : 0;
}

sub _flush_template_cache {
    my ($self) = @_;
    eval {
        my $tt = $self->template;
        $tt->context->reset if $tt && $tt->can('context') && $tt->context;
    };
    return;
}

sub _log_tt {
    my ($c, $level, $line, $msg) = @_;
    # Helper: caller (render) already decided level/message. Logging itself
    # must not mask the render outcome — failures here are non-fatal.
    eval {
        require Comserv::Util::Logging;
        Comserv::Util::Logging->instance->log_with_details(
            $c, $level, __FILE__, $line, 'tt_render_retry', $msg
        );
    };
    return;
}

sub render {
    my ($self, $c, $template, $args) = @_;
    my $out = eval { $self->next::method($c, $template, $args) };
    my $err = $@;
    return $out unless $err;
    unless (is_truncated_parse_error("$err")) {
        die $err;
    }
    $self->_flush_template_cache;
    select(undef, undef, undef, 0.15);
    my $retry = eval { $self->next::method($c, $template, $args) };
    my $err2 = $@;
    if ($err2) {
        _log_tt($c, 'error', __LINE__,
            "Template parse retry failed for $template: $err2 (first: $err)");
        die $err2;
    }
    _log_tt($c, 'warning', __LINE__,
        "Recovered from truncated-template parse for $template");
    return $retry;
}

__PACKAGE__->meta->make_immutable(inline_constructor => 0);

1;

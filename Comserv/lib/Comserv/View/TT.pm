package Comserv::View::TT;
use Moose;
use namespace::autoclean;
extends 'Catalyst::View::TT';

__PACKAGE__->config(
    TEMPLATE_EXTENSION => '.tt',
    render_die => 1,
    WRAPPER => 'layout.tt',
    PLUGIN_BASE => 'Template::Plugin',
    PLUGINS     => { DateTime => {} },
    ENCODING => 'UTF-8',
    FILTERS => {
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
            $text =~ s{&}{&amp;}g;
            $text =~ s{<}{&lt;}g;
            $text =~ s{>}{&gt;}g;
            $text =~ s{\b(\d+)\b}{<a href="/ENCY/Reference/$1" title="Reference #$1" class="ency-ref-link">[$1]</a>}g;
            return $text;
        },
    },
);
# Register the format_time filter
$Template::Stash::SCALAR_OPS->{format_time} = sub {
    my $seconds = shift;
    my $hours = int($seconds / 3600);
    my $minutes = int(($seconds % 3600) / 60);
    return sprintf("%02d:%02d", $hours, $minutes);
};
__PACKAGE__->meta->make_immutable(inline_constructor => 0);

1;

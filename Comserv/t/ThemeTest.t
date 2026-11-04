#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use JSON::PP qw(decode_json);
use Test::More;

my $root = File::Spec->catdir($Bin, '..', 'root');
my $config_file = File::Spec->catfile(
    $root, 'static', 'config', 'theme_definitions.json'
);
my $css_dir = File::Spec->catdir($root, 'static', 'css', 'themes');

ok(-f $config_file, 'canonical theme definitions exist');
my $config = decode_json(do {
    open my $fh, '<', $config_file or die "Cannot read $config_file: $!";
    local $/;
    <$fh>;
});

ok(ref $config->{themes} eq 'HASH', 'canonical definitions contain themes');
my $themes = $config->{themes} || {};

for my $theme_name (sort keys %$themes) {
    my $css_file = File::Spec->catfile($css_dir, "$theme_name.css");
    ok(-f $css_file, "$theme_name has generated CSS");
    next unless -f $css_file;

    open my $fh, '<', $css_file or die "Cannot read $css_file: $!";
    local $/;
    my $css = <$fh>;
    my ($root_block) = $css =~ /:root\s*\{(.*?)\}/s;
    ok(defined $root_block, "$theme_name CSS has a :root block");
    next unless defined $root_block;

    my %css_variables = map {
        my ($name, $value) = /^\s*--([^:]+):\s*(.*?);\s*$/
            or ();
        defined $name ? ($name => $value) : ()
    } split /\n/, $root_block;

    for my $variable (sort keys %{ $themes->{$theme_name}{variables} || {} }) {
        is(
            $css_variables{$variable},
            $themes->{$theme_name}{variables}{$variable},
            "$theme_name preserves canonical --$variable"
        );
    }
}

done_testing();

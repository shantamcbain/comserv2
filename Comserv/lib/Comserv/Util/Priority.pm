package Comserv::Util::Priority;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(priority_options);

sub priority_options {
    return {
        1  => 'P1: Critical — system/site broken, stop everything',
        2  => 'P2: Urgent — blocking key work, must resolve today',
        3  => 'P3: High — important, complete this sprint',
        4  => 'P4: Above Normal — scheduled soon, next sprint',
        5  => 'P5: Medium — standard backlog item',
        6  => 'P6: Normal — background work, no deadline pressure',
        7  => 'P7: Low — address when capacity allows',
        8  => 'P8: Minor — nice to have, no immediate impact',
        9  => 'P9: Minimal — someday/maybe',
        10 => 'P10: Optional — wishlist only',
    };
}

1;

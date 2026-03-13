package Comserv::Util::CSRF;

use strict;
use warnings;

sub generate_token  { return '' }
sub ensure_token    { return '' }
sub validate_token  { return wantarray ? (1, 'ok') : 1 }

1;

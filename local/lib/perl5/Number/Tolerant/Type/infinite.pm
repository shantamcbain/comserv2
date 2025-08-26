use strict;
use warnings;
# ABSTRACT: an infinite tolerance

package
  Number::Tolerant::Type::infinite;
use parent qw(Number::Tolerant::Type);

sub construct { shift; { value => 0 } }

sub parse {
  my ($self, $string, $factory) = @_;
  return $factory->new('infinite') if $string =~ m!\Aany\s+number\z!;
  return;
}

sub valid_args { shift;
  return ($_[0]) if @_ == 1 and defined $_[0] and $_[0] eq 'infinite';
  return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Number::Tolerant::Type::infinite - an infinite tolerance

=head1 VERSION

version 1.710

=head1 PERL VERSION

This library should run on perls released even a long time ago.  It should work
on any version of perl released in the last five years.

Although it may work on older versions of perl, no guarantee is made that the
minimum required version will not be increased.  The version may be increased
for any reason, and there is no promise that patches will be accepted to lower
the minimum required perl.

=head1 AUTHOR

Ricardo Signes <cpan@semiotic.systems>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2004 by Ricardo Signes.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

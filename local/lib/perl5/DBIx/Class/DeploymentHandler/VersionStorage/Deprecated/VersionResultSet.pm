package DBIx::Class::DeploymentHandler::VersionStorage::Deprecated::VersionResultSet;
$DBIx::Class::DeploymentHandler::VersionStorage::Deprecated::VersionResultSet::VERSION = '0.002234';
# ABSTRACT: (DEPRECATED) Predefined searches to find what you want from the version storage

use strict;
use warnings;

use parent 'DBIx::Class::ResultSet';

use Try::Tiny;
use Time::HiRes 'gettimeofday';

sub version_storage_is_installed {
  my $self = shift;
  try { $self->count; 1 } catch { undef }
}

sub database_version {
  my $self = shift;
  $self->search(undef, {
    order_by => { -desc => 'installed' },
    rows => 1
  })->get_column('version')->next;
}

# this is why it's deprecated guys... Serially.
sub create {
  my $self = shift;
  my $args = shift;

  my @tm = gettimeofday();
  my @dt = gmtime ($tm[0]);

  $self->next::method({
    %{$args},
    installed => sprintf("v%04d%02d%02d_%02d%02d%02d.%03.0f",
      $dt[5] + 1900,
      $dt[4] + 1,
      $dt[3],
      $dt[2],
      $dt[1],
      $dt[0],
      $tm[1] / 1000, # convert to millisecs, format as up/down rounded int above
    ),
  });
}

1;

# vim: ts=2 sw=2 expandtab

__END__

=pod

=head1 NAME

DBIx::Class::DeploymentHandler::VersionStorage::Deprecated::VersionResultSet - (DEPRECATED) Predefined searches to find what you want from the version storage

=head1 DEPRECATED

This component has been suplanted by
L<DBIx::Class::DeploymentHandler::VersionStorage::Standard::VersionResultSet>.
In the next major version (1) we will begin issuing a warning on it's use.
In the major version after that (2) we will remove it entirely.

=head1 METHODS

=head2 version_storage_is_installed

True if (!!!) the version storage has been installed

=head2 database_version

The version of the database

=head2 create

Overridden to default C<installed> to the current time. (take a look, it's yucky)

=head1 AUTHOR

Arthur Axel "fREW" Schmidt <frioux+cpan@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2024 by Arthur Axel "fREW" Schmidt.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

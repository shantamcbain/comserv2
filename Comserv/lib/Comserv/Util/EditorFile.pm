package Comserv::Util::EditorFile;

use strict;
use warnings;
use namespace::autoclean;
use File::Copy qw(copy);
use File::Temp qw(tempfile);

=head1 NAME

Comserv::Util::EditorFile - Shared file read/write with backup and validation

=head1 SYNOPSIS

    use Comserv::Util::EditorFile;

    my $ef = Comserv::Util::EditorFile->new($c);

    # Read a file
    my $result = $ef->read_file($c, 'lib/Comserv/Controller/AI2.pm');
    if ($result->{content}) {
        print $result->{content};
        print "mtime: $result->{mtime}";
    } else {
        print "Error: $result->{error}";
    }

    # Write a file (with backup + perl -c validation)
    my $result = $ef->write_file($c, 'lib/Comserv/Controller/AI2.pm', $new_content);
    if ($result->{success}) {
        print "Written to $result->{path}";
    } else {
        print "Error: $result->{error}";
    }

=head1 METHODS

=head2 new

    my $ef = Comserv::Util::EditorFile->new($c);

Constructor.  Accepts a Catalyst context object and resolves the project root
via C<< $c->path_to('') >>.

=cut

sub new {
    my ($class, $c) = @_;
    my $root = $c->path_to('');
    bless {
        root => "$root",
        c    => $c,
    }, $class;
}

=head2 root

Returns the project root path as a string.

=cut

sub root {
    my $self = shift;
    return $self->{root};
}

# ---------------------------------------------------------------------------
# Internal: resolve a relative path to an absolute path under the project root
# ---------------------------------------------------------------------------
sub _resolve_path {
    my ($self, $rel_path) = @_;
    return "$self->{root}/$rel_path";
}

# ---------------------------------------------------------------------------
# Internal: check that the resolved path is under the project root
# ---------------------------------------------------------------------------
sub _path_allowed {
    my ($self, $full) = @_;
    return $full =~ /^\Q$self->{root}\E/;
}

=head2 read_file

    my $result = $ef->read_file($c, $rel_path);

Reads a file relative to the project root.  Returns a hashref:

On success: C<< { path => $full_path, content => $content, mtime => $epoch } >>
On failure: C<< { error => 'reason' } >>

Security: rejects paths that resolve outside the project root.
B<Note:> The C<$c> parameter is passed for consistency with C<write_file>
and to allow future logging hooks; it is not currently used for reading.

=cut

sub read_file {
    my ($self, $c, $rel_path) = @_;

    my $full = $self->_resolve_path($rel_path);

    # Security: must be inside project root
    unless ($self->_path_allowed($full)) {
        return { error => 'Forbidden' };
    }

    unless (-e $full) {
        return { error => 'Not found' };
    }

    my $content;
    eval {
        open my $fh, '<:utf8', $full or die "open: $!";
        local $/;
        $content = <$fh>;
        close $fh;
        1;
    } or do {
        my $err = $@ || 'Unknown error';
        return { error => "Read failed: $err" };
    };

    my $mtime = (stat($full))[9];

    return {
        path    => $full,
        content => $content,
        mtime   => $mtime,
    };
}

=head2 write_file

    my $result = $ef->write_file($c, $rel_path, $content);

Writes a file relative to the project root.  Performs these steps:

1. Security check — path must be under project root
2. Backup — copies the existing file to C<.bak> (single-rotation: old .bak is
   deleted before creating the new one)
3. Perl syntax validation — for C<.pm> and C<.pl> files, runs C<perl -c>
   against a temp file and rejects on failure
4. Write — writes the file with UTF-8 encoding

Returns a hashref:

On success: C<< { success => 1, path => $full_path, mtime => $epoch } >>
On failure: C<< { success => 0, error => 'reason', detail => $detail, hint => $hint } >>

=cut

sub write_file {
    my ($self, $c, $rel_path, $content) = @_;

    my $full = $self->_resolve_path($rel_path);

    # Security: must be inside project root
    unless ($self->_path_allowed($full)) {
        return { success => 0, error => 'Forbidden' };
    }

    unless (defined $content) {
        return { success => 0, error => 'No content provided' };
    }

    # Backup the existing file before overwriting (single-rotation)
    if (-f $full) {
        my $bak = "$full.bak";
        unlink $bak if -f $bak;
        eval { copy($full, $bak); 1; };
    }

    # Validate Perl syntax before writing .pm / .pl files
    if ($rel_path =~ /\.(pm|pl)$/i) {
        my ($tmp_fh, $tmp_path) = tempfile(
            SUFFIX => '.pl',
            UNLINK => 1,
        );
        print $tmp_fh $content;
        close $tmp_fh;

        my $validate = `perl -c -I "$self->{root}/lib" "$tmp_path" 2>&1`;
        if ($? != 0) {
            return {
                success => 0,
                error   => 'Syntax error',
                detail  => $validate,
                hint    => 'Fix the syntax errors and try saving again. Backup saved as .bak',
            };
        }
    }

    # Write the file
    my $ok = eval {
        open my $fh, '>:utf8', $full or die "open: $!";
        print $fh $content;
        close $fh;
        1;
    };
    my $err = $@;

    if ($ok) {
        my $mtime = (stat($full))[9];
        return {
            success => 1,
            path    => $full,
            mtime   => $mtime,
        };
    } else {
        return {
            success => 0,
            error   => "Failed to write file: $err",
        };
    }
}

1;

__END__

=head1 COMPATIBILITY

This module is designed to be a drop-in replacement for the inline file I/O in:

=over

=item * Comserv::Controller::AI2 (load_file, save_file)

=item * Comserv::Controller::AI (apply_fix, read_file)

=back

To roll back: delete C<lib/Comserv/Util/EditorFile.pm> and revert the
controller changes.  All three controllers will still work — they simply
revert to their own inline file I/O.

=cut
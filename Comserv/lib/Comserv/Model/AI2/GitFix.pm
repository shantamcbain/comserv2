package Comserv::Model::AI2::GitFix;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;

use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

=head1 NAME

Comserv::Model::AI2::GitFix - Quote the real path-rejection rule. Do not invent one.

The AI editor sends the open file and auto-attached sources inside the chat
prompt. A broad "git ... commit ... path" match used to fire on that source
(Chat.pm's investigator line) and return a model-written diagnosis of a commit
rejection the user did not paste. That reply was fiction.

Trigger only when the user's own ask contains the flash string
"Rejected unsafe or unknown path". The answer is the validator source, not a
model call.

=cut

# Editor chat.js appends loaded files after this marker, and also as
# [FILE: path] ``` ... ``` blocks. Neither is the user's question.
sub user_ask {
    my ($self, $prompt) = @_;
    my $ask = defined $prompt ? $prompt : '';
    $ask =~ s/\n---\nThese files were loaded live.*\z//s;
    $ask =~ s/\[FILE:[^\]]*\][\s\S]*?```[\s\S]*?```//g;
    return $ask;
}

sub is_path_rejection_ask {
    my ($self, $prompt) = @_;
    return $self->user_ask($prompt) =~ /Rejected unsafe or unknown path/i ? 1 : 0;
}

sub _read_lines {
    my ($self, $abs, $start, $end) = @_;
    return '' unless $abs && -f $abs && open my $fh, '<', $abs;
    my @out;
    my $n = 0;
    while (my $line = <$fh>) {
        $n++;
        next if $n < $start;
        last if $n > $end;
        chomp $line;
        push @out, sprintf('%d|%s', $n, $line);
    }
    close $fh;
    return join("\n", @out);
}

sub validator_excerpt {
    my ($self, $c) = @_;
    my $abs = eval {
        $c && $c->can('path_to')
            ? $c->path_to('lib', 'Comserv', 'Controller', 'Admin', 'Git.pm')->stringify
            : '';
    };
    return '' unless $abs && -f $abs;
    my $rules = $self->_read_lines($abs, 213, 262);
    my $flash = $self->_read_lines($abs, 319, 326);
    return '' unless $rules && $flash;
    return "lib/Comserv/Controller/Admin/Git.pm _validate_paths:\n$rules\n\n"
         . "lib/Comserv/Controller/Admin/Git.pm flash (the exact string):\n$flash\n";
}

sub try_chat_fix {
    my ($self, $c, %args) = @_;

    my $prompt = $args{prompt} // '';
    my $ask = $self->user_ask($prompt);
    # Literal flash text in the USER ask only. Attached source must not trigger
    # this, and a loose git/commit/path regex must not either — that match is
    # what turned an editor question into a made-up rejection essay.
    return { handled => 0 } unless $ask =~ /Rejected unsafe or unknown path/i;

    my $excerpt = eval { $self->validator_excerpt($c) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'try_chat_fix',
            "validator excerpt failed: $@");
        return { handled => 0 };
    }
    unless ($excerpt) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'try_chat_fix',
            'Admin/Git.pm validator excerpt missing; not inventing a diagnosis');
        return { handled => 0 };
    }

    my $named = '';
    if ($ask =~ /Rejected unsafe or unknown path\(s\):\s*([^(]+)/i) {
        my $list = $1;
        $list =~ s/\s+\z//;
        $named = $list if length $list;
    }

    my $response = "This is the server rule, not a model guess.\n\n"
        . "The flash text is written by lib/Comserv/Controller/Admin/Git.pm "
        . "when _validate_paths rejects a path. A path is rejected only when "
        . "one of these is true in that sub:\n"
        . "- it contains '..' or starts with '/'\n"
        . "- it is not an exact key in `git status --porcelain` for the bound target\n"
        . "- the target is local and the path is a symlink whose real path is outside the repo\n\n";
    $response .= "The flash named these rejected paths: $named\n"
        . "Those names came from the error text, not from inference.\n\n"
        if $named;
    $response .= "Source:\n\n$excerpt";

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'try_chat_fix',
        'answered path rejection from Admin/Git.pm; no model call');

    return {
        handled  => 1,
        success  => 1,
        response => $response,
        model    => '(git-validator)',
        provider => 'ai2-gitfix',
        git_fix_proposal => 1,
    };
}

__PACKAGE__->meta->make_immutable;
1;

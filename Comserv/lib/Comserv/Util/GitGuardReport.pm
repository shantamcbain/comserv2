package Comserv::Util::GitGuardReport;

use strict;
use warnings;

=head1 NAME

Comserv::Util::GitGuardReport - turn a secret-guard refusal into a fix route

=head1 DESCRIPTION

Parses C<BLOCKED:> lines from C<script/git/secret_guard.sh> into file, optional
line, and reason. Builds an AI-editor URL and a prompt. Never includes secret
values — the script already reports names and rule ids only.

Key rule carried in the prompt: the env file may hold one encryption key, the
primary key for the initial database password. Every other key belongs in the
database, not in git.

=cut

sub parse {
    my ($class, $output) = @_;
    my @hits;
    for my $line (split /\n/, $output // '') {
        next unless $line =~ /^\s*BLOCKED:\s+(.+)$/;
        my $rest = $1;
        # The shell prints a UTF-8 em dash. Match those bytes and a Unicode dash.
        my ($loc, $reason);
        if ($rest =~ /^(.*?)\s+(?:\xe2\x80\x94|\x{2014}|\x{2013})\s+(.+)$/s) {
            ($loc, $reason) = ($1, $2);
        } elsif ($rest =~ /^(.*?)\s+-\s+(.+)$/s) {
            ($loc, $reason) = ($1, $2);
        } else {
            next;
        }
        my ($file, $line_no) = ($loc, 0);
        if ($loc =~ /^(.*):(\d+)$/) {
            ($file, $line_no) = ($1, $2 + 0);
        }
        next unless length $file;
        push @hits, {
            file   => $file,
            line   => $line_no,
            reason => $reason,
        };
    }
    return \@hits;
}

sub is_key_file {
    my ($class, $path) = @_;
    return 0 unless defined $path && length $path;
    my $base = $path;
    $base =~ s{.*/}{};
    return 1 if $base =~ /
        (?:^|[._])encryption_key$
        |\.(?:key|pem|p12|pfx|jks|kdbx)$
        |^id_(?:rsa|ed25519|ecdsa|dsa)
        |^\.env(?:\.|$)
        |^(?:db_config|credentials|auth)\.json$
    /ix;
    return 0;
}

sub editor_path {
    my ($class, $file) = @_;
    $file //= '';
    $file =~ s{^Comserv/}{};
    return $file;
}

sub _esc {
    my ($s) = @_;
    $s //= '';
    $s =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge;
    return $s;
}

sub prompt_for {
    my ($class, $hit) = @_;
    my $loc = $hit->{file} // 'unknown';
    $loc .= ':' . $hit->{line} if $hit->{line};
    my $reason = $hit->{reason} // 'secret guard';
    return join("\n",
        'Secret guard refused a commit or merge. Do not print, quote, copy, or commit any secret value.',
        '',
        "Location: $loc",
        "Reason: $reason",
        '',
        'Key rule: the env file may hold only ONE encryption key — the primary key that unlocks the initial database password. Every other key belongs in the database, not in git and not as an extra env entry.',
        'If that primary key is missing on a new server (Docker or freestanding), an admin creates the first env file as part of install. Do not invent additional env keys.',
        'A new install either uses a key issued by the primary install to reach the shared database, or creates its own empty or core-prefilled tables without that key. Do not decide that here.',
        '',
        'Fix this block:',
        '- If the flagged path is a key, .env, or credential file: unstage it and keep it out of git. Do not open that file. Leave only the primary DB key in the env. Move any other key material into the database.',
        '- If the flagged path is source with an embedded secret: remove the literal. The initial DB password comes from the single env key. Other secrets are read from the database.',
        '- Do not use --no-verify. Do not add the path to .secret-guard-allow unless a human has reviewed that it is not a secret.',
    );
}

sub editor_url {
    my ($class, $hit) = @_;
    my $prompt = _esc($hit->{prompt} // $class->prompt_for($hit));
    my $path = $class->is_key_file($hit->{file})
        ? 'lib/Comserv/Util/EnvFileManager.pm'
        : $class->editor_path($hit->{file});
    return '' unless length $path;
    my $url = '/ai2/editing_widget_popup?file=' . _esc($path) . '&prompt=' . $prompt;
    $url .= '&line=' . $hit->{line} if $hit->{line} && !$class->is_key_file($hit->{file});
    return $url;
}

sub enrich {
    my ($class, $output) = @_;
    my $hits = $class->parse($output);
    @$hits = splice(@$hits, 0, 8) if @$hits > 8;
    for my $h (@$hits) {
        $h->{editor_path} = $class->editor_path($h->{file});
        $h->{key_file}    = $class->is_key_file($h->{file}) ? 1 : 0;
        $h->{prompt}      = $class->prompt_for($h);
        $h->{editor_url}  = $class->editor_url($h);
        $h->{editor_note} = $h->{key_file}
            ? 'Key file is not opened. The editor opens the env-file code with a fix prompt.'
            : '';
    }
    return $hits;
}

sub text_for {
    my ($class, $hits) = @_;
    return '' unless $hits && ref $hits eq 'ARRAY' && @$hits;
    my @lines = (
        'Fix route (no secret values):',
        'Only one encryption key belongs in the env: the primary key for the initial DB password.',
        'Every other key belongs in the database, not in git.',
    );
    for my $h (@$hits) {
        my $loc = ($h->{file} // '') . ($h->{line} ? ":$h->{line}" : '');
        push @lines, "Location: $loc — $h->{reason}";
        push @lines, "Editor: $h->{editor_url}" if $h->{editor_url};
        push @lines, $h->{editor_note} if $h->{editor_note};
        push @lines, 'Prompt:';
        push @lines, $h->{prompt} // '';
    }
    return join("\n", @lines);
}

1;

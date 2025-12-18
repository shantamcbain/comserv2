#!/usr/bin/perl
use strict;
use warnings;
use YAML;
use DateTime;
use Sys::Hostname;
use Getopt::Long;
use JSON::PP;

my $log_file = '/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/session_history/prompts_log.yaml';
my $session_file = '/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/session_history/current_session.md';

sub get_current_chat {
    return unless -f $session_file;
    my $last_chat = 0;
    open my $fh, '<', $session_file or return;
    while (<$fh>) {
        $last_chat = $1 if /^## Chat (\d+)/;
    }
    close $fh;
    return $last_chat || undef;
}

sub get_next_prompt {
    return 1 unless -f $log_file;
    my $last_prompt = 0;
    open my $fh, '<', $log_file or return 1;
    while (<$fh>) {
        $last_prompt = $1 if /^prompt: (\d+)/;
    }
    close $fh;
    return $last_prompt + 1;
}

my $detected_chat = get_current_chat();
my $detected_prompt = get_next_prompt();

my %args = (
    chat => $detected_chat,
    prompt => $detected_prompt,
    action => undef,
    description => undef,
    files => '',
    tools => '',
    success => 1,
    problems => undef,
    notes => undef,
    diagnostics => {},
    ai_assistant => $ENV{AI_ASSISTANT} // 'Zencoder',
    agent_name => $ENV{AGENT_NAME} // 'UnknownAgent',
    session_id => $ENV{SESSION_ID} // '',
);

GetOptions(
    'chat=i' => \$args{chat},
    'prompt=i' => \$args{prompt},
    'action=s' => \$args{action},
    'description=s' => \$args{description},
    'files=s' => \$args{files},
    'tools=s' => \$args{tools},
    'success=i' => \$args{success},
    'problems=s' => \$args{problems},
    'notes=s' => \$args{notes},
    'diagnostics=s' => sub {
        my ($opt, $val) = @_;
        eval {
            $args{diagnostics} = JSON::PP::decode_json($val);
        };
        if ($@) {
            warn "Failed to parse diagnostics JSON: $@";
            $args{diagnostics} = {};
        }
    },
) or die "Error in command line arguments\n";

die "chat number could not be auto-detected or provided via --chat\n" unless defined $args{chat};
die "action is required\n" unless defined $args{action};
die "description is required\n" unless defined $args{description};

my $dt = DateTime->now(time_zone => 'UTC');
my $timestamp = $dt->iso8601 . 'Z';

my @files = split(/,\s*/, $args{files});
@files = map { s/^\s+|\s+$//g; $_ } @files;
@files = grep { $_ } @files;

my @tools = split(/,\s*/, $args{tools});
@tools = map { s/^\s+|\s+$//g; $_ } @tools;
@tools = grep { $_ } @tools;

my $hostname = hostname();

my $entry = {
    timestamp => $timestamp,
    ai_assistant => $args{ai_assistant},
    agent_name => $args{agent_name},
    session_id => $args{session_id},
    chat => $args{chat},
    prompt => $args{prompt},
    action => $args{action},
    description => $args{description},
    files_involved => \@files,
    code_changed => undef,
    tools_used => \@tools,
    success => $args{success},
    hostname => $hostname,
};

$entry->{diagnostics} = $args{diagnostics} if keys %{$args{diagnostics}};
$entry->{problems} = $args{problems} if defined $args{problems};
$entry->{notes} = $args{notes} if defined $args{notes};

open my $fh, '>>', $log_file or die "Cannot open $log_file: $!\n";
print $fh "---\n";

my $yaml_entry = YAML::Dump($entry);
$yaml_entry =~ s/^---\n//;
print $fh $yaml_entry;

close $fh or die "Cannot close $log_file: $!\n";

print "✅ Updated prompts_log.yaml: Chat $args{chat}, Prompt $args{prompt}\n";
exit 0;

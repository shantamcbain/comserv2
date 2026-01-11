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
    my $current_chat = undef;
    open my $fh, '<', $session_file or return;
    while (<$fh>) {
        if (/^#+\s*\*?\*?Chat\s+(\d+)/) {
            $current_chat = $1;
            last;
        }
    }
    close $fh;
    return $current_chat;
}

sub print_help {
    print <<'EOF';
updateprompt.pl - Log Zencoder agent actions and user messages to prompts_log.yaml

USAGE:
    perl updateprompt.pl [OPTIONS]

REQUIRED OPTIONS (AGENT WORK):
    --action TEXT              Brief description of what the agent did
    --description TEXT         Detailed explanation of the action

REQUIRED OPTIONS (USER MESSAGE):
    --user-message TEXT        User's prompt/command/question text
    --user-action TEXT         What the user asked the agent to do

OPTIONAL OPTIONS:
    --chat NUM                 Chat number (auto-detected from current_session.md if not provided)
    --prompt NUM               Prompt number (auto-detected from prompts_log.yaml if not provided)
    --phase TEXT               Execution phase: "before" (planning/pre-work), "after" (post-execution) [default: after]
    --diffs TEXT               Show what changed in files (for "after" phase)
    --files TEXT               Comma-separated list of files involved
    --tools TEXT               Comma-separated list of tools used
    --success 0|1              Success status (default: 1 for agent, varies for user)
    --problems TEXT            Description of any problems encountered
    --notes TEXT               Additional notes
    --full-prompt TEXT         ENTIRE original opening prompt/role block (for bilateral audit trail)
    --agent-type TEXT          Type of agent (daily-audit, documentation-sync, master-plan, daily-plans, etc)
    --help                     Show this help message

EXAMPLES (AGENT WORK):
    perl updateprompt.pl \
      --action "Daily Audit Agent: Analyzed code changes" \
      --description "Created daily_audit_log.md and daily_audit_plan.md" \
      --files "daily_audit_log.md, daily_audit_plan.md, agent_pipeline_data.yaml" \
      --tools "Read, Write, Grep" \
      --success 1 \
      --agent-type "daily-audit"

EXAMPLES (USER MESSAGE):
    perl updateprompt.pl \
      --user-message "/daily-audit" \
      --user-action "Requested daily audit workflow execution" \
      --success 1

OUTPUT:
    Appends a new entry to: Comserv/root/Documentation/session_history/prompts_log.yaml
    Chat and Prompt numbers are auto-detected unless overridden via --chat or --prompt
    Log entries include both user_message (when provided) and agent_action (when provided)

ENVIRONMENT VARIABLES (optional):
    AI_ASSISTANT        Name of AI assistant (default: Zencoder)
    AGENT_NAME          Name of specific agent (default: UnknownAgent)
    SESSION_ID          Session identifier (default: empty)

EOF
    exit 0;
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
    user_message => undef,
    user_action => undef,
    phase => 'after',
    diffs => undef,
    files => '',
    tools => '',
    success => 1,
    problems => undef,
    notes => undef,
    full_prompt => undef,
    agent_type => undef,
    diagnostics => {},
    ai_assistant => $ENV{AI_ASSISTANT} // 'Zencoder',
    agent_name => $ENV{AGENT_NAME} // 'UnknownAgent',
    session_id => $ENV{SESSION_ID} // '',
);

GetOptions(
    'help' => sub { print_help() },
    'chat=i' => \$args{chat},
    'prompt=i' => \$args{prompt},
    'action=s' => \$args{action},
    'description=s' => \$args{description},
    'user-message=s' => \$args{user_message},
    'user-action=s' => \$args{user_action},
    'phase=s' => \$args{phase},
    'diffs=s' => \$args{diffs},
    'files=s' => \$args{files},
    'tools=s' => \$args{tools},
    'success=i' => \$args{success},
    'problems=s' => \$args{problems},
    'notes=s' => \$args{notes},
    'full-prompt=s' => \$args{full_prompt},
    'agent-type=s' => \$args{agent_type},
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

# Determine mode: either agent work OR user message, not both
my $is_agent_work = defined $args{action};
my $is_user_message = defined $args{user_message};

if ($is_agent_work && $is_user_message) {
    die "Error: Provide EITHER (--action + --description) OR (--user-message + --user-action), not both\n";
}

if ($is_agent_work) {
    die "action is required for agent work\n" unless defined $args{action};
    die "description is required for agent work\n" unless defined $args{description};
} elsif ($is_user_message) {
    die "user-message is required for user input logging\n" unless defined $args{user_message};
    die "user-action is required for user input logging\n" unless defined $args{user_action};
} else {
    die "Error: Provide EITHER (--action + --description) for agent work OR (--user-message + --user-action) for user input\n";
}

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
    session_id => $args{session_id},
    chat => $args{chat},
    prompt => $args{prompt},
    success => $args{success},
    hostname => $hostname,
};

# Add agent-specific fields if this is agent work
if (defined $args{action}) {
    $entry->{agent_name} = $args{agent_name};
    $entry->{agent_type} = $args{agent_type} if defined $args{agent_type};
    $entry->{action} = $args{action};
    $entry->{description} = $args{description};
    $entry->{phase} = $args{phase};
    $entry->{files_involved} = \@files;
    $entry->{code_changed} = undef;
    $entry->{tools_used} = \@tools;
    $entry->{diagnostics} = $args{diagnostics} if keys %{$args{diagnostics}};
    $entry->{diffs} = $args{diffs} if defined $args{diffs};
    $entry->{problems} = $args{problems} if defined $args{problems};
    $entry->{notes} = $args{notes} if defined $args{notes};
    $entry->{full_prompt} = $args{full_prompt} if defined $args{full_prompt};
} elsif (defined $args{user_message}) {
    # Add user-specific fields if this is user input
    $entry->{message_type} = 'user_input';
    $entry->{user_message} = $args{user_message};
    $entry->{user_action} = $args{user_action};
    $entry->{notes} = $args{notes} if defined $args{notes};
    $entry->{full_prompt} = $args{full_prompt} if defined $args{full_prompt};
}

open my $fh, '>>', $log_file or die "Cannot open $log_file: $!\n";
print $fh "---\n";

my $yaml_entry = YAML::Dump($entry);
$yaml_entry =~ s/^---\n//;
print $fh $yaml_entry;

close $fh or die "Cannot close $log_file: $!\n";

if (defined $args{action}) {
    print "✅ Updated prompts_log.yaml: Chat $args{chat}, Prompt $args{prompt} - Agent Action Logged\n";
    print "   Action: $args{action}\n";
} elsif (defined $args{user_message}) {
    print "✅ Updated prompts_log.yaml: Chat $args{chat}, Prompt $args{prompt} - User Input Logged\n";
    print "   Message: $args{user_message}\n";
}
exit 0;

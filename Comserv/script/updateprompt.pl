#!/usr/bin/perl
use LWP::UserAgent;
use Data::Dumper;
use strict;
use warnings;
use YAML;
use DateTime;
use Sys::Hostname;
use Getopt::Long;
use JSON::PP;

my $log_file = '/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/session_history/prompts_log.yaml';

sub get_chat_from_handoff {
    return unless -f $log_file;
    my $last_chat = 0;
    my $last_was_handoff = 0;
    
    open my $fh, '<', $log_file or return;
    while (<$fh>) {
        if (/^---$/) {
            $last_was_handoff = 0; # Reset for new entry
            next;
        }
        if (/^(?:chat|conversation_id): (\d+)/) {
            $last_chat = $1;
        }
        if (/^action:.*handoff/i || /^description:.*handoff/i) {
            $last_was_handoff = 1;
        }
    }
    close $fh;
    
    # If the last entry was a handoff, we are in a NEW chat
    if ($last_was_handoff) {
        return $last_chat + 1;
    }
    # Otherwise, we are CONTINUING the last chat found
    return $last_chat if $last_chat > 0;
    return 1; # Default to Chat 1 if nothing found
}

sub get_chat_name {
    my ($full_prompt) = @_;
    if ($full_prompt) {
        # Handle literal \n if passed as string
        $full_prompt =~ s/\\n/\n/g;
        if ($full_prompt =~ /^CHAT NAME:\s*(.*?)$/m) {
            return $1;
        }
        # Fallback to first line of prompt, truncated
        my ($first_line) = split(/\n/, $full_prompt, 2);
        $first_line =~ s/^\s+|\s+$//g;
        $first_line = substr($first_line, 0, 100) if length($first_line) > 100;
        return $first_line;
    }
    return;
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
    --code-changed TEXT       Code changes in +- format (e.g., "+10 -5 lines")
    --session-id TEXT        Session identifier (auto-detected from env SESSION_ID)
    --conversation-id NUM    Conversation ID from AI API (for linking prompts)

    --chat NUM                 [DEPRECATED] Use --conversation-id instead. Chat number (auto-detected from prompts_log.yaml /chathandoff entries if not provided)
    --conversation-id NUM    Conversation ID from Comserv AI Chat system (used for linking prompts)
    --title TEXT               Title for the conversation (overrides CHAT NAME in prompt)
    --chat-name TEXT           Alias for --title
    --new-chat                 Start a new conversation (omits conversation-id in API call to trigger new chat record)
    --prompt NUM               Prompt number (auto-detected from prompts_log.yaml if not provided)
    --phase TEXT               Execution phase: "before" (planning/pre-work), "after" (post-execution) [default: after]
    --diffs TEXT               Show what changed in files (for "after" phase)
    --files TEXT               Comma-separated list of files involved
    --tools TEXT               Comma-separated list of tools used
    --success 0|1              Success status (default: 1 for agent, varies for user)
    --problems TEXT            Description of any problems encountered
    --notes TEXT               Additional notes
    --full-prompt TEXT         ENTIRE original opening prompt/role block (for bilateral audit trail)
    --agent-type TEXT          Type of agent (daily-audit, cleanup-agent, master-plan, etc)
    --help                     Show this help message

MANDATORY AI AGENT FORMATTING STANDARDS:
    1. VERBATIM RECORDS: When recording a user message, you MUST provide the UNALTERED record of the user's prompt.
       Do not paraphrase, summarize, or clean up the user's input. The --user-message field
       must contain the exact text provided by the user.
    2. BILATERAL LOGGING: The --description field MUST include the 'USER PROMPT: [verbatim text]' prefix
       when logging agent work to maintain the audit trail of what triggered the action.
    3. NO interpretaions: Do not include your interpretation of what the user meant in the user-message field.
    
    Example of CORRECT recording:
      --user-message "Fix the bug in the login system, it's urgent!!"
      --user-action "Fixed login system bug"
    
    Example of INCORRECT recording:
      --user-message "User requested login system fix" (Paraphrased)

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

EOF
    exit 0;
}

# Environment variables
my $session_id = $ENV{SESSION_ID} // '';
my $agent_name = $ENV{AGENT_NAME} // 'unknown';
my $ai_assistant = $ENV{AI_ASSISTANT} // 'Zencoder';

sub get_next_prompt {
    my ($conversation_id) = @_;
    return 0 unless -f $log_file;
    my $last_prompt = -1;
    my $found_conv = 0;
    open my $fh, '<', $log_file or return 0;
    while (<$fh>) {
        if (/^(?:chat|conversation_id): (\d+)/) {
            if ($conversation_id && $1 == $conversation_id) {
                $found_conv = 1;
            } else {
                $found_conv = 0;
            }
        }
        if ($found_conv && /^prompt: (\d+)/) {
            $last_prompt = $1;
        }
    }
    close $fh;
    return $last_prompt + 1;
}

my $detected_chat = get_chat_from_handoff();
my $detected_prompt = get_next_prompt($detected_chat);

# Session persistence files
my $session_id_file_local = '/home/shanta/PycharmProjects/comserv2/.zencoder/session_id';
my $conv_id_file_local = '/home/shanta/PycharmProjects/comserv2/.zencoder/current_conversation_id';

# Try to get session_id from local file if not provided
my $saved_session_id;
if (-f $session_id_file_local) {
    open my $fh, '<', $session_id_file_local;
    $saved_session_id = <$fh>;
    close $fh;
    $saved_session_id =~ s/^\s+|\s+$//g if $saved_session_id;
}

# Try to get conversation_id from local session file if detection fails
if (!$detected_chat && -f $conv_id_file_local) {
    open my $fh, '<', $conv_id_file_local;
    my $content = <$fh>;
    close $fh;
    if ($content && $content =~ /^(\d+)$/) {
        $detected_chat = $1;
    }
}

my %args = (
    conversation_id => $detected_chat,
    'new-chat' => 0,
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
    agent_type => $ENV{AGENT_TYPE} // 'cleanup-agent',
    diagnostics => {},
    ai_assistant => $ENV{AI_ASSISTANT} // 'Zencoder',
    agent_name => $ENV{AGENT_NAME} // 'unknown',
    session_id => $ENV{SESSION_ID} // $saved_session_id // '',
);

GetOptions(
    'help' => sub { print_help() },
    'chat=i' => \$args{conversation_id}, # Backward compatibility
    'conversation-id=i' => \$args{conversation_id},
    'title=s' => \$args{chat_name},
    'chat-name=s' => \$args{chat_name},
    'new-chat' => \$args{'new-chat'},
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
    'code-changed=s' => \$args{code_changed},
    'session-id=s' => \$args{session_id},
) or die "Error in command line arguments\n";

die "conversation-id could not be auto-detected or provided via --conversation-id\n" unless (defined $args{conversation_id} || $args{'new-chat'});

# If new-chat requested, clear detected conversation_id to force new conversation creation in API
if ($args{'new-chat'}) {
    $args{conversation_id} = undef;
}

# If it's a new chat, try to extract a chat name from the full prompt (if not already provided via --title)
if ($args{'new-chat'} && $args{full_prompt} && !defined $args{chat_name}) {
    my $name = get_chat_name($args{full_prompt});
    if ($name) {
        $args{chat_name} = $name;
    }
}

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

# Sanitization Detection (AI Limitation Mitigation - 2026-01-23)
if ($is_user_message && $args{user_message}) {
    my $msg = $args{user_message};
    
    # Check for common sanitization patterns
    my @red_flags = (
        # Too short (likely summarized) - exception for slash commands
        (length($msg) < 10 && $msg !~ m{^/\w+}),
        
        # Paraphrasing indicators
        ($msg =~ /^(User|The user) (requested|asked|said|wanted)/i),
        
        # Professional cleanup patterns
        ($msg =~ /^(Please |Could you )?update|modify|change|fix/i && length($msg) < 30),
    );
    
    if (grep { $_ } @red_flags) {
        warn "\n";
        warn "⚠️  ═══════════════════════════════════════════════════════════\n";
        warn "⚠️  SANITIZATION DETECTED in --user-message\n";
        warn "⚠️  ═══════════════════════════════════════════════════════════\n";
        warn "    Message appears paraphrased or summarized\n";
        warn "    Verbatim recording required (see line 98-110)\n";
        warn "    Received: $msg\n";
        warn "\n";
        warn "    If this is genuinely what user typed, add environment variable:\n";
        warn "    export BYPASS_SANITIZATION_CHECK=1\n";
        warn "⚠️  ═══════════════════════════════════════════════════════════\n";
        warn "\n";
        
        # Check if bypass flag is set
        unless ($ENV{BYPASS_SANITIZATION_CHECK}) {
            # Don't die, just warn loudly - allows manual override if needed
            # But log it for metrics tracking
            warn "    Continuing with WARNING logged...\n";
        }
    }
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

# --- AI Chat System Integration ---
sub get_session_details {
    my ($args) = @_;
    return unless $args->{session_id};
    
    my $ua = LWP::UserAgent->new;
    $ua->timeout(5);
    
    # Base URL for Comserv API - Use port 3000 for development server if 3001 fails
    my @urls = (
        $ENV{COMSERV_API_URL} || 'http://localhost:3000',
        'http://workstation.local:3001',
        'http://localhost:3001'
    );
    
    foreach my $base_url (@urls) {
        my $url = "$base_url/ai/session_details";
        
        # Add session cookie for authentication
        $ua->default_header('Cookie' => "comserv_session=" . $args->{session_id});
        
        my $response = $ua->get($url);
        
        if ($response->is_success) {
            my $data = eval { JSON::PP::decode_json($response->content) };
            if ($data && $data->{success}) {
                # Save session_id for future prompts
                if ($args->{session_id}) {
                    open my $sfh, '>', $session_id_file_local;
                    print $sfh $args->{session_id};
                    close $sfh;
                }
                return $data;
            }
        }
    }
    return;
}

sub create_ai_chat_record {
    my ($args) = @_;
    
    my $ua = LWP::UserAgent->new;
    $ua->timeout(5);
    
    # Base URL for Comserv API
    my @urls = (
        $ENV{COMSERV_API_URL} || 'http://localhost:3000',
        'http://workstation.local:3001',
        'http://localhost:3001'
    );
    
    my $message;
    if ($is_agent_work) {
        my $phase_label = ($args->{phase} eq 'before') ? "Research/Plan" : "Execution/Results";
        $message = "Action: " . ($args->{action} // '') . "\n";
        $message .= "Phase: " . ($args->{phase} // '') . " ($phase_label)\n";
        $message .= "Agent: " . ($args->{agent_name} // 'unknown') . " (" . ($args->{agent_type} // 'cleanup-agent') . ")\n";
        $message .= "Tools: " . ($args->{tools} // '') . "\n";
        $message .= "Files: " . ($args->{files} // '') . "\n";
        $message .= "Changes: " . ($args->{code_changed} // '') . "\n" if $args->{code_changed};
        $message .= "\nDescription: " . ($args->{description} // '');
    } else {
        $message = $args->{user_message} || "System Log Entry";
    }
    
    # Extract original user prompt from description if present (bilateral logging)
    # Match both 'USER PROMPT: "content"' and 'USER PROMPT: content' formats
    if (!$args->{user_message} && $args->{description} && $args->{description} =~ /USER PROMPT:\s*['"]?(.*?)['"]?(\. Agent| \.| \-\-| \n|$)/s) {
        my $user_p = $1;
        # Clean up any trailing quotes or markers if they were accidentally captured
        $user_p =~ s/['"]$//;
        $user_p =~ s/^\s+|\s+$//g;
        $message = $user_p unless $is_agent_work;
    }

    # If this is a new conversation, the message acts as the title
    # Limit length for title if needed, but the AI chat system usually handles this
    
    foreach my $base_url (@urls) {
        my $url = "$base_url/chat/send_message";
        
        # Use session cookie if available
        if ($args->{session_id}) {
            $ua->default_header('Cookie' => "comserv_session=" . $args->{session_id});
        }
        
        # Add metadata for the AI system
        my %payload = (
            message => $message,
            agent_type => $args->{agent_type} || 'cleanup-agent',
        );
        $payload{conversation_id} = $args->{conversation_id} if $args->{conversation_id};
        $payload{is_new_conversation} = 1 if $args->{'new-chat'};
        $payload{title} = $args->{chat_name} if $args->{chat_name};
        
        my $response = $ua->post($url, \%payload);
        
        if ($response->is_success) {
            my $data = eval { JSON::PP::decode_json($response->content) };
            if ($data && $data->{success}) {
                # Save session_id for future prompts if we have one
                if ($args->{session_id}) {
                    open my $sfh, '>', $session_id_file_local;
                    print $sfh $args->{session_id};
                    close $sfh;
                }
                return $data;
            } else {
                warn "AI Chat API ($base_url) returned success:0 - " . ($data->{error} || 'Unknown error') . "\n";
            }
        } else {
            warn "AI Chat API ($base_url) connection failed: " . $response->status_line . "\n";
        }
    }
    return;
}

# 1. Attempt to retrieve session details if session_id is provided
if ($args{session_id}) {
    my $session_info = get_session_details(\%args);
    if ($session_info) {
        $args{username} = $session_info->{username} if $session_info->{username};
        $args{conversation_id} ||= $session_info->{conversation_id};
        $hostname = $session_info->{hostname} if $session_info->{hostname};
    }
}

# 2. If we are performing agent work or logging user message,
# attempt to create a record in the AI system
if ($is_agent_work || $is_user_message) {
    my $ai_data = create_ai_chat_record(\%args);
    if ($ai_data) {
        $args{conversation_id} = $ai_data->{conversation_id};
    }
}

# Ensure conversation_id is prioritized from API results if provided
if ($args{conversation_id}) {
    # Save conversation_id to local session file for future prompts
    eval {
        open my $fh, '>', $conv_id_file_local;
        print $fh $args{conversation_id};
        close $fh;
    };
} elsif ($args{'new-chat'}) {
    # Clear local session files if starting a new chat
    unlink $conv_id_file_local if -f $conv_id_file_local;
    unlink $session_id_file_local if -f $session_id_file_local;
}

my $entry = {
    timestamp => $timestamp,
    ai_assistant => $args{ai_assistant},
    session_id => $args{session_id} // '',
    conversation_id => $args{conversation_id} // 0,
    prompt => $args{prompt},
    success => $args{success},
    hostname => $hostname // 'unknown',
    username => $args{username} // 'testadmin',
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
    print "✅ Updated prompts_log.yaml: Conversation $args{conversation_id}, Prompt $args{prompt} - Agent Action Logged\n";
    print "   Action: $args{action}\n";
} elsif (defined $args{user_message}) {
    print "✅ Updated prompts_log.yaml: Conversation $args{conversation_id}, Prompt $args{prompt} - User Input Logged\n";
    print "   Message: $args{user_message}\n";
}
exit 0;

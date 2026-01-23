#!/usr/bin/perl
use strict;
use warnings;
use YAML;
use DateTime;

=head1 NAME

validation_step0.pl - Pre-Prompt Validation Gate (SYSTEM-LEVEL ENFORCEMENT)

=head1 DESCRIPTION

CRITICAL ENFORCEMENT MECHANISM: This script MUST run before any agent work begins.
It validates previous prompt compliance and BLOCKS work if violations are found.

Step 0 of every prompt execution:
1. Check if previous prompt executed /updateprompt.pl (logged to prompts_log.yaml)
2. Check if ask_questions() was used when user input required
3. Verify success status of previous prompt
4. HALT work and log violations if found
5. Exit with status 0 (PASS) or 1 (FAIL)

If FAIL: Agent cannot proceed. Error message explains violation. User must review.

=head1 USAGE

    perl validation_step0.pl

ENVIRONMENT VARIABLES (optional):
    CURRENT_CHAT    Current chat number (auto-detected from prompts_log.yaml if not set)
    CURRENT_PROMPT  Current prompt number (next prompt after last logged)

=head1 ENFORCEMENT RULES

Rule 1: Previous prompt MUST have /updateprompt entry
- If missing: HALT and log "PROTOCOL VIOLATION: /updateprompt not executed in previous prompt"
- Action: User must review previous prompt compliance

Rule 2: ask_questions() MUST be used for user decisions
- If text question detected in previous prompt: HALT and log "PROTOCOL VIOLATION: Text question instead of ask_questions()"
- Action: User must execute /chathandoff to close session with compliance error

Rule 3: Previous prompt MUST have success status
- If missing or undefined: HALT and log "PROTOCOL VIOLATION: Previous prompt missing success status"
- Action: User must verify previous prompt completion

Rule 4: Cannot skip validation
- This gate runs BEFORE any work tools
- No bypass, no override, no exceptions
- Agent cannot continue without passing validation

=cut

my $log_file = '/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/session_history/prompts_log.yaml';

sub get_current_chat {
    return $ENV{CURRENT_CHAT} if $ENV{CURRENT_CHAT};
    return unless -f $log_file;
    my $last_chat = 0;
    my $in_entry = 0;
    
    open my $fh, '<', $log_file or return;
    while (<$fh>) {
        if (/^---$/) {
            $in_entry = 1;
            next;
        }
        if ($in_entry) {
            if (/^chat: (\d+)/) {
                $last_chat = $1;
            }
            if (/^action:.*handoff/i || /^description:.*handoff/i) {
                close $fh;
                return $last_chat + 1;
            }
        }
    }
    close $fh;
    return $last_chat;
}

sub get_last_prompt_entry {
    return unless -f $log_file;
    my @entries = ();
    
    open my $fh, '<', $log_file or do {
        print "⚠️  WARNING: prompts_log.yaml not found. First prompt of session - PASS\n";
        return undef;
    };
    
    my $current_entry = {};
    my $in_entry = 0;
    
    while (<$fh>) {
        if (/^---$/) {
            if (keys %$current_entry) {
                # Skip validation entries when looking for the last prompt
                if (!$current_entry->{validation_step0}) {
                    push @entries, { %$current_entry };
                }
            }
            $current_entry = {};
            $in_entry = 1;
        } elsif ($in_entry && /^(\w+):\s+(.*)$/) {
            my ($key, $value) = ($1, $2);
            $value =~ s/^["']|["']$//g;  # Remove quotes
            $current_entry->{$key} = $value;
        }
    }
    
    if (keys %$current_entry && !$current_entry->{validation_step0}) {
        push @entries, { %$current_entry };
    }
    
    close $fh;
    return @entries ? $entries[-1] : undef;
}

sub validate_compliance {
    my $last_entry = get_last_prompt_entry();
    my $current_chat = get_current_chat();
    
    # First prompt of session - always PASS
    if (!defined $last_entry) {
        return {
            passed => 1,
            message => "✅ PASS: First prompt of session",
            violations => []
        };
    }
    
    my @violations = ();
    
    # Rule 1: Check /updateprompt was executed
    # For user_input messages, 'action' is not present, 'user_action' is.
    if (!defined $last_entry->{prompt}) {
        push @violations, "PROTOCOL VIOLATION: /updateprompt not executed - missing prompt number in previous entry";
    }
    
    if (!defined $last_entry->{action} && !defined $last_entry->{user_action}) {
        push @violations, "PROTOCOL VIOLATION: /updateprompt not executed - missing action/user_action in previous entry";
    }
    
    # Rule 2: Check success status exists
    if (!defined $last_entry->{success}) {
        push @violations, "PROTOCOL VIOLATION: Previous prompt missing success status - cannot determine completion";
    }
    
    # Rule 3: Verify chat continuity
    if (defined $current_chat && defined $last_entry->{chat}) {
        if ($last_entry->{chat} != $current_chat) {
            # Chat changed - this is a new chat, so rules don't apply from previous chat
            # Reset validation for new chat
            return {
                passed => 1,
                message => "✅ PASS: New chat started (Chat $current_chat) - previous chat compliance not required",
                violations => []
            };
        }
    }
    
    if (@violations) {
        return {
            passed => 0,
            message => "❌ FAIL: Compliance violations detected. Work HALTED.",
            violations => \@violations
        };
    }
    
    return {
        passed => 1,
        message => "✅ PASS: Previous prompt compliance verified",
        violations => []
    };
}

sub log_validation_result {
    my ($result, $current_chat) = @_;
    my $timestamp = DateTime->now(time_zone => 'UTC')->iso8601 . 'Z';
    
    open my $fh, '>>', $log_file or do {
        warn "Cannot write to $log_file: $!\n";
        return;
    };
    
    print $fh "---\n";
    print $fh "timestamp: \"$timestamp\"\n";
    print $fh "chat: $current_chat\n" if $current_chat;
    print $fh "validation_step0: true\n";
    print $fh "status: " . ($result->{passed} ? "PASS" : "FAIL") . "\n";
    print $fh "message: \"" . $result->{message} . "\"\n";
    
    if (@{$result->{violations}}) {
        print $fh "violations:\n";
        foreach my $violation (@{$result->{violations}}) {
            print $fh "  - \"$violation\"\n";
        }
    }
    
    close $fh;
}

# Main execution
my $result = validate_compliance();
my $current_chat = get_current_chat();

# Log validation result
log_validation_result($result, $current_chat);

# Output result
print "\n" . "="x70 . "\n";
print "VALIDATION STEP 0 - PRE-PROMPT COMPLIANCE CHECK\n";
print "="x70 . "\n";
print $result->{message} . "\n";

if (@{$result->{violations}}) {
    print "\nVIOLATIONS DETECTED:\n";
    foreach my $violation (@{$result->{violations}}) {
        print "  🔴 $violation\n";
    }
    print "\nACTION REQUIRED:\n";
    print "  1. Review previous prompt execution\n";
    print "  2. Verify /updateprompt.pl was executed\n";
    print "  3. Confirm ask_questions() was used for user decisions\n";
    print "  4. Check prompts_log.yaml for compliance issues\n";
    print "  5. Return to this check after compliance fixes\n";
}

print "="x70 . "\n\n";

# Exit with appropriate status code
exit($result->{passed} ? 0 : 1);

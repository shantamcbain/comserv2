package Comserv::Model::AI2::ChatIntent;
# Shared Chat-with-AI / AI Editor intent routing helpers.
# Keeps create-ticket vs create-todo (and editor agent skips) consistent across
# Controller::AI2 and Model::AI2::Chat so interceptors cannot hijack each other.
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(is_editor_agent looks_like_todo_create looks_like_helpdesk_ticket_create);

# AI Editor agents plan/analyze code; their prompts often say "create todos"
# without meaning the TodoCreate short-circuit. Chat-with-AI must not edit code.
sub is_editor_agent {
    my ($agent_id) = @_;
    return (lc($agent_id // '') =~ /^(?:programming|coding|code|documentation|analyze)$/) ? 1 : 0;
}

# Primary object of create/add is a todo/task (not a helpdesk ticket).
sub looks_like_todo_create {
    my ($prompt) = @_;
    return 0 unless defined $prompt && $prompt =~ /\S/;
    my $p = $prompt;
    $p =~ s/^\s+|\s+$//g;
    return 1 if $p =~ /\b(?:add|create|make|track)\s+(?:me\s+)?(?:a\s+|an\s+|new\s+)*(?:todos?|tasks?|to-dos?|to\s+dos?)(?:\s+item)?\b/i;
    return 0;
}

# Primary object of create/file/open/submit is a HelpDesk / support ticket.
# Used so TodoCreate does not steal ticket prompts that mention "todo" in the
# subject (3D-20260907-3180 / 6510), and so HelpDeskTicketCreate can win first.
sub looks_like_helpdesk_ticket_create {
    my ($prompt) = @_;
    return 0 unless defined $prompt && $prompt =~ /\S/;
    my $p = $prompt;
    $p =~ s/^\s+|\s+$//g;
    return 0 if $p =~ /^(how\s+(do\s+i|to)|what\s+is|explain|where\s+(is|do))\b/i;
    # Verb near ticket / support ticket / helpdesk ticket (allow a few fillers).
    return 1 if $p =~ /\b(?:create|file|open|submit|raise|lodge|report)\b(?:\W+\w+){0,5}\W+\b(?:(?:a|an|new|the)\s+)?(?:help\s*desk\s+|helpdesk\s+|support\s+)?tickets?\b/i;
    return 1 if $p =~ /\b(?:help\s*desk|helpdesk)\b(?:\W+\w+){0,4}\W+\b(?:create|file|open|submit|raise)\b(?:\W+\w+){0,4}\W+\btickets?\b/i;
    return 0;
}

1;

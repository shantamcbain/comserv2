package Comserv::Model::AI2::ChatIntent;
# Shared Chat-with-AI / AI Editor intent routing helpers.
# Keeps create-ticket vs create-todo (and editor agent skips) consistent across
# Controller::AI2 and Model::AI2::Chat so interceptors cannot hijack each other.
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(is_editor_agent looks_like_todo_create looks_like_todo_open looks_like_helpdesk_ticket_create looks_like_page_create);

# AI Editor agents plan/analyze/implement code. Their buffers and phase
# contracts mention "todo" constantly; intercepts must never fire (#2423).
# Chat-with-AI (non-editor) is the only surface that creates todos from chat.
sub is_editor_agent {
    my ($agent_id) = @_;
    # Single source of truth (todo #2564): ModelPick knows about gitfix-* too.
    require Comserv::Model::AI2::ModelPick;
    return Comserv::Model::AI2::ModelPick->is_editor_agent($agent_id) ? 1 : 0;
}

# Primary object of create/add is a todo/task (not a helpdesk ticket).
sub looks_like_todo_create {
    my ($prompt) = @_;
    return 0 unless defined $prompt && $prompt =~ /\S/;
    my $p = $prompt;
    $p =~ s/^\s+|\s+$//g;
    return 0 if $p =~ /^(how\s+(do\s+i|to)|what\s+is|explain|where\s+(is|do))\b/i;
    return 0 if $p =~ /\b(?:does\s+not|doesn'?t|do\s+not|don'?t|never|not|without)\s+(?:creating|create|adding|add|making|make|tracking|track)\b/i;
    return 1 if $p =~ /\b(?:add|create|make|track|log)\s+(?:me\s+)?(?:a|an|new|this|the)\s+(?:todos?|tasks?|to-dos?|to\s+dos?)(?:\s+item)?\b/i;
    return 1 if $p =~ /\b(?:can you|could you|would you|please)\s+(?:add|create|make|track)\b.{0,60}\b(?:todos?|tasks?|to-dos?)\b/i;
    return 1 if $p =~ /\b(?:need|want)\s+(?:a|an|new)\s+(?:todos?|tasks?)\b/i;
    return 1 if $p =~ /\bput\s+(?:this|it|that)\s+on\s+(?:the\s+)?(?:todo|task)\s+list\b/i;
    return 0;
}


# "open this todo" / "open todo 2771" must not fall through to create-todo
# (CSC-20260914-9320). Yields to ticket-create when the object is a ticket.
sub looks_like_todo_open {
    my ($prompt) = @_;
    return 0 unless defined $prompt && $prompt =~ /\S/;
    my $p = $prompt;
    $p =~ s/^\s+|\s+$//g;
    return 0 if $p =~ /^(how\s+(do\s+i|to)|what\s+is|explain|where\s+(is|do))\b/i;
    return 0 if looks_like_helpdesk_ticket_create($p);
    # "open a new todo" is create, not open.
    return 0 if $p =~ /\bopen\s+(?:a|an|new)\s+(?:new\s+)?(?:todos?|tasks?|to-dos?|to\s+dos?)\b/i;
    return 1 if $p =~ /\b(?:open|show|view|display|go\s+to|navigate\s+to|take\s+me\s+to)\s+(?:(?:this|that|the|current|my)\s+)*(?:todos?|tasks?|to-dos?|to\s+dos?)\b/i;
    return 1 if $p =~ /\b(?:open|show|view|display)\s+(?:todos?|tasks?|to-dos?|to\s+dos?)\s*#?\s*\d+\b/i;
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


# Nov 5 2026: "create/make/write (me) a (new) page about X" -> topic X, else ''.
sub looks_like_page_create {
    my ($prompt) = @_;
    return '' unless defined $prompt && $prompt =~ /\S/;
    my $p = $prompt; $p =~ s/^\s+|\s+$//g;
    return '' if $p =~ /^(how\s+(do\s+i|to)|what\s+is|explain|where\s+(is|do))\b/i;
    return '' if $p =~ /\b(?:todo|task|ticket|invoice)s?\b/i;
    if ($p =~ /\b(?:create|make|write|draft|add|build)\s+(?:me\s+)?(?:a|an|new|the)\s+(?:new\s+)?(?:web\s*)?page\s+(?:about|on|for|called|titled|describing)\s+(.{3,200})/i) {
        my $t = $1; $t =~ s/[.?!]+\s*$//; return $t;
    }
    return '';
}

1;

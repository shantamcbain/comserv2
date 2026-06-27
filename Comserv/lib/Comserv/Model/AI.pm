package Comserv::Model::AI;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

# Facade / central entry point for all AI functionality.
# Thin controller should call methods on this model instead of implementing logic.

# We deliberately do NOT use has 'config' or has 'ai_config' because
# Catalyst::Component already provides a 'config' class/instance method,
# and Moose readers blow up with "string as HASH ref" when Catalyst
# calls ClassName->method during component registration.
#
# Instead we use a private slot + safe accessor methods that guard
# against being called on the bare class name.

sub ai_config {
    my $self = shift;
    # If called as Class->ai_config during loading, just give a fresh one
    return Comserv::Model::AI::Config->new unless ref $self;
    if (exists $self->{_ai_cfg} && $self->{_ai_cfg}) {
        return $self->{_ai_cfg};
    }
    require Comserv::Model::AI::Config;
    return $self->{_ai_cfg} = Comserv::Model::AI::Config->new;
}

# Backward compat for all the existing $c->model('AI')->config calls
sub config { shift->ai_config(@_) }

has 'provider' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Provider;
        Comserv::Model::AI::Provider->new;
    },
);

has 'chat' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Chat;
        Comserv::Model::AI::Chat->new;
    },
);

has 'conversation' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Conversation;
        Comserv::Model::AI::Conversation->new;
    },
);

has 'knowledge_base' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::KnowledgeBase;
        Comserv::Model::AI::KnowledgeBase->new;
    },
);

has 'coding' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Coding;
        Comserv::Model::AI::Coding->new;
    },
);

has 'access' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Access;
        Comserv::Model::AI::Access->new;
    },
);

has 'usage' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Usage;
        Comserv::Model::AI::Usage->new;
    },
);

has 'model_manager' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::ModelManager;
        Comserv::Model::AI::ModelManager->new;
    },
);

# Central role-based AI router (like OpenRouter but with membership levels,
# manual override for devs/admins, cost/speed/privacy balancing).
# Thin controllers should call: $c->model('AI')->route(...)
has 'router' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Comserv::Model::AI::Router;
        Comserv::Model::AI::Router->new;
    },
);

# Public delegation method for controllers
sub route {
    my ($self, $c, %args) = @_;
    return $self->router->route_request($c, %args);
}

# Convenience delegation methods (controller can call $c->model('AI')->chat(...) etc.)
sub chat_message {
    my ($self, $c, %args) = @_;
    return $self->chat->process($c, %args);
}

sub get_conversations {
    my ($self, $c, %args) = @_;
    return $self->conversation->list($c, %args);
}

sub get_conversation_messages {
    my ($self, $c, $conv_id) = @_;
    return $self->conversation->get_messages($c, $conv_id);
}

sub log_usage {
    my ($self, $c, %args) = @_;
    return $self->usage->log($c, %args);
}

sub select_model {
    my ($self, $c, %args) = @_;
    return $self->chat->select_model($c, %args);
}

sub build_system_prompt {
    my ($self, $c, $agent_type, %args) = @_;
    return $self->chat->build_system_prompt($c, $agent_type, %args);
}

# Provider management
sub get_available_providers {
    my ($self, $c) = @_;
    return $self->provider->list_available($c);
}

sub get_current_config {
    my ($self, $c, $can_select_model) = @_;
    return $self->config->get_current_ollama_config($c, $can_select_model);
}

sub get_available_models {
    my ($self, $c, %opts) = @_;

    # For now, delegate to existing logic or Router
    if ($self->can('router') && $self->router) {
        return $self->router->get_models($c, %opts) || { local => [] };
    }

    # Fallback
    return {
        local => [],
        host => 'localhost',
        port => 11434,
        current_model => 'llama3'
    };
}

sub _build_page_navigation_hint {
    my ($self, $base_url, $page_path, $page_title, $role) = @_;

    return '' unless $page_path;

    my $context_label = $page_title ? "\"$page_title\" ($page_path)" : $page_path;
    my $hint = "\n\nThe user is currently viewing: $context_label.\n";

    if ($page_path =~ m{/HelpDesk/ticket/new}i) {
        if ($role eq 'admin') {
            $hint .= "NOTE: This page has a HelpDesk pre-screening form, but you are an admin user.\n"
                   . "Answer questions about projects, todos, system state, and application features normally.\n"
                   . "Only switch to support pre-screening mode if the user explicitly describes a support problem.\n";
        } else {
            $hint .= "SUPPORT PRE-SCREENING MODE:\n"
                   . "The user has navigated to the 'Create New Ticket' page but has been invited to\n"
                   . "try the AI assistant FIRST before submitting a ticket.\n"
                   . "Your goal is to RESOLVE the user's issue so they do NOT need to submit a ticket.\n"
                   . "- Listen carefully to their problem description.\n"
                   . "- Provide clear, actionable step-by-step solutions.\n"
                   . "- Check the Knowledge Base: $base_url/HelpDesk/kb\n"
                   . "- If you solve the issue, say so clearly and tell them no ticket is needed.\n"
                   . "- If you CANNOT resolve it after trying, acknowledge this and tell them:\n"
                   . "  'It looks like this needs human support. Click \"Skip AI — Submit Ticket Directly\" on the page to open the ticket form.'\n"
                   . "Do NOT refuse to help or just redirect them to submit a ticket without genuinely trying to solve the problem first.\n";
        }
    } elsif ($page_path =~ m{/HelpDesk}i) {
        $hint .= "Navigation context — HelpDesk:\n"
               . "- Submit a new ticket: $base_url/HelpDesk/ticket/new\n"
               . "- Check ticket status: $base_url/HelpDesk/ticket/status\n"
               . "- Knowledge Base: $base_url/HelpDesk/kb\n"
               . "- Contact support: $base_url/HelpDesk/contact\n";
        $hint .= "- Admin panel: $base_url/HelpDesk/admin\n" if $role eq 'admin';
    } elsif ($page_path =~ m{/Documentation}i) {
        if ($role eq 'admin') {
            $hint .= "Navigation context — Documentation section (admin):\n"
                   . "- You may edit or create documentation pages.\n"
                   . "- Related sections: Daily Plans, Master Plan, Architecture docs.\n"
                   . "- To manage plans: $base_url/planning/daily\n"
                   . "- To view all docs: $base_url/Documentation\n";
        } elsif ($role eq 'user') {
            $hint .= "Navigation context — Documentation section:\n"
                   . "- You can read documentation pages and follow internal links.\n"
                   . "- To search the encyclopedia: $base_url/ency/search?q=TERM\n"
                   . "- To view all docs: $base_url/Documentation\n";
        } else {
            $hint .= "Navigation context — Documentation section (guest):\n"
                   . "- Public documentation is available for reading.\n"
                   . "- Log in for full access and editing capabilities.\n";
        }
    } elsif ($page_path =~ m{/workshop}i) {
        if ($role eq 'admin') {
            $hint .= "Navigation context — Workshops (admin):\n"
                   . "- You can create, edit, and manage workshop entries.\n"
                   . "- Active workshops: $base_url/workshop/list_active\n"
                   . "- All workshops: $base_url/workshop/list\n";
        } elsif ($role eq 'user') {
            $hint .= "Navigation context — Workshops:\n"
                   . "- You can view and participate in workshops.\n"
                   . "- Active workshops: $base_url/workshop/list_active\n";
        } else {
            $hint .= "Navigation context — Workshops (guest):\n"
                   . "- Public workshop information is available for viewing.\n"
                   . "- Log in to participate or manage workshops.\n";
        }
    } elsif ($page_path =~ m{/todo}i) {
        if ($role eq 'admin') {
            $hint .= "Navigation context — Todo / Task Management (admin):\n"
                   . "- You can view, create, assign, and close tasks across all projects.\n"
                   . "- All tasks: $base_url/todo/list\n"
                   . "- Project-specific: $base_url/todo/list?project_id=N (use real numeric ID from live project data — never literal 'ID')\n";
        } elsif ($role eq 'user') {
            $hint .= "Navigation context — Todo / Task Management:\n"
                   . "- You can view tasks assigned to you and update their status.\n"
                   . "- Your tasks: $base_url/todo/list\n";
        } else {
            $hint .= "Navigation context — Tasks (guest):\n"
                   . "- Log in to view and manage tasks.\n";
        }
    } elsif ($page_path =~ m{/project}i) {
        if ($role eq 'admin') {
            $hint .= "Navigation context — Projects (admin):\n"
                   . "- You can create, edit, and archive projects.\n"
                   . "- All projects: $base_url/project/list\n";
        } elsif ($role eq 'user') {
            $hint .= "Navigation context — Projects:\n"
                   . "- You can view projects you are a member of.\n"
                   . "- Projects: $base_url/project/list\n";
        } else {
            $hint .= "Navigation context — Projects (guest):\n"
                   . "- Log in to view project information.\n";
        }
    } elsif ($page_path =~ m{/Inventory/consignment}i) {
        $hint .= "Navigation context — Consignment Tracking:\n"
               . "Consignment = sending items to a partner store; partner sells them and keeps a commission.\n"
               . "- Consignment list:        $base_url/Inventory/consignment\n"
               . "- Create new consignment:  $base_url/Inventory/consignment/new\n"
               . "- Consignment partners:    $base_url/Inventory/consignment/partners\n"
               . "- View/settle:             $base_url/Inventory/consignment/view/<id>\n"
               . "- Full docs:               $base_url/Documentation/Inventory/consignment\n"
               . "WORKFLOW: 1) Set up a partner at /Inventory/consignment/partners\n"
               . "2) Create batch at /Inventory/consignment/new — select partner, enter items + qty + retail price\n"
               . "3) View consignment to print slip or settle when partner pays\n"
               . "4) On settlement: enter qty sold and qty returned per line; optionally post GL entry\n"
               . "Partners: Monashee Arts Council (Lumby), Monashee Coop (30% commission)\n";
    } elsif ($page_path =~ m{/Inventory}i) {
        $hint .= "Navigation context — Inventory:\n"
               . "- Inventory dashboard:    $base_url/Inventory\n"
               . "- Items list:             $base_url/Inventory/items\n"
               . "- Add item:               $base_url/Inventory/item/add\n"
               . "- Suppliers:              $base_url/Inventory/suppliers\n"
               . "- Supplier invoices:      $base_url/Inventory/invoice\n"
               . "- New invoice:            $base_url/Inventory/invoice/new\n"
               . "- Stock transactions:     $base_url/Inventory/stock/transactions\n"
               . "- Customer sales:         $base_url/Inventory/sales\n"
               . "- Consignments:           $base_url/Inventory/consignment\n"
               . "- New consignment:        $base_url/Inventory/consignment/new\n"
               . "- Consignment partners:   $base_url/Inventory/consignment/partners\n"
               . "- Consignment docs:       $base_url/Documentation/Inventory/consignment\n";
    } elsif ($page_path =~ m{/Accounting}i) {
        $hint .= "Navigation context — Accounting:\n"
               . "- Accounting dashboard:   $base_url/Accounting\n"
               . "- Chart of accounts:      $base_url/Accounting/coa\n"
               . "- General ledger:         $base_url/Accounting/gl\n"
               . "- Consignment settlement posts GL: DR AR + Commission / CR Sales Revenue\n"
               . "- For consignment management go to: $base_url/Inventory/consignment\n";
    } elsif ($page_path =~ m{/ency}i) {
        $hint .= "Navigation context — Encyclopedia:\n"
                . "- Search for information: $base_url/ency/search?q=TERM\n";
        $hint .= "- As an admin you can add and edit encyclopedia entries.\n" if $role eq 'admin';
    } elsif ($page_path =~ m{/ai}i) {
        $hint .= "Navigation context — AI Assistant:\n"
               . "- You are currently in the AI chat interface.\n";
        if ($role eq 'admin') {
            $hint .= "- Admin: manage AI models at $base_url/ai/models\n"
                   . "- Manage API keys at $base_url/ai/manage_api_keys\n";
        }
    }

    return $hint;
}

sub _select_model_for_context {
    my ($self, $agent_id, $page_context, $installed_models, $default_model) = @_;

    $agent_id    //= 'general';
    $page_context //= 'general';
    $installed_models //= [];

    # Filter out non-chat models (embeddings, rerankers, etc.) to avoid 400 errors
    my $is_chat_model = sub {
        my ($n) = @_;
        return $n !~ /embed|rerank|bge|nomic|clip|whisper|tts/i;
    };

    # Build a quick lookup: short name → full model name (chat models only)
    my %installed;
    for my $m (@$installed_models) {
        my $name = ref($m) ? ($m->{name} || '') : ($m || '');
        next unless $name;
        next unless $is_chat_model->($name);
        $installed{$name} = $name;
        (my $short = $name) =~ s/:.*$//;
        $installed{$short} = $name;
    }

    # Preferred models per context (ordered: first match wins).
    # tinyllama intentionally excluded — too small for reliable answers.
    my %context_prefs = (
        chat        => ['llama3.1', 'llama3', 'deepseek-r1', 'mistral'],
        helpdesk    => ['llama3.1', 'llama3', 'mistral'],
        ency        => ['phi4', 'llama3.1', 'llama3', 'mistral'],
        bmaster     => ['phi4', 'llama3.1', 'llama3', 'mistral'],
        csc         => ['llama3.1', 'llama3', 'mistral'],
        general     => ['llama3.1', 'llama3', 'mistral'],
        navigation  => ['llama3.1', 'llama3'],
        simple      => ['llama3.1', 'llama3'],
        code        => ['starcoder2', 'qwen2.5-coder', 'qwen-coder', 'codellama', 'llama3.1'],
        developer   => ['starcoder2', 'qwen2.5-coder', 'codellama', 'llama3.1'],
        docker      => ['starcoder2', 'qwen2.5-coder', 'llama3.1'],
    );

    my $ctx = lc($agent_id);
    $ctx = 'helpdesk'   if $ctx =~ /helpdesk/;
    $ctx = 'code'       if $ctx =~ /code|developer|starcoder/;
    $ctx = 'bmaster'    if $ctx =~ /bmast|beekeep|apiar/;
    $ctx = 'csc'        if $ctx =~ /^csc$/;
    $ctx = 'ency'       if $ctx =~ /^ency$/;
    $ctx = 'docker'     if $ctx =~ /docker/;
    $ctx = 'general'    unless exists $context_prefs{$ctx};

    my $prefs = $context_prefs{$ctx} || $context_prefs{general};

    for my $pref (@$prefs) {
        for my $key (keys %installed) {
            if ($key =~ /\Q$pref\E/i) {
                return $installed{$key};
            }
        }
    }

    # Fall back: default_model if installed and is chat-capable, else first available chat model, else hardcoded
    if ($default_model && $is_chat_model->($default_model)) {
        return $default_model if $installed{$default_model} || grep { $_ eq $default_model } values %installed;
    }
    my @chat_values = values %installed;
    return $chat_values[0] if @chat_values;
    return 'llama3.1:latest';
}
sub _get_learned_navigation_additions {
    my ($self, $c, $max) = @_;
    $max //= 8;
    return '' unless $c;

    my $out = '';
    eval {
        my $schema = $c->model('DBEncy')->schema;
        return '' unless $schema;

        my @rows = $schema->resultset('LearnedData')->search(
            { file => 'ai_discovered_link', word => { like => 'ai_link:%' } },
            { order_by => { -desc => 'frequency' }, rows => $max }
        )->all;

        my @items;
        for my $r (@rows) {
            my $w = $r->word || '';
            $w =~ s/^ai_link://;
            next unless $w =~ /^\//;
            my $f = $r->frequency || 1;
            push @items, "  - (observed $f×) $w";
        }
        if (@items) {
            $out = "\nDynamically learned links (observed on pages during recent AI chats — use when relevant):\n"
                 . join("\n", @items) . "\n";
        }
    };
    return $out;
}
__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Comserv::Model::AI - Central facade for all AI functionality

=head1 DESCRIPTION

This model provides a thin, stable API for controllers.
All heavy logic lives in the sub-modules under Comserv::Model::AI::*

Controllers (AI.pm, AIAdmin.pm, Chat.pm, Coding.pm, etc.) should delegate here.

=cut
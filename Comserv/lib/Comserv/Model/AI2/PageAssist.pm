package Comserv::Model::AI2::PageAssist;
# ===================================================================
# AI help for the Pages editor (Nov 5 2026, Shanta approved phases 1-3).
#   assist($c, action => draft|rewrite|format|outline, text, title, page_code)
#   write_page($c, topic, notes, sitename)   -> fields for the Create form
#   suggest_links($c, sitename, text, page_code) -> existing pages (DB only, no AI)
# Output is ALWAYS a preview; this module never writes a page row.
# Models: Super Grok (when its guard is not locked) -> particle-1 -> luna.
# Never Mercury, Seed, paid OpenRouter grok, v4-pro, glm or Relace. Every
# call goes through AI2::Router::dispatch_chat (failover off, so the router
# cannot walk to another model) and is ledgered (log_usage => page_assist;
# OpenRouter calls are ledgered by Provider::OpenRouter itself).
# ===================================================================
use Moose;
use namespace::autoclean;
use JSON;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (is => 'ro', default => sub { Comserv::Util::Logging->instance });

use constant WRITING_MODELS => (
    'supergrok|grok-4.7',
    'openrouter|particle-ai/particle-1',
    'openrouter|openai/gpt-5.6-luna',
);
my $BANNED = qr/mercury|seed|v4-pro|glm|relace|openrouter\|(?:x-ai\/)?grok/i;

my %ACTIONS = (
    draft   => 'Write a first draft of web page content about the given title/notes. Use short sections with <h2> headings, <p> paragraphs and <ul> lists where helpful.',
    rewrite => 'Rewrite the given content so it is clear, friendly and easy to read. Keep every fact, name, number and link. Do not add new facts.',
    format  => 'Tidy the HTML structure of the given content: sensible <h2>/<h3> headings, <p> paragraphs, <ul>/<ol> lists. Keep the wording and every fact and link exactly as written.',
    outline => 'Propose an outline for this page as nested <h2>/<h3> headings, each with one placeholder <p> sentence saying what goes there. Base it on the given title and content.',
);

sub actions { return [ sort keys %ACTIONS ] }

sub allowed_models {
    my ($self) = @_;
    return [ grep { $_ !~ $BANNED } WRITING_MODELS ];
}

# Model chain for this call: skip Super Grok while its guard is locked.
sub model_chain {
    my ($self, $c, %o) = @_;
    my @chain = @{ $self->allowed_models };
    my $router = $o{router} || eval { $c->model('AI2::Router') };
    my $g = ($router && $router->can('supergrok_guard')) ? eval { $router->supergrok_guard($c) } : undef;
    @chain = grep { !/^supergrok\|/ } @chain if $g && $g->{locked};
    return \@chain;
}

sub _call {
    my ($self, $c, $system, $user, %o) = @_;
    my $router = $o{router} || $c->model('AI2::Router');
    my @tried;
    for my $m (@{ $self->model_chain($c, router => $router) }) {
        next if $m =~ $BANNED;
        my $resp = eval {
            $router->dispatch_chat($c, $m, [
                { role => 'system', content => $system },
                { role => 'user',   content => $user },
            ], can_select => 1, failover => 0, purpose => 'page_assist',
               request_type => 'page_assist', log_usage => 'page_assist');
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'page_assist', "dispatch $m threw: $@");
        }
        if ($resp && $resp->{success} && defined $resp->{response} && $resp->{response} =~ /\S/) {
            my $used = join('|', grep { defined } $resp->{provider}, $resp->{model});
            if ($used =~ $BANNED) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'page_assist', "discarded reply from disallowed model $used");
                push @tried, $m; next;
            }
            return { success => 1, response => $resp->{response}, model => $used || $m, tried => \@tried };
        }
        push @tried, $m;
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'page_assist',
            "model $m failed: " . (($resp && $resp->{error}) // 'no response'));
    }
    return { success => 0, error => 'No writing model is available right now (Super Grok, particle-1 and luna all failed or are locked). Please try again later.', tried => \@tried };
}

# Strip anything a page body must not carry from an AI reply.
sub clean_html {
    my ($self, $html) = @_;
    $html //= '';
    $html =~ s/^\s*```(?:html)?\s*//i; $html =~ s/\s*```\s*$//;
    $html =~ s{<script\b.*?</script\s*>}{}gis;
    $html =~ s{<(iframe|object|embed|style)\b.*?(?:</\1\s*>|/?>)}{}gis;
    $html =~ s{\son\w+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)}{}gi;
    $html =~ s{(href|src)\s*=\s*(["'])\s*javascript:[^"']*\2}{$1="#"}gi;
    $html =~ s/^\s+|\s+$//g;
    return $html;
}

sub assist {
    my ($self, $c, %in) = @_;
    my $action = lc($in{action} // '');
    return { success => 0, error => "Unknown action '$action'" } unless $ACTIONS{$action};
    my $text = $in{text} // '';
    return { success => 0, error => 'Select some text or add page content first.' }
        if $action =~ /^(rewrite|format)$/ && $text !~ /\S/;
    $text = substr($text, 0, 20000);
    my $system = "You help write pages for a website. $ACTIONS{$action} "
               . 'Reply with ONLY the HTML fragment (no <html>, <head>, <body>, <script> or <style>, no markdown, no explanation).';
    my $user = 'Page title: ' . ($in{title} // '') . "\n"
             . ($in{notes} ? "Notes: $in{notes}\n" : '')
             . "Content:\n$text";
    my $r = $self->_call($c, $system, $user, %in);
    return $r unless $r->{success};
    my $html = $self->clean_html($r->{response});
    return { success => 0, error => 'The model returned nothing usable.' } unless $html =~ /\S/;
    return { success => 1, html => $html, model => $r->{model}, action => $action };
}

sub _slug {
    my ($s) = @_; $s = lc($s // ''); $s =~ s/[^a-z0-9]+/_/g; $s =~ s/^_+|_+$//g;
    return substr($s, 0, 60);
}

sub parse_write_reply {
    my ($self, $raw) = @_;
    $raw //= '';
    $raw =~ s/^\s*```(?:json)?\s*//i; $raw =~ s/\s*```\s*$//;
    my ($json) = $raw =~ /(\{.*\})/s;
    my $d = $json ? eval { JSON->new->relaxed->decode($json) } : undef;
    return unless ref $d eq 'HASH' && ($d->{body} // '') =~ /\S/;
    return $d;
}

sub write_page {
    my ($self, $c, %in) = @_;
    my $topic = $in{topic} // '';
    return { success => 0, error => 'Tell me what the page is about.' } unless $topic =~ /\S/;
    my $system = 'You write complete, well-structured website pages. Reply with ONLY a JSON object with keys: '
               . 'title (short), page_code (lowercase_with_underscores), description (one sentence, under 160 characters), '
               . 'keywords (comma separated), body (HTML fragment using <h2>, <h3>, <p>, <ul>; no <script>, <style>, <html> or <body>). '
               . 'Use only facts from the notes; where facts are missing write a clear [placeholder].';
    my $user = "Site: " . ($in{sitename} // '') . "\nTopic: $topic\nNotes:\n" . substr($in{notes} // '', 0, 8000);
    my $r = $self->_call($c, $system, $user, %in);
    return $r unless $r->{success};
    my $d = $self->parse_write_reply($r->{response})
        or return { success => 0, error => 'The model reply was not in the expected format. Please try again.', model => $r->{model} };
    my %out = (
        title       => substr($d->{title} // $topic, 0, 255),
        page_code   => _slug($d->{page_code} || $d->{title} || $topic),
        description => substr($d->{description} // '', 0, 255),
        keywords    => substr($d->{keywords} // '', 0, 255),
        body        => $self->clean_html($d->{body}),
    );
    return { success => 1, page => \%out, model => $r->{model} };
}

# Existing pages on the site that the content could link to. DB only.
sub suggest_links {
    my ($self, $c, %in) = @_;
    my $site = $in{sitename} || 'CSC';
    my @rows = eval {
        $c->model('DBEncy')->resultset('Page')->search(
            { sitename => $site, status => 'active',
              ($in{page_code} ? (page_code => { '!=' => $in{page_code} }) : ()) },
            { columns => [qw/page_code title menu submenu link_order description/],
              order_by => [qw/menu link_order/], rows => 500 })->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'suggest_links', "page search failed: $@");
        return { success => 0, error => 'Could not read the page list.' };
    }
    my $text = lc(($in{text} // '') . ' ' . ($in{title} // ''));
    $text =~ s/<[^>]+>/ /g;
    my %words = map { $_ => 1 } grep { length > 3 } split /[^a-z0-9]+/, $text;
    my (@links, %menus);
    for my $p (@rows) {
        my $t = $p->title // $p->page_code;
        my @tw = grep { length > 3 } split /[^a-z0-9]+/, lc($t . ' ' . ($p->description // ''));
        my $score = grep { $words{$_} } @tw;
        $menus{ $p->menu // '' }{ $p->submenu // '' } += $score;
        push @links, { page_code => $p->page_code, title => $t, url => '/page/' . $p->page_code,
                       menu => $p->menu, submenu => ($p->submenu // ''), score => $score + 0 };
    }
    @links = sort { $b->{score} <=> $a->{score} || lc $a->{title} cmp lc $b->{title} } @links;
    my ($best_menu, $best_sub, $best) = ('main', '', -1);
    for my $m (keys %menus) { for my $s (keys %{ $menus{$m} }) {
        ($best_menu, $best_sub, $best) = ($m, $s, $menus{$m}{$s}) if $menus{$m}{$s} > $best;
    } }
    my $max_order = 0;
    for my $p (@rows) { next unless ($p->menu // '') eq $best_menu; $max_order = $p->link_order if ($p->link_order // 0) > $max_order }
    return { success => 1, links => [ @links[0 .. ($#links < 29 ? $#links : 29)] ],
             placement => { menu => $best_menu, submenu => $best_sub, link_order => $max_order + 10 } };
}

__PACKAGE__->meta->make_immutable;
1;

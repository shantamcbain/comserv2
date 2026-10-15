package Comserv::Util::AI::HarmRefusal;

# Local refusal before any model call. Not a police scanner and not a
# keyword net over herbal chat. A hit means: do not send the prompt, do not
# fall through to another provider, do not log the body, do not freeze delete.
#
# Categories: harm to a person, a weapon built to hurt people, sexual
# exploitation of a child, and a request for a method of suicide.
# Herbal, garden, beekeeping pest, and plant-safety questions are not hits.

use strict;
use warnings;

sub classify {
    my ($text) = @_;
    return undef unless defined $text && $text =~ /\S/;
    my $t = lc $text;
    $t =~ s/\s+/ /g;

    return { category => 'child_exploitation' } if _child_exploitation($t);
    return { category => 'weapon_harm' }        if _weapon_harm($t);
    return { category => 'self_harm_method' }   if _self_harm_method($t);
    return { category => 'harm_to_person' }     if _harm_to_person($t);
    return undef;
}

sub classify_turn {
    my ($prompt, $history) = @_;
    my $hit = classify($prompt);
    return $hit if $hit;
    return scan_messages($history);
}

sub scan_messages {
    my ($messages) = @_;
    return undef unless ref $messages eq 'ARRAY';
    for my $m (@$messages) {
        next unless ref $m eq 'HASH';
        my $role = lc($m->{role} // 'user');
        next if $role eq 'system' || $role eq 'developer' || $role eq 'assistant';
        my $hit = classify(_content_text($m->{content}));
        return $hit if $hit;
    }
    return undef;
}

sub refusal_text {
    my ($hit) = @_;
    my $cat = ref $hit eq 'HASH' ? ($hit->{category} // '') : '';
    if ($cat eq 'self_harm_method') {
        return "I can't help with that. If you are in crisis, call or text 988 (Canada or the US). You are not alone.";
    }
    return "I can't help with that. This app does not answer requests to harm another person, "
         . "exploit a child, or build a weapon to hurt people. Herbal and health questions are still welcome.";
}

sub reply_hash {
    my ($hit) = @_;
    $hit = ref $hit eq 'HASH' ? $hit : { category => 'harm_to_person' };
    return {
        success  => 1,
        refused  => 1,
        category => $hit->{category},
        response => refusal_text($hit),
        provider => 'local-refusal',
        model    => 'harm-refusal',
    };
}

sub log_line {
    my ($hit, $user_id) = @_;
    my $cat = ref $hit eq 'HASH' ? ($hit->{category} // 'harm') : 'harm';
    return 'Harm refusal category=' . $cat
         . ' user_id=' . (defined $user_id ? $user_id : '?')
         . ' (body not logged; not sent to a provider)';
}

sub _content_text {
    my ($content) = @_;
    return '' unless defined $content;
    return $content unless ref $content;
    return '' unless ref $content eq 'ARRAY';
    my @bits;
    for my $part (@$content) {
        if (!ref $part) {
            push @bits, $part;
            next;
        }
        next unless ref $part eq 'HASH';
        push @bits, $part->{text} if defined $part->{text};
    }
    return join ' ', @bits;
}

sub _child_exploitation {
    my ($t) = @_;
    return 1 if $t =~ /\b(?:csam|child pornography|child porn)\b/;
    my $minor = qr/(?:child|children|minor|underage|toddler|preteen|pre-teen)/;
    my $sexual = qr/(?:porn|nude|naked|molest)/;
    return 1 if $t =~ /$minor.{0,40}$sexual|$sexual.{0,40}$minor/;
    if ($t =~ /\b(\d{1,2})\s*(?:year|yr)s?\s*old\b/ && $t =~ /\b(?:porn|nude|naked|molest|sexual)\b/) {
        return 1 if $1 < 18;
    }
    return 0;
}

sub _weapon_harm {
    my ($t) = @_;
    return 0 if $t =~ /bath bomb|seed bomb/;
    return 1 if $t =~ /how (?:do i|to|can i).{0,48}(?:make|build|construct|assemble).{0,30}(?:\bbomb\b|explosive|molotov|grenade)/;
    return 1 if $t =~ /how (?:do i|to|can i).{0,40}(?:make|build).{0,24}pipe bomb/;
    return 1 if $t =~ /how (?:do i|to|can i).{0,40}(?:make|build|synthesize).{0,24}(?:chemical weapon|biological weapon|nerve agent)/;
    return 0;
}

sub _self_harm_method {
    my ($t) = @_;
    return 1 if $t =~ /how (?:do i|to|can i) (?:kill myself|commit suicide|end my life|hang myself)/;
    return 1 if $t =~ /\bsuicide method\b/;
    return 1 if $t =~ /how (?:do i|to) overdose\b/;
    return 0;
}

sub _harm_to_person {
    my ($t) = @_;
    my $person  = qr/\b(?:person|people|someone|somebody|neighbor|neighbour|wife|husband|boyfriend|girlfriend|classmate|teacher|coworker|co-worker|stranger|boss)\b/;
    my $pronoun = qr/\b(?:him|her|them)\b/;
    my $pest    = qr/\b(?:aphid|aphids|mite|mites|varroa|weed|weeds|slug|slugs|pest|pests|mouse|mice|rat|rats|mold|mould|fungus|bug|bugs|beetle|larva|larvae|deer|rabbit|rabbits)\b/;
    my $harm    = qr/\b(?:kill|murder|assassinate|stab|strangle|shoot|poison|beat up|assault)\b/;
    my $hurt    = qr/\b(?:hurt|injure|maim)\b/;
    my $ask     = qr/(?:how (?:do i|to|can i)|help me|tell me how|steps to|instructions (?:for|to)|guide to|i (?:want|plan|am going) to|gonna)/;

    return 1 if $t =~ /(?:plan|planning|help me).{0,40}(?:attack|shoot up|bomb).{0,30}(?:school|church|mosque|synagogue|crowd|people|office|mall)/;
    return 1 if $t =~ /how (?:do i|to|can i).{0,30}(?:shoot up|attack).{0,24}(?:school|church|crowd|people)/;

    return 0 if $t =~ $pest && $t !~ $person && $t !~ $pronoun;

    return 1 if $t =~ /(?:kill|murder|assassinate|stab|strangle|shoot|poison|assault|beat up)\s+(?:my|his|her|their|a|the)\s+(?:wife|husband|neighbor|neighbour|boss|teacher|classmate|coworker|child|kid|friend|ex)\b/;
    return 1 if $t =~ $ask && $t =~ $harm && ($t =~ $person || $t =~ $pronoun);
    return 1 if $t =~ $ask && $t =~ $hurt && $t =~ $person;
    return 0;
}

1;

package Comserv::Model::AI::ConversationScope;
# Shared guest/user scoping for AI conversation list + message access.
use strict;
use warnings;
use Exporter 'import';
use JSON;

our @EXPORT_OK = qw(
    is_guest_session
    ensure_guest_session_id
    conversation_owned_by_session
    guest_meta_ok
);

sub is_guest_session {
    my ($c) = @_;
    return 1 unless $c;
    my $u = eval { $c->session->{username} } // '';
    return 1 if !length($u) || lc($u) eq 'guest' || $u =~ /^Guest-/i;
    return 0;
}

sub ensure_guest_session_id {
    my ($c) = @_;
    return '' unless $c;
    my $gid = eval { $c->session->{guest_session_id} } // '';
    if (!length $gid && is_guest_session($c)) {
        require Data::UUID;
        $gid = Data::UUID->new->create_str();
        $c->session->{guest_session_id} = $gid;
    }
    return $gid // '';
}

sub guest_meta_ok {
    my ($metadata_json, $guest_session_id) = @_;
    return 0 unless defined $guest_session_id && length $guest_session_id;
    my $meta = {};
    eval { $meta = decode_json($metadata_json || '{}'); };
    return 0 if $@;
    my $mid = $meta->{guest_session_id} // '';
    return (length($mid) && $mid eq $guest_session_id) ? 1 : 0;
}

# True when this session may see/load the conversation row.
sub conversation_owned_by_session {
    my ($c, $conv) = @_;
    return 0 unless $c && $conv;
    my $is_guest = is_guest_session($c);
    my $user_id  = eval { $c->session->{user_id} };
    if ($is_guest) {
        $user_id = 199 unless defined $user_id;
        my $gid = ensure_guest_session_id($c);
        return 0 unless defined $conv->user_id && $conv->user_id == $user_id;
        return guest_meta_ok($conv->metadata, $gid);
    }
    return 0 unless defined $user_id;
    return (defined $conv->user_id && $conv->user_id == $user_id) ? 1 : 0;
}

1;

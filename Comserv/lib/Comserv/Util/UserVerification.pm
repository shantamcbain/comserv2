package Comserv::Util::UserVerification;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Digest::SHA qw(sha256_hex);
use DateTime;
use DateTime::Format::MySQL;

sub generate_verification_code {
    my ($self) = @_;
    
    return sprintf('%06d', int(rand(1000000)));
}

sub generate_reset_token {
    my ($self) = @_;
    
    my @chars = ('0'..'9', 'a'..'f');
    my $token = '';
    $token .= $chars[rand @chars] for 1..32;
    
    return $token;
}

sub create_verification_code {
    my ($self, $user, $code) = @_;
    
    my $code_hash = sha256_hex($code);
    
    my $now = DateTime->now;
    my $expires_at = $now->clone->add(hours => 24);
    
    my $verification_record = $user->create_related('verification_codes', {
        code_hash => $code_hash,
        expires_at => $expires_at->strftime('%Y-%m-%d %H:%M:%S'),
    });
    
    return $verification_record;
}

sub verify_code {
    my ($self, $user, $code) = @_;
    
    my $code_hash = sha256_hex($code);
    
    my $verification_record = $user->verification_codes->search({
        code_hash => $code_hash,
        verified_at => undef,
    })->first;
    
    return unless $verification_record;
    
    return if $self->is_expired($verification_record);
    
    $verification_record->update({
        verified_at => DateTime->now->strftime('%Y-%m-%d %H:%M:%S'),
    });
    
    return $verification_record;
}

sub create_reset_token {
    my ($self, $user, $token) = @_;
    
    my $token_hash = sha256_hex($token);
    
    my $now = DateTime->now;
    my $expires_at = $now->clone->add(hours => 24);
    
    my $reset_record = $user->create_related('password_reset_tokens', {
        token_hash => $token_hash,
        expires_at => $expires_at->strftime('%Y-%m-%d %H:%M:%S'),
    });
    
    return $reset_record;
}

sub verify_reset_token {
    my ($self, $schema, $token) = @_;
    
    my $token_hash = sha256_hex($token);
    
    my $reset_record = $schema->resultset('PasswordResetToken')->search({
        token_hash => $token_hash,
        used_at => undef,
    })->first;
    
    return unless $reset_record;
    
    return if $self->is_expired($reset_record);
    
    return $reset_record;
}

sub is_expired {
    my ($self, $record) = @_;
    
    return 1 unless $record;
    
    my $expires_at = $record->expires_at;
    
    return unless $expires_at;
    
    my $now = DateTime->now;
    my $expiry_dt;
    
    if (ref($expires_at) && $expires_at->isa('DateTime')) {
        $expiry_dt = $expires_at;
    } else {
        my $parser = DateTime::Format::MySQL->new;
        $expiry_dt = $parser->parse_datetime($expires_at);
    }
    
    return DateTime->compare($now, $expiry_dt) > 0;
}

__PACKAGE__->meta->make_immutable;

1;

package Comserv::Model::Schema::Ency::Result::WebSearchResult;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('web_search_results');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    query => {
        data_type => 'varchar',
        size => 500,
        is_nullable => 0,
    },
    result_title => {
        data_type => 'varchar',
        size => 512,
        is_nullable => 0,
    },
    result_url => {
        data_type => 'varchar',
        size => 1000,
        is_nullable => 0,
    },
    result_snippet => {
        data_type => 'longtext',
        is_nullable => 0,
    },
    full_content => {
        data_type => 'longtext',
        is_nullable => 1,
    },
    source_type => {
        data_type => 'enum',
        extra => { list => ['web', 'public_domain_book', 'arxiv', 'github', 'stackoverflow'] },
        default_value => 'web',
        is_nullable => 0,
    },
    found_by_user_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    is_verified => {
        data_type => 'boolean',
        default_value => 0,
        is_nullable => 0,
    },
    verified_by_user_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    verification_notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    verified_at => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    used_in_ai_message_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# Relationships
__PACKAGE__->belongs_to(
    'found_by_user' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.found_by_user_id' }
);

__PACKAGE__->belongs_to(
    'verified_by_user' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.verified_by_user_id' },
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    'ai_message' => 'Comserv::Model::Schema::Ency::Result::AiMessage',
    { 'foreign.id' => 'self.used_in_ai_message_id' },
    { join_type => 'left' }
);

# Helper methods
sub is_pending_verification {
    my $self = shift;
    return !$self->is_verified;
}

sub can_be_verified {
    my ($self, $user_role) = @_;
    return $user_role eq 'admin';
}

sub mark_as_verified {
    my ($self, $user_id, $notes) = @_;
    $self->is_verified(1);
    $self->verified_by_user_id($user_id);
    $self->verified_at(\DateTime->now);
    $self->verification_notes($notes) if defined $notes;
    return $self->update;
}

sub mark_as_rejected {
    my ($self, $user_id, $notes) = @_;
    $self->is_verified(-1);
    $self->verified_by_user_id($user_id);
    $self->verified_at(\DateTime->now);
    $self->verification_notes($notes) if defined $notes;
    return $self->update;
}

1;
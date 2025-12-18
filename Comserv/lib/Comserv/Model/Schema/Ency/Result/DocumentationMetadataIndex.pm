package Comserv::Model::Schema::Ency::Result::DocumentationMetadataIndex;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('documentation_metadata_index');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    file_path => {
        data_type => 'varchar',
        size => 512,
        is_nullable => 0,
    },
    file_type => {
        data_type => 'enum',
        extra => { list => ['tt', 'md'] },
        is_nullable => 0,
    },
    title => {
        data_type => 'varchar',
        size => 512,
        is_nullable => 0,
    },
    excerpt => {
        data_type => 'text',
        is_nullable => 1,
    },
    searchable_text => {
        data_type => 'longtext',
        is_nullable => 0,
    },
    content_hash => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 0,
    },
    role_access => {
        data_type => 'json',
        is_nullable => 1,
    },
    indexed_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    last_file_modified => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    file_size => {
        data_type => 'integer',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['file_path']);

eval {
    __PACKAGE__->add_index(['content_hash']);
};
if ($@) {
    warn "[DocumentationMetadataIndex] Could not add index on content_hash: $@\n";
}

eval {
    __PACKAGE__->add_index(['file_type']);
};
if ($@) {
    warn "[DocumentationMetadataIndex] Could not add index on file_type: $@\n";
}

# Relationships to AI messages that cited this doc
__PACKAGE__->has_many(
    'ai_citations' => 'Comserv::Model::Schema::Ency::Result::AiMessage',
    sub {
        my $args = shift;
        return {
            "$args->{foreign_alias}.sources_cited" => { like => '%' . $args->{self_alias}.file_path . '%' }
        };
    }
);

# Helper methods
sub get_accessible_by_roles {
    my $self = shift;
    my $role_access = $self->role_access;
    return $role_access ? (ref $role_access eq 'ARRAY' ? $role_access : [$role_access]) : [];
}

sub can_user_access {
    my ($self, $user_roles) = @_;
    my @accessible = @{ $self->get_accessible_by_roles };
    return 1 unless @accessible;
    
    for my $role (@$user_roles) {
        return 1 if grep { $_ eq $role || $_ eq '*' } @accessible;
    }
    return 0;
}

sub is_content_stale {
    my $self = shift;
    return 0 unless $self->last_file_modified;
    
    my $now = DateTime->now;
    my $modified = $self->last_file_modified;
    my $duration = $now - $modified;
    
    return $duration->in_units('hours') >= 24;
}

1;
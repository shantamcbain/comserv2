package Comserv::Model::Schema::Ency::Result::CodeSearchIndex;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('code_search_index');
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
        extra => { list => ['pm', 'tt', 'sql'] },
        is_nullable => 0,
    },
    code_elements => {
        data_type => 'json',
        is_nullable => 1,
    },
    searchable_code => {
        data_type => 'longtext',
        is_nullable => 0,
    },
    content_hash => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 0,
    },
    indexed_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    min_role => {
        data_type => 'enum',
        extra => { list => ['developer', 'admin'] },
        is_nullable => 0,
    },
    file_size => {
        data_type => 'integer',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['file_path']);

# Helper methods
sub get_code_elements {
    my $self = shift;
    my $elements = $self->code_elements;
    return $elements ? (ref $elements eq 'HASH' ? $elements : {}) : {};
}

sub get_functions {
    my $self = shift;
    my $elements = $self->get_code_elements;
    return $elements->{functions} ? (ref $elements->{functions} eq 'ARRAY' ? $elements->{functions} : [$elements->{functions}]) : [];
}

sub get_classes {
    my $self = shift;
    my $elements = $self->get_code_elements;
    return $elements->{classes} ? (ref $elements->{classes} eq 'ARRAY' ? $elements->{classes} : [$elements->{classes}]) : [];
}

sub get_variables {
    my $self = shift;
    my $elements = $self->get_code_elements;
    return $elements->{variables} ? (ref $elements->{variables} eq 'ARRAY' ? $elements->{variables} : [$elements->{variables}]) : [];
}

sub is_accessible_by_role {
    my ($self, $user_role) = @_;
    my $min_role = $self->min_role;
    
    return 1 if $user_role eq 'admin';
    return 1 if $user_role eq 'developer' && $min_role eq 'developer';
    return 0;
}

1;
package Comserv::Model::Schema::Ency::Result::DocumentationRoleAccess;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('documentation_role_access');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    role => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
    },
    doc_section_pattern => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    can_access => {
        data_type => 'boolean',
        default_value => 1,
        is_nullable => 0,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['role', 'doc_section_pattern']);

# Helper methods
sub matches_doc_path {
    my ($self, $doc_path) = @_;
    my $pattern = $self->doc_section_pattern;
    
    my $regex_pattern = $pattern;
    $regex_pattern =~ s/\*/.*/g;
    $regex_pattern = "^$regex_pattern\$";
    
    return $doc_path =~ /$regex_pattern/;
}

sub grants_access {
    my $self = shift;
    return $self->can_access;
}

1;
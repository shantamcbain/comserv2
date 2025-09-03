package Comserv::Model::Schema::Ency::Result::Navigation;

use base 'DBIx::Class::Core';

__PACKAGE__->table('navigation');

__PACKAGE__->add_columns(
    'id' => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    'page_id' => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    'menu' => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'parent_id' => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    'order' => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    'is_private' => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'page',
    'Comserv::Model::Schema::Ency::Result::Page',
    { 'foreign.id' => 'self.page_id' },
    { is_deferrable => 1, on_delete => 'CASCADE', on_update => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'parent',
    'Comserv::Model::Schema::Ency::Result::Navigation',
    { 'foreign.id' => 'self.parent_id' },
    { join_type => 'LEFT' }
);

__PACKAGE__->has_many(
    'children',
    'Comserv::Model::Schema::Ency::Result::Navigation',
    { 'foreign.parent_id' => 'self.id' },
    { cascade_delete => 0 }
);

# Helper methods for navigation visibility
sub is_public {
    my $self = shift;
    return $self->is_private ? 0 : 1;
}

sub should_display_for_user {
    my ($self, $user_logged_in) = @_;
    
    # Public items are always displayed
    return 1 if $self->is_public;
    
    # Private items only shown to logged-in users
    return $user_logged_in ? 1 : 0;
}

1;
package Comserv::Model::Schema::Ency::Result::TodoDependency;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('todo_dependency');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    dependent_todo_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    blocking_todo_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    dependency_type => {
        data_type => 'enum',
        extra => { list => ['blocks', 'relates_to', 'duplicates'] },
        default_value => 'blocks',
        is_nullable => 0,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['dependent_todo_id', 'blocking_todo_id']);

__PACKAGE__->belongs_to(
    'dependent_todo' => 'Comserv::Model::Schema::Ency::Result::Todo',
    'dependent_todo_id',
    { on_delete => 'cascade' }
);

__PACKAGE__->belongs_to(
    'blocking_todo' => 'Comserv::Model::Schema::Ency::Result::Todo',
    'blocking_todo_id',
    { on_delete => 'cascade' }
);

sub is_blocking {
    my $self = shift;
    return $self->dependency_type eq 'blocks';
}

sub validate_no_circular {
    my ($self, $schema) = @_;
    my $dependent_id = $self->dependent_todo_id;
    my $blocking_id = $self->blocking_todo_id;
    
    return 0 if $dependent_id == $blocking_id;
    
    my %visited = ();
    my @queue = ($blocking_id);
    
    while (@queue) {
        my $current = shift @queue;
        return 0 if $current == $dependent_id;
        next if $visited{$current};
        $visited{$current} = 1;
        
        my @dependencies = $schema->resultset('TodoDependency')->search({
            dependent_todo_id => $current,
            dependency_type => 'blocks'
        })->all;
        
        push @queue, map { $_->blocking_todo_id } @dependencies;
    }
    
    return 1;
}

1;

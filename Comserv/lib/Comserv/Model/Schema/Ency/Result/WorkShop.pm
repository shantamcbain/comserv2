package Comserv::Model::Schema::Ency::Result::WorkShop;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components("TimeStamp");
__PACKAGE__->table('workshop');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar',
    },
    title => {
        data_type => 'varchar',
        size => 255,
    },
    description => {
        data_type => 'text',
    },
    date => {
        data_type => 'datetime',
    },
    end_time => {
        data_type => 'time',
    },
    time => {
        data_type => 'time',
    },
    location => {
        data_type => 'varchar',
        size => 255,
    },
    instructor => {
        data_type => 'varchar',
        size => 255,
    },
    share => {
        data_type => 'enum',
        default_value => 'private',
        extra => {
            list => ['public', 'private']
        },
    },
    max_participants => {
        data_type => 'integer',
        is_nullable => 1,
    },
    status => {
        data_type => 'enum',
        default_value => 'draft',
        extra => {
            list => ['draft', 'published', 'registration_closed', 'in_progress', 'completed', 'cancelled']
        },
    },
    created_by => {
        data_type => 'integer',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    registration_deadline => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    site_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    { 'foreign.id' => 'self.site_id' },
    { join_type => 'left' },
);

__PACKAGE__->belongs_to(
    creator => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.created_by' },
    { join_type => 'left' },
);

__PACKAGE__->has_many(
    files => 'Comserv::Model::Schema::Ency::Result::File',
    { 'foreign.workshop_id' => 'self.id' },
);

__PACKAGE__->has_many(
    participants => 'Comserv::Model::Schema::Ency::Result::Participant',
    { 'foreign.workshop_id' => 'self.id' },
);

__PACKAGE__->has_many(
    content => 'Comserv::Model::Schema::Ency::Result::WorkshopContent',
    { 'foreign.workshop_id' => 'self.id' },
);

__PACKAGE__->has_many(
    emails => 'Comserv::Model::Schema::Ency::Result::WorkshopEmail',
    { 'foreign.workshop_id' => 'self.id' },
);

__PACKAGE__->has_many(
    site_associations => 'Comserv::Model::Schema::Ency::Result::SiteWorkshop',
    { 'foreign.workshop_id' => 'self.id' },
);

sub current_participants {
    my ($self) = @_;
    return $self->participants->search({ status => 'registered' })->count;
}

sub is_full {
    my ($self) = @_;
    return 0 unless defined $self->max_participants;
    return $self->current_participants >= $self->max_participants;
}

sub can_register {
    my ($self) = @_;
    return 0 if $self->status ne 'published';
    return 0 if $self->registration_deadline && $self->registration_deadline < DateTime->now;
    return 1;
}

1;
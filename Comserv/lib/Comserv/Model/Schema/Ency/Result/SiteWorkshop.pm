package Comserv::Model::Schema::Ency::Result::SiteWorkshop;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components("TimeStamp");
__PACKAGE__->table('site_workshop');

__PACKAGE__->add_columns(
    site_id => {
        data_type => 'integer',
    },
    workshop_id => {
        data_type => 'integer',
    },
);

__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    { 'foreign.id' => 'self.site_id' },
);

__PACKAGE__->belongs_to(
    workshop => 'Comserv::Model::Schema::Ency::Result::WorkShop',
    { 'foreign.id' => 'self.workshop_id' },
);

1;
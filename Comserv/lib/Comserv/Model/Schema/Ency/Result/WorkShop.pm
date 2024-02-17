package Comserv::Model::Schema::Ency::Result::WorkShop;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components("TimeStamp");
__PACKAGE__->table('workshop');
# Add your columns and relationships here

1;git add .
git commit -m "Created WorkShop branch, added WorkShop result class, and made additional changes"
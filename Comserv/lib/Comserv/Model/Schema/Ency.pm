use utf8;
package Comserv::Model::Schema::Ency;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE
our $VERSION = '2';
use Moose;
use MooseX::MarkAsMethods autoclean => 1;
extends 'DBIx::Class::Schema';

__PACKAGE__->load_namespaces;
__PACKAGE__->register_class('ProjectSite', 'Comserv::Model::Schema::Ency::Result::ProjectSite');
__PACKAGE__->register_class('NetworkDevice', 'Comserv::Model::Schema::Ency::Result::NetworkDevice');
__PACKAGE__->register_class('Page', 'Comserv::Model::Schema::Ency::Result::Page');

# Created by DBIx::Class::Schema::Loader v0.07051 @ 2024-02-10 06:41:40
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:mVufLKsHMeSer486KG6RQA

# You can replace this text with custom code or comments, and it will be preserved on regeneration
__PACKAGE__->meta->make_immutable(inline_constructor => 0);
1;

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

# Explicitly register the User result class for authentication
__PACKAGE__->register_class('User', 'Comserv::Model::Schema::Ency::Result::User');

# Register AI conversation system classes
__PACKAGE__->register_class('AiConversation', 'Comserv::Model::Schema::Ency::Result::AiConversation');
__PACKAGE__->register_class('AiMessage', 'Comserv::Model::Schema::Ency::Result::AiMessage');
__PACKAGE__->register_class('ProjectDocumentationMapping', 'Comserv::Model::Schema::Ency::Result::ProjectDocumentationMapping');
__PACKAGE__->register_class('ApiToken', 'Comserv::Model::Schema::Ency::Result::ApiToken');
__PACKAGE__->register_class('UserApiKeys', 'Comserv::Model::Schema::Ency::Result::UserApiKeys');

# Register Workshop system classes
__PACKAGE__->register_class('WorkshopContent', 'Comserv::Model::Schema::Ency::Result::WorkshopContent');
__PACKAGE__->register_class('WorkshopEmail', 'Comserv::Model::Schema::Ency::Result::WorkshopEmail');
__PACKAGE__->register_class('WorkshopRole', 'Comserv::Model::Schema::Ency::Result::WorkshopRole');
__PACKAGE__->register_class('SiteWorkshop', 'Comserv::Model::Schema::Ency::Result::SiteWorkshop');
__PACKAGE__->register_class('WorkshopResource', 'Comserv::Model::Schema::Ency::Result::WorkshopResource');

__PACKAGE__->register_class('SystemLog', 'Comserv::Model::Schema::Ency::Result::SystemLog');

__PACKAGE__->meta->make_immutable(inline_constructor => 0);
1;

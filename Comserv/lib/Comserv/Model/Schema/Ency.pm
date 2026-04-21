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
__PACKAGE__->register_class('SystemLog', 'Comserv::Model::Schema::Ency::Result::SystemLog');
__PACKAGE__->register_class('HealthAlert', 'Comserv::Model::Schema::Ency::Result::HealthAlert');
__PACKAGE__->register_class('SiteConfig', 'Comserv::Model::Schema::Ency::Result::SiteConfig');

# Register Workshop system classes
__PACKAGE__->register_class('WorkshopContent', 'Comserv::Model::Schema::Ency::Result::WorkshopContent');
__PACKAGE__->register_class('WorkshopEmail', 'Comserv::Model::Schema::Ency::Result::WorkshopEmail');
__PACKAGE__->register_class('WorkshopRole', 'Comserv::Model::Schema::Ency::Result::WorkshopRole');
__PACKAGE__->register_class('SiteWorkshop', 'Comserv::Model::Schema::Ency::Result::SiteWorkshop');
__PACKAGE__->register_class('WorkshopResource', 'Comserv::Model::Schema::Ency::Result::WorkshopResource');
__PACKAGE__->register_class('WorkshopMailTemplate', 'Comserv::Model::Schema::Ency::Result::WorkshopMailTemplate');

# Register Membership system classes
__PACKAGE__->register_class('MembershipPlan', 'Comserv::Model::Schema::Ency::Result::MembershipPlan');
__PACKAGE__->register_class('MembershipPlanPricing', 'Comserv::Model::Schema::Ency::Result::MembershipPlanPricing');
__PACKAGE__->register_class('UserMembership', 'Comserv::Model::Schema::Ency::Result::UserMembership');
__PACKAGE__->register_class('MembershipServiceAccess', 'Comserv::Model::Schema::Ency::Result::MembershipServiceAccess');
__PACKAGE__->register_class('MembershipTransaction', 'Comserv::Model::Schema::Ency::Result::PaymentTransaction');
__PACKAGE__->register_class('SystemCostTracking', 'Comserv::Model::Schema::Ency::Result::SystemCostTracking');

__PACKAGE__->register_class('MembershipPromoCode', 'Comserv::Model::Schema::Ency::Result::MembershipPromoCode');

# Register unified Payment and Currency classes
__PACKAGE__->register_class('PaymentTransaction', 'Comserv::Model::Schema::Ency::Result::PaymentTransaction');
__PACKAGE__->register_class('InternalCurrencyAccount', 'Comserv::Model::Schema::Ency::Result::InternalCurrencyAccount');
__PACKAGE__->register_class('InternalCurrencyTransaction', 'Comserv::Model::Schema::Ency::Result::InternalCurrencyTransaction');

# Register Beekeeping hive component tracking
__PACKAGE__->register_class('HiveComponent', 'Comserv::Model::Schema::Ency::Result::HiveComponent');

# Register Apiary / Queen lifecycle system classes (DB Project 219 — QueenLogModel)
__PACKAGE__->register_class('Queen',                'Comserv::Model::Schema::Ency::Result::Queen');
__PACKAGE__->register_class('QueenEvent',           'Comserv::Model::Schema::Ency::Result::QueenEvent');
__PACKAGE__->register_class('QueenHiveAssignment',  'Comserv::Model::Schema::Ency::Result::QueenHiveAssignment');
__PACKAGE__->register_class('QueenEnhanced',        'Comserv::Model::Schema::Ency::Result::QueenEnhanced');
__PACKAGE__->register_class('Hive',                 'Comserv::Model::Schema::Ency::Result::Hive');
__PACKAGE__->register_class('Inspection',           'Comserv::Model::Schema::Ency::Result::Inspection');
__PACKAGE__->register_class('InspectionDetail',     'Comserv::Model::Schema::Ency::Result::InspectionDetail');
__PACKAGE__->register_class('Box',                  'Comserv::Model::Schema::Ency::Result::Box');
__PACKAGE__->register_class('Yard',                 'Comserv::Model::Schema::Ency::Result::Yard');
__PACKAGE__->register_class('Pallet',               'Comserv::Model::Schema::Ency::Result::Pallet');
__PACKAGE__->register_class('HiveConfiguration',    'Comserv::Model::Schema::Ency::Result::HiveConfiguration');
__PACKAGE__->register_class('HiveFrame',            'Comserv::Model::Schema::Ency::Result::HiveFrame');
__PACKAGE__->register_class('HoneyHarvest',         'Comserv::Model::Schema::Ency::Result::HoneyHarvest');
__PACKAGE__->register_class('Treatment',            'Comserv::Model::Schema::Ency::Result::Treatment');

# Register Chart of Accounts and General Ledger classes
# (modeled on SQL-Ledger / LedgerSMB account + journal_entry + journal_line)
__PACKAGE__->register_class('CoaAccountHeading', 'Comserv::Model::Schema::Ency::Result::CoaAccountHeading');
__PACKAGE__->register_class('CoaAccount',        'Comserv::Model::Schema::Ency::Result::CoaAccount');
__PACKAGE__->register_class('GlEntry',           'Comserv::Model::Schema::Ency::Result::GlEntry');
__PACKAGE__->register_class('GlEntryLine',       'Comserv::Model::Schema::Ency::Result::GlEntryLine');

# Register Inventory system classes
__PACKAGE__->register_class('InventoryItem', 'Comserv::Model::Schema::Ency::Result::InventoryItem');
__PACKAGE__->register_class('InventorySupplier', 'Comserv::Model::Schema::Ency::Result::InventorySupplier');
__PACKAGE__->register_class('InventoryLocation', 'Comserv::Model::Schema::Ency::Result::InventoryLocation');
__PACKAGE__->register_class('InventoryStockLevel', 'Comserv::Model::Schema::Ency::Result::InventoryStockLevel');
__PACKAGE__->register_class('InventoryTransaction', 'Comserv::Model::Schema::Ency::Result::InventoryTransaction');
__PACKAGE__->register_class('InventoryAssignment', 'Comserv::Model::Schema::Ency::Result::InventoryAssignment');
__PACKAGE__->register_class('InventoryItemSupplier', 'Comserv::Model::Schema::Ency::Result::InventoryItemSupplier');
__PACKAGE__->register_class('InventoryItemBOM', 'Comserv::Model::Schema::Ency::Result::InventoryItemBOM');

__PACKAGE__->meta->make_immutable(inline_constructor => 0);
1;

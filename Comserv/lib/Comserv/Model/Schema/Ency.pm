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
__PACKAGE__->register_class('MembershipTransaction', 'Comserv::Model::Schema::Ency::Result::Accounting::PaymentTransaction');
__PACKAGE__->register_class('SystemCostTracking', 'Comserv::Model::Schema::Ency::Result::SystemCostTracking');

__PACKAGE__->register_class('MembershipPromoCode', 'Comserv::Model::Schema::Ency::Result::MembershipPromoCode');

# Register unified Payment and Currency classes
__PACKAGE__->register_class('PaymentTransaction', 'Comserv::Model::Schema::Ency::Result::Accounting::PaymentTransaction');
__PACKAGE__->register_class('InternalCurrencyAccount', 'Comserv::Model::Schema::Ency::Result::Accounting::InternalCurrencyAccount');
__PACKAGE__->register_class('InternalCurrencyTransaction', 'Comserv::Model::Schema::Ency::Result::Accounting::InternalCurrencyTransaction');

# Register Beekeeping hive component tracking
__PACKAGE__->register_class('HiveComponent', 'Comserv::Model::Schema::Ency::Result::Beekeeping::HiveComponent');

# Register Apiary / Queen lifecycle system classes (DB Project 219 — QueenLogModel)
__PACKAGE__->register_class('Queen',                'Comserv::Model::Schema::Ency::Result::Beekeeping::Queen');
__PACKAGE__->register_class('QueenEvent',           'Comserv::Model::Schema::Ency::Result::Beekeeping::QueenEvent');
__PACKAGE__->register_class('QueenHiveAssignment',  'Comserv::Model::Schema::Ency::Result::Beekeeping::QueenHiveAssignment');
__PACKAGE__->register_class('QueenEnhanced',        'Comserv::Model::Schema::Ency::Result::Beekeeping::QueenEnhanced');
__PACKAGE__->register_class('Hive',                 'Comserv::Model::Schema::Ency::Result::Beekeeping::Hive');
__PACKAGE__->register_class('Inspection',           'Comserv::Model::Schema::Ency::Result::Beekeeping::Inspection');
__PACKAGE__->register_class('InspectionDetail',     'Comserv::Model::Schema::Ency::Result::Beekeeping::InspectionDetail');
__PACKAGE__->register_class('Box',                  'Comserv::Model::Schema::Ency::Result::Beekeeping::Box');
__PACKAGE__->register_class('Yard',                 'Comserv::Model::Schema::Ency::Result::Beekeeping::Yard');
__PACKAGE__->register_class('Pallet',               'Comserv::Model::Schema::Ency::Result::Accounting::Pallet');
__PACKAGE__->register_class('HiveConfiguration',    'Comserv::Model::Schema::Ency::Result::Beekeeping::HiveConfiguration');
__PACKAGE__->register_class('HiveFrame',            'Comserv::Model::Schema::Ency::Result::Beekeeping::HiveFrame');
__PACKAGE__->register_class('HoneyHarvest',         'Comserv::Model::Schema::Ency::Result::Beekeeping::HoneyHarvest');
__PACKAGE__->register_class('Treatment',            'Comserv::Model::Schema::Ency::Result::Ency::Treatment');

# Register Chart of Accounts and General Ledger classes
# (modeled on SQL-Ledger / LedgerSMB account + journal_entry + journal_line)
__PACKAGE__->register_class('CoaAccountHeading', 'Comserv::Model::Schema::Ency::Result::Accounting::CoaAccountHeading');
__PACKAGE__->register_class('CoaAccount',        'Comserv::Model::Schema::Ency::Result::Accounting::CoaAccount');
__PACKAGE__->register_class('GlEntry',           'Comserv::Model::Schema::Ency::Result::Accounting::GlEntry');
__PACKAGE__->register_class('GlEntryLine',       'Comserv::Model::Schema::Ency::Result::Accounting::GlEntryLine');

# Register Inventory system classes
__PACKAGE__->register_class('InventoryItem', 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem');
__PACKAGE__->register_class('InventorySupplier', 'Comserv::Model::Schema::Ency::Result::Accounting::InventorySupplier');
__PACKAGE__->register_class('InventoryLocation', 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocation');
__PACKAGE__->register_class('InventoryStockLevel', 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryStockLevel');
__PACKAGE__->register_class('InventoryTransaction', 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryTransaction');
__PACKAGE__->register_class('InventoryAssignment', 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryAssignment');
__PACKAGE__->register_class('InventoryItemSupplier', 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItemSupplier');
__PACKAGE__->register_class('InventoryItemBOM', 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItemBOM');

# Register HelpDesk support ticket and messaging classes
__PACKAGE__->register_class('SupportTicket', 'Comserv::Model::Schema::Ency::Result::SupportTicket');
__PACKAGE__->register_class('TicketMessage', 'Comserv::Model::Schema::Ency::Result::TicketMessage');

__PACKAGE__->meta->make_immutable(inline_constructor => 0);
1;

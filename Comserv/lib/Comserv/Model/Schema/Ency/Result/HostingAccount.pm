package Comserv::Model::Schema::Ency::Result::HostingAccount;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('hosting_accounts');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
        documentation => 'SiteName being hosted (e.g. forager, Mcoop, 3d)',
    },
    plan_slug => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        documentation => 'hosting-subdomain or hosting-app',
    },
    domain => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
        documentation => 'Full domain or subdomain for this hosted site',
    },
    domain_type => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 1,
        default_value => 'subdomain',
        documentation => 'subdomain | custom | subpath',
    },
    parent_domain => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
        documentation => 'Parent domain if domain_type=subdomain (e.g. forager.com)',
    },
    status => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 0,
        default_value => 'pending',
        documentation => 'pending | active | suspended | cancelled',
    },
    referring_sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        documentation => 'SiteName whose admin referred this registration',
    },
    discount_applied => {
        data_type     => 'decimal',
        size          => [5, 2],
        default_value => '0.00',
        is_nullable   => 0,
        documentation => 'One-time discount % applied at signup',
    },
    monthly_cost => {
        data_type     => 'decimal',
        size          => [10, 2],
        default_value => '0.00',
        is_nullable   => 0,
    },
    next_renewal_date => {
        data_type   => 'date',
        is_nullable => 1,
    },
    cpanel_username => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        documentation => 'WHC.ca cPanel username, if applicable',
    },
    contact_email => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
        documentation => 'Billing contact email for this hosted SiteName',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_by => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['sitename']);

sub is_active   { return ($_[0]->status // '') eq 'active'  }
sub is_pending  { return ($_[0]->status // '') eq 'pending' }

1;

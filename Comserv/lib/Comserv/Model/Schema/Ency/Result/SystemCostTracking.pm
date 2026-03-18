package Comserv::Model::Schema::Ency::Result::SystemCostTracking;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

=head1 NAME

Comserv::Model::Schema::Ency::Result::SystemCostTracking

=head1 DESCRIPTION

Records operational expenses so admins can verify that membership pricing
covers infrastructure costs. Costs can be global (site_id NULL) or
attributed to a specific site.

=cut

__PACKAGE__->table('system_cost_tracking');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    cost_category => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
        documentation => join(', ',
            'power_electricity',
            'cooling_hvac',
            'server_room_rent',
            'hardware_servers',
            'hardware_network',
            'hardware_ups',
            'hardware_storage',
            'hardware_workstations',
            'isp_primary',
            'isp_backup',
            'ip_addressing',
            'cdn',
            'hosting_cloud',
            'domain_registration',
            'ssl_certificates',
            'backup_services',
            'ai_ollama_gpu',
            'ai_xai',
            'ai_openai',
            'ai_anthropic',
            'ai_other',
            'software_os',
            'software_licenses',
            'software_monitoring',
            'software_security',
            'email_service',
            'sms_notifications',
            'programming_labor',
            'sysadmin_labor',
            'customer_support',
            'accounting_legal',
            'insurance',
            'security_audit',
            'other',
        ),
    },
    description => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    amount => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
    },
    currency => {
        data_type     => 'varchar',
        size          => 10,
        default_value => 'USD',
        is_nullable   => 0,
    },
    site_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
        documentation  => 'NULL = global/shared infrastructure cost',
    },
    period_start => {
        data_type   => 'date',
        is_nullable => 0,
    },
    period_end => {
        data_type   => 'date',
        is_nullable => 0,
    },
    is_recurring => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 0,
        is_nullable   => 0,
        documentation => 'Monthly recurring cost vs one-time expense',
    },
    vendor => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    invoice_reference => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    created_by => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    'site_id',
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    creator => 'Comserv::Model::Schema::Ency::Result::User',
    'created_by',
    { join_type => 'left' }
);

sub monthly_equivalent {
    my $self = shift;
    return $self->amount if $self->is_recurring;
    use DateTime::Format::Strptime;
    my $fmt = DateTime::Format::Strptime->new(pattern => '%Y-%m-%d');
    my $start = eval { $fmt->parse_datetime($self->period_start) };
    my $end   = eval { $fmt->parse_datetime($self->period_end) };
    return $self->amount unless $start && $end;
    my $days = $end->delta_days($start)->delta_days || 1;
    return sprintf('%.2f', $self->amount / ($days / 30.44));
}

1;

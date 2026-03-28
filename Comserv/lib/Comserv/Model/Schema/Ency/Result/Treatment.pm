package Comserv::Model::Schema::Ency::Result::Treatment;
use base 'DBIx::Class::Core';

__PACKAGE__->table('treatments');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    hive_id => {
        data_type => 'integer',
    },
    treatment_date => {
        data_type => 'date',
    },
    treatment_type => {
        data_type => 'enum',
        extra => {
            list => [qw/varroa nosema foulbrood tracheal_mite small_hive_beetle wax_moth other/]
        },
    },
    product_name => {
        data_type => 'varchar',
        size => 100,
    },
    dosage => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    application_method => {
        data_type => 'enum',
        extra => {
            list => [qw/strip drench dust spray fumigation feeding/]
        },
    },
    duration_days => {
        data_type => 'integer',
        is_nullable => 1,
    },
    withdrawal_period_days => {
        data_type => 'integer',
        is_nullable => 1,
    },
    effectiveness => {
        data_type => 'enum',
        extra => {
            list => [qw/excellent good fair poor unknown/]
        },
        default_value => 'unknown',
    },
    applied_by => {
        data_type => 'varchar',
        size => 50,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

# Relationships
__PACKAGE__->belongs_to(
    'hive',
    'Comserv::Model::Schema::Ency::Result::Hive',
    'hive_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

# Custom methods
sub treatment_type_display {
    my $self = shift;
    
    my %types = (
        varroa => 'Varroa Mite',
        nosema => 'Nosema',
        foulbrood => 'Foulbrood',
        tracheal_mite => 'Tracheal Mite',
        small_hive_beetle => 'Small Hive Beetle',
        wax_moth => 'Wax Moth',
        other => 'Other'
    );
    
    return $types{$self->treatment_type} || $self->treatment_type;
}

sub application_method_display {
    my $self = shift;
    
    my %methods = (
        strip => 'Treatment Strip',
        drench => 'Drench Application',
        dust => 'Dust Application',
        spray => 'Spray Application',
        fumigation => 'Fumigation',
        feeding => 'Medicated Feeding'
    );
    
    return $methods{$self->application_method} || $self->application_method;
}

sub effectiveness_display {
    my $self = shift;
    
    my %effectiveness = (
        excellent => 'Excellent',
        good => 'Good',
        fair => 'Fair',
        poor => 'Poor',
        unknown => 'Unknown'
    );
    
    return $effectiveness{$self->effectiveness} || $self->effectiveness;
}

sub full_description {
    my $self = shift;
    return sprintf("%s treatment with %s (%s)",
        $self->treatment_type_display,
        $self->product_name,
        $self->application_method_display
    );
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::Treatment - Treatment table result class

=head1 DESCRIPTION

Tracks treatments and medications applied to hives. This provides comprehensive
treatment history and withdrawal period tracking for food safety compliance.

=cut
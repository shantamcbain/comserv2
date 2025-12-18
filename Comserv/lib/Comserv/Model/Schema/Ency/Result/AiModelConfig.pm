package Comserv::Model::Schema::Ency::Result::AiModelConfig;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('ai_model_config');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    role => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
    },
    agent_type => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
    },
    model_name => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
    },
    enabled => {
        data_type => 'boolean',
        default_value => 1,
        is_nullable => 0,
    },
    api_endpoint => {
        data_type => 'varchar',
        size => 500,
        is_nullable => 0,
    },
    api_key_encrypted => {
        data_type => 'varchar',
        size => 512,
        is_nullable => 1,
    },
    temperature => {
        data_type => 'float',
        is_nullable => 1,
    },
    max_tokens => {
        data_type => 'integer',
        is_nullable => 1,
    },
    search_docs_automatically => {
        data_type => 'boolean',
        default_value => 1,
        is_nullable => 0,
    },
    allow_web_search => {
        data_type => 'boolean',
        default_value => 0,
        is_nullable => 0,
    },
    allow_code_search => {
        data_type => 'boolean',
        default_value => 0,
        is_nullable => 0,
    },
    priority => {
        data_type => 'integer',
        default_value => 1,
        is_nullable => 0,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');

eval {
    __PACKAGE__->add_index(['role']);
};
if ($@) {
    warn "[AiModelConfig] Could not add index on role: $@\n";
}

eval {
    __PACKAGE__->add_index(['agent_type']);
};
if ($@) {
    warn "[AiModelConfig] Could not add index on agent_type: $@\n";
}

eval {
    __PACKAGE__->add_index(['model_name']);
};
if ($@) {
    warn "[AiModelConfig] Could not add index on model_name: $@\n";
}

eval {
    __PACKAGE__->add_index(['enabled']);
};
if ($@) {
    warn "[AiModelConfig] Could not add index on enabled: $@\n";
}

eval {
    __PACKAGE__->add_index(['priority']);
};
if ($@) {
    warn "[AiModelConfig] Could not add index on priority: $@\n";
}

__PACKAGE__->add_unique_constraint(['role', 'agent_type', 'model_name']);

# Helper methods
sub is_enabled {
    my $self = shift;
    return $self->enabled;
}

sub get_decrypted_api_key {
    my ($self, $encryption_key) = @_;
    my $encrypted = $self->api_key_encrypted;
    return undef unless $encrypted;
    
    use Crypt::CBC;
    use Digest::MD5 qw(md5_hex);
    
    my $cipher = Crypt::CBC->new(
        -key    => $encryption_key,
        -cipher => 'Crypt::OpenSSL::AES'
    );
    
    return $cipher->decrypt($encrypted);
}

sub set_encrypted_api_key {
    my ($self, $api_key, $encryption_key) = @_;
    
    use Crypt::CBC;
    use Digest::MD5 qw(md5_hex);
    
    my $cipher = Crypt::CBC->new(
        -key    => $encryption_key,
        -cipher => 'Crypt::OpenSSL::AES'
    );
    
    my $encrypted = $cipher->encrypt($api_key);
    $self->api_key_encrypted($encrypted);
    return 1;
}

sub get_capabilities {
    my $self = shift;
    return {
        search_docs => $self->search_docs_automatically,
        web_search  => $self->allow_web_search,
        code_search => $self->allow_code_search,
    };
}

sub can_role_use {
    my ($self, $user_role) = @_;
    return $self->is_enabled && ($self->role eq $user_role || $self->role eq '*');
}

1;
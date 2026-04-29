package Comserv::Model::Schema::Ency::Result::VoiceTranscript;
use base 'DBIx::Class::Core';

__PACKAGE__->table('voice_transcripts');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    username => {
        data_type => 'varchar',
        size      => 50,
    },
    original_filename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    audio_path => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    file_size => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    transcript => {
        data_type => 'text',
    },
    model_used => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    inspection_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'inspection',
    'Comserv::Model::Schema::Ency::Result::Inspection',
    'inspection_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

1;

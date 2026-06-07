package Comserv::Model::Schema::Ency::Result::VoiceTranscripts;
use base 'DBIx::Class::Core';

__PACKAGE__->table('voice_transcripts');
__PACKAGE__->add_columns(
    audio_path => {
        data_type => 'varchar',
        size => 500,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    file_size => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    inspection_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    model_used => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    original_filename => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    transcript => {
        data_type => 'text',
    },
    username => {
        data_type => 'varchar',
        size => 50,
    },
);
__PACKAGE__->set_primary_key('id');

1;

package Comserv::Model::Ollama;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

has 'model' => (
    is      => 'rw',
    isa     => 'Str',
    default => 'llama3.1',
    documentation => 'Ollama model name to use for chat/query when no model arg is passed',
);

with 'Comserv::Model::Ollama::Connection';
with 'Comserv::Model::Ollama::Chat';
with 'Comserv::Model::Ollama::Models';

# All other methods (shell fallbacks, etc.) remain here for now
# They will be moved into additional role modules in subsequent steps.

1;
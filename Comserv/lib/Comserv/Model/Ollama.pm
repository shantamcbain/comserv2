package Comserv::Model::Ollama;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

with 'Comserv::Model::Ollama::Connection';
with 'Comserv::Model::Ollama::Chat';
with 'Comserv::Model::Ollama::Models';

# All other methods (shell fallbacks, etc.) remain here for now
# They will be moved into additional role modules in subsequent steps.

1;
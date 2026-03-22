package Comserv::Controller::Health;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::Health - Simple health check endpoint for debugging

=head1 DESCRIPTION

Provides minimal health check endpoint to verify application request processing works.
If this endpoint responds but main app hangs, problem is in main application logic.
If this endpoint hangs, problem is in Catalyst initialization or middleware chain.

=cut

# /health
sub index :Path('') :Args(0) {
    my ($self, $c) = @_;
    $c->response->body('OK');
    $c->response->status(200);
}

# /health/status
sub status :Local :Args(0) {
    my ($self, $c) = @_;
    
    my %status = (
        timestamp => scalar(localtime),
        perl_version => $],
        catalyst_version => $Catalyst::VERSION // 'unknown',
        pid => $$,
    );
    
    $c->response->content_type('application/json');
    $c->response->body(
        Comserv->json->encode(\%status)
    );
}

=head1 AUTHOR

Comserv Debugging

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
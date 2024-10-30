package Comserv::Util::Logger;
   use Moose;
   use namespace::autoclean;
   sub call {
       my ($self, $c) = @_;

       # Log request details
       $c->log->info("Request: " . $c->req->uri);

       # Call the next middleware/controller
       my $response = $c->next::method();

       # Log response details
       $c->log->info("Response: " . $response->status);

       return $response;
   }

   __PACKAGE__->meta->make_immutable;
   1;
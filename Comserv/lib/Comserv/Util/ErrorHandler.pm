package Comserv::Util::ErrorHandler;
   use Moose;
   use Try::Tiny;
   use namespace::autoclean;
   sub call {
       my ($self, $c) = @_;

       try {
           return $c->next::method();
       } catch {
           $c->response->status(500);
           $c->response->body('An error occurred: ' . $_);
           return $c->response;
       };
   }

   __PACKAGE__->meta->make_immutable;
   1;
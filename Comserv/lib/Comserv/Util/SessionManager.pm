package Comserv::Middleware::SessionManager;
   use Moose;
   use namespace::autoclean;
   sub call {
       my ($self, $c) = @_;

       # Check if SiteName is in session
       if (!$c->session->{SiteName}) {
           # Logic to set SiteName based on domain
           my $domain = $c->req->base->host;
           # Fetch site details based on domain
           # Set $c->session->{SiteName} accordingly
       }

       # Call the next middleware/controller
       return $c->next::method();
   }

   __PACKAGE__->meta->make_immutable;
   1;
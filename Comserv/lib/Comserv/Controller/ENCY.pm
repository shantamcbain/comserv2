package Comserv::Controller::ENCY;
use Moose;
use namespace::autoclean;
use Comserv::Model::ENCYModel;
use Comserv::Util::Logging;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
BEGIN { extends 'Catalyst::Controller'; }

sub index :Path('/ENCY') :Args(0) {
    my ( $self, $c ) = @_;
       $c->session->{MailServer} = "http://webmail.usbm.ca";

    # The index action will display the 'index.tt' template
    $c->stash(template => 'ENCY/index.tt');
}
sub add_herb :Path('/ENCY/add_herb') :Args(0) {
    my ( $self, $c ) = @_;

    if ($c->request->method eq 'POST') {
        # Handle form submission
        my $form_data = $c->request->body_parameters;

        # Use the existing logging system to log the form data
        $self->logging->log_with_details($c, __FILE__, __LINE__, 'add_herb', "Form data received: " . join(", ", map { "$_: $form_data->{$_}" } keys %$form_data));

        my $new_herb = {
            therapeutic_action => $form_data->{therapeutic_action},
            botanical_name => $form_data->{botanical_name},
            common_names => $form_data->{common_names},
            parts_used => $form_data->{parts_used},
            comments => $form_data->{comments},
            medical_uses => $form_data->{medical_uses},
            homiopathic => $form_data->{homiopathic},
            ident_character => $form_data->{ident_character},
            image => $form_data->{image},
            stem => $form_data->{stem},
            nectar => $form_data->{nectar},
            pollinator => $form_data->{pollinator},
            pollen => $form_data->{pollen},
            leaves => $form_data->{leaves},
            flowers => $form_data->{flowers},
            fruit => $form_data->{fruit},
            taste => $form_data->{taste},
            odour => $form_data->{odour},
            distribution => $form_data->{distribution},
            url => $form_data->{url},
            root => $form_data->{root},
            constituents => $form_data->{constituents},
            solvents => $form_data->{solvents},
            chinese => $form_data->{chinese},
            culinary => $form_data->{culinary},
            contra_indications => $form_data->{contra_indications},
            dosage => $form_data->{dosage},
            administration => $form_data->{administration},
            formulas => $form_data->{formulas},
            vetrinary => $form_data->{vetrinary},
            cultivation => $form_data->{cultivation},
            sister_plants => $form_data->{sister_plants},
            harvest => $form_data->{harvest},
            non_med => $form_data->{non_med},
            history => $form_data->{history},
            reference => $form_data->{reference},
            username_of_poster => $c->session->{username},
            group_of_poster => $c->session->{group},
            date_time_posted => \'NOW()',  # Assuming you want to set this to the current timestamp
            share => $form_data->{share} // 0,

            preparation => $form_data->{preparation},
            pollennotes => $form_data->{pollennotes},
            nectarnotes => $form_data->{nectarnotes},
            apis => $form_data->{apis},
        };

        # Use the existing logging system to log the new herb data
        $self->logging->log_with_details($c, __FILE__, __LINE__, 'add_herb', "New herb data: " . join(", ", map { "$_: $new_herb->{$_}" } keys %$new_herb));

        # Save the new herb using the ENCYModel
        $c->model('ENCYModel')->add_herb($new_herb);

        # Redirect or display a success message
        $c->flash->{success_message} = 'Herb added successfully';
        $c->res->redirect($c->uri_for($self->action_for('index')));
    } else {
        # Display the form
        $c->stash(
            template => 'ENCY/add_herb_form.tt',
            user_role => $c->session->{roles}  # Pass user role to the template
        );
    }
}


sub botanical_name_view :Path('/ENCY/BotanicalNameView') :Args(0) {
    my ( $self, $c ) = @_;

    # Fetch the herbal data
    my $forager_data = $c->model('DBForager')->get_herbal_data();

    # Pass the data to the template
    my $herbal_data = $forager_data;  # Add 'my' here
    $c->stash(herbal_data => $herbal_data, template => 'ENCY/BotanicalNameView.tt');
}
sub herb_detail :Path('/ENCY/herb_detail') :Args(1) {
    my ( $self, $c, $id ) = @_;
    my $herb = $c->model('DBForager')->get_herb_by_id($id);
    $c->stash(herb => $herb, template => 'ENCY/HerbDetailView.tt');
}
sub get_reference_by_id :Local {
    my ( $self, $c, $id ) = @_;
    # Implement the logic to display the form for getting a reference by its id
    # Fetch the reference using the ENCY model
    my $reference = $c->model('ENCY')->get_reference_by_id($id);
    $c->stash(reference => $reference);
    $c->stash(template => 'ency/get_reference_form.tt');
}

sub create_reference :Local {
    my ( $self, $c ) = @_;
    # Implement the logic to display the form for creating a new reference
    $c->stash(template => 'ency/create_reference_form.tt');
}
sub search :Path('/ENCY/search') :Args(0) {
    my ($self, $c) = @_;

    my $search_string = $c->request->parameters->{search_string};

    # Call the searchHerbs method in the DBForager model
    my $results = $c->model('DBForager')->searchHerbs($c, $search_string);

    # Stash the results for the view
    $c->stash(herbal_data => $results);  # Changed from 'results' to 'herbal_data'

    # Get the referer from the request headers
    my $referer = $c->req->headers->referer;

    # Extract the template name from the referer

        $c->stash(template => 'ENCY/BotanicalNameView.tt');

}
sub get_category_by_id :Local {
    my ( $self, $c, $id ) = @_;
    # Implement the logic to display the form for getting a category by its id
    # Fetch the category using the ENCY model
    my $category = $c->model('ENCY')->get_category_by_id($id);
    $c->stash(category => $category);
    $c->stash(template => 'ency/get_category_form.tt');
}

sub create_category :Local {
    my ( $self, $c ) = @_;
    # Implement the logic to display the form for creating a new category
    $c->stash(template => 'ency/create_category_form.tt');
}

__PACKAGE__->meta->make_immutable;

1;

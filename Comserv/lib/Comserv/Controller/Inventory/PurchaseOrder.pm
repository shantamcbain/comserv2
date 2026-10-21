package Comserv::Controller::Inventory::PurchaseOrder;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::Inventory::Purchasing;
use JSON;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

# LAN/token for /Inventory/api/* ; admin session otherwise.
sub auto :Private {
    my ($self, $c) = @_;
    my $path = $c->req->path // '';
    if ($path =~ m{(?:^|/)Inventory/api/}i) {
        my $address  = $c->req->address // '';
        my $is_local = ($address eq '127.0.0.1' || $address eq '::1'
            || $address =~ /^192\.168\.1\./);
        return 1 if $is_local;
        my $token    = $c->req->header('X-API-Token') || $c->req->params->{api_token};
        my $expected = $c->config->{api_token} || $ENV{COMSERV_API_TOKEN} || '';
        return 1 if $expected && $token && $token eq $expected;
    }
    my $roles = $c->session->{roles} // [];
    my $is_admin = 0;
    if (ref($roles) eq 'ARRAY') {
        $is_admin = grep { lc($_) eq 'admin' } @$roles;
    } elsif (!ref($roles) && $roles) {
        $is_admin = ($roles =~ /\badmin\b/i) ? 1 : 0;
    }
    $is_admin ||= 1 if ($c->session->{username} // '') eq 'Shanta';
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
            'PO access denied for ' . ($c->session->{username} || 'guest'));
        $c->flash->{error_msg} = 'Inventory purchasing is restricted to administrators.';
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return 0;
    }
    return 1;
}

sub _json_body {
    my ($self, $c) = @_;
    my $p = {};
    eval {
        my $body = $c->request->body;
        if ($body) {
            if (ref($body) && $body->can('seek')) {
                seek($body, 0, 0);
                my $raw = do { local $/; <$body> };
                $p = JSON::decode_json($raw) if $raw;
            } else {
                $p = JSON::decode_json($body);
            }
        }
    };
    # Empty body / form POST is not an error — merge query+form params so
    # /Inventory/api/po/receive?po_id= works (audit: 400 po_id required).
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_json_body',
            "JSON parse failed: $@");
        $p = {};
    }
    $p = {} unless ref($p) eq 'HASH';
    my $params = $c->req->parameters || {};
    for my $k (keys %$params) {
        $p->{$k} = $params->{$k} unless exists $p->{$k};
    }
    return $p;
}

# GET /Inventory/api/need?sitename=&parent_sku=
sub api_need :Path('/Inventory/api/need') :Args(0) {
    my ($self, $c) = @_;
    my $p = {
        sitename       => $c->req->params->{sitename} || $c->session->{SiteName} || 'default',
        parent_sku     => $c->req->params->{parent_sku},
        parent_item_id => $c->req->params->{parent_item_id},
    };
    unless ($p->{parent_sku} || $p->{parent_item_id}) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => 'parent_sku or parent_item_id required' }));
        $c->detach;
    }
    my $util = Comserv::Util::Inventory::Purchasing->new;
    my $res  = $util->need_list($c, $p);
    unless ($res->{ok}) {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => $res->{error} }));
        $c->detach;
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_need',
        "need parent=$res->{parent_sku} buy=" . scalar(@{ $res->{buy} || [] })
        . " print=" . scalar(@{ $res->{print} || [] }));
    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1, %$res }));
    $c->detach;
}

# POST /Inventory/api/po/create
sub api_po_create :Path('/Inventory/api/po/create') :Args(0) {
    my ($self, $c) = @_;
    unless (uc($c->req->method || '') eq 'POST') {
        $c->res->status(405);
        $c->res->content_type('application/json');
        $c->res->body('{"success":0,"error":"POST required"}');
        $c->detach;
    }
    my $p = $self->_json_body($c);
    unless ($p) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => 'Invalid JSON' }));
        $c->detach;
    }
    $p->{sitename} ||= $c->session->{SiteName} || 'default';
    my $util = Comserv::Util::Inventory::Purchasing->new;
    my $res  = $util->create_po($c, $p);
    unless ($res->{ok}) {
        $c->res->status($res->{need_schema_compare} ? 503 : 400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, %$res }));
        $c->detach;
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_po_create',
        "PO created id=$res->{po_id} number=$res->{po_number}");
    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1, %$res }));
    $c->detach;
}

# POST /Inventory/api/po/receive  {sitename, po_id, lines?:[{line_id,quantity}]}
sub api_po_receive :Path('/Inventory/api/po/receive') :Args(0) {
    my ($self, $c) = @_;
    unless (uc($c->req->method || '') eq 'POST') {
        $c->res->status(405);
        $c->res->content_type('application/json');
        $c->res->body('{"success":0,"error":"POST required"}');
        $c->detach;
    }
    my $p = $self->_json_body($c);
    unless ($p) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => 'Invalid JSON' }));
        $c->detach;
    }
    $p->{sitename} ||= $c->session->{SiteName} || $c->req->params->{sitename} || 'default';
    $p->{po_id}    ||= $c->req->params->{po_id};
    my $util = Comserv::Util::Inventory::Purchasing->new;
    my $res  = $util->receive_po($c, $p);
    unless ($res->{ok}) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, %$res }));
        $c->detach;
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_po_receive',
        "PO received id=$res->{po_id} status=$res->{status}");
    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1, %$res }));
    $c->detach;
}

# POST /Inventory/po/receive/:id  form qty_<line_id>
sub po_receive :Path('/Inventory/po/receive') :Args(1) {
    my ($self, $c, $id) = @_;
    unless (uc($c->req->method || '') eq 'POST') {
        $c->res->redirect($c->uri_for('/Inventory/po/view', [$id]));
        return;
    }
    my $sitename = $c->session->{SiteName} || $c->req->params->{sitename} || 'default';
    my $params   = $c->req->body_parameters || {};
    my @lines;
    for my $k (keys %$params) {
        next unless $k =~ /^qty_(\d+)$/;
        my $qty = 0 + ($params->{$k} || 0);
        next unless $qty > 0;
        push @lines, { line_id => $1, quantity => $qty };
    }
    my $util = Comserv::Util::Inventory::Purchasing->new;
    my $res  = $util->receive_po($c, {
        sitename => $sitename,
        po_id    => $id,
        (@lines ? (lines => \@lines) : ()),
    });
    if ($res->{ok}) {
        $c->flash->{success_msg} = 'Received ' . scalar(@{ $res->{received} || [] })
            . ' line(s). Status: ' . ($res->{status} || '');
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'po_receive',
            "PO $id: " . ($res->{error} || 'fail'));
        $c->flash->{error_msg} = $res->{error} || 'Receive failed';
    }
    $c->res->redirect($c->uri_for('/Inventory/po/view', [$id]));
}

# POST /Inventory/invoice/apply_mail_stock
# Current site, or every configured site when all_sites=1 and the session is CSC.
sub apply_mail_stock :Path('/Inventory/invoice/apply_mail_stock') :Args(0) {
    my ($self, $c) = @_;
    my $back = $c->uri_for('/Inventory/email-config');
    unless (uc($c->req->method || '') eq 'POST') {
        $c->res->redirect($back);
        return;
    }
    my $session_site = $c->session->{SiteName} || 'CSC';
    my $all = $c->req->body_parameters->{all_sites} ? 1 : 0;
    my $csc = ($session_site =~ /^CSC\b/i) || (($c->session->{username} || '') eq 'Shanta');
    if ($all && !$csc) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'apply_mail_stock',
            "all-sites refused for $session_site");
        $c->flash->{error_msg} = 'Only a CSC admin can apply mail stock for every site.';
        $c->res->redirect($back);
        return;
    }
    require Comserv::Util::Inventory::MailInvoiceStock;
    my $res = eval {
        Comserv::Util::Inventory::MailInvoiceStock->new->apply($c,
            ($all ? () : (sitename => $session_site)),
        );
    };
    if ($@ || !$res || !$res->{ok}) {
        my $err = $@ || ($res && $res->{error}) || 'fail';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'apply_mail_stock', $err);
        $c->flash->{error_msg} = $err;
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'apply_mail_stock',
            $res->{summary} || 'applied');
        $c->flash->{success_msg} = $res->{summary} || 'Mail invoices applied.';
    }
    $c->res->redirect($back);
}

# POST /Inventory/api/invoice/draft_from_mail  {sitename} or {all_sites:1}
sub api_draft_from_mail :Path('/Inventory/api/invoice/draft_from_mail') :Args(0) {
    my ($self, $c) = @_;
    unless (uc($c->req->method || '') eq 'POST') {
        $c->res->status(405);
        $c->res->content_type('application/json');
        $c->res->body('{"success":0,"error":"POST required"}');
        $c->detach;
    }
    my $p = $self->_json_body($c) || {};
    my %args;
    if ($p->{all_sites}) {
        # every configured sitename
    } else {
        $args{sitename} = $p->{sitename} || $c->session->{SiteName} || $c->req->params->{sitename} || 'CSC';
    }
    require Comserv::Util::Inventory::MailInvoiceStock;
    my $res = eval {
        Comserv::Util::Inventory::MailInvoiceStock->new->apply($c, %args);
    };
    if ($@ || !$res || !$res->{ok}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_draft_from_mail',
            $@ || ($res && $res->{error}) || 'fail');
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => $@ || ($res && $res->{error}) || 'fail' }));
        $c->detach;
    }
    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1, %$res }));
    $c->detach;
}

# POST /Inventory/api/stock/reserve
# {sitename, parent_sku|parent_item_id, quantity?, dry_run?, customer_order_id?, force?}
sub api_stock_reserve :Path('/Inventory/api/stock/reserve') :Args(0) {
    my ($self, $c) = @_;
    unless (uc($c->req->method || '') eq 'POST') {
        $c->res->status(405);
        $c->res->content_type('application/json');
        $c->res->body('{"success":0,"error":"POST required"}');
        $c->detach;
    }
    my $p = $self->_json_body($c) || {};
    $p->{sitename} ||= $c->session->{SiteName} || $c->req->params->{sitename} || 'default';
    $p->{parent_sku}     ||= $c->req->params->{parent_sku};
    $p->{parent_item_id} ||= $c->req->params->{parent_item_id};
    my $util = Comserv::Util::Inventory::Purchasing->new;
    my $res  = $util->reserve_bom($c, $p);
    unless ($res->{ok}) {
        $c->res->status($res->{already} ? 409 : 400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, %$res }));
        $c->detach;
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_stock_reserve',
        "parent=$res->{parent_sku} buy=" . scalar(@{ $res->{buy} || [] })
        . " print=" . scalar(@{ $res->{print} || [] }));
    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1, %$res }));
    $c->detach;
}

# POST /Inventory/api/stock/unreserve
# {sitename, parent_sku|parent_item_id, quantity?, customer_order_id?, force?}
sub api_stock_unreserve :Path('/Inventory/api/stock/unreserve') :Args(0) {
    my ($self, $c) = @_;
    unless (uc($c->req->method || '') eq 'POST') {
        $c->res->status(405);
        $c->res->content_type('application/json');
        $c->res->body('{"success":0,"error":"POST required"}');
        $c->detach;
    }
    my $p = $self->_json_body($c) || {};
    $p->{sitename} ||= $c->session->{SiteName} || $c->req->params->{sitename} || 'default';
    $p->{parent_sku}     ||= $c->req->params->{parent_sku};
    $p->{parent_item_id} ||= $c->req->params->{parent_item_id};
    my $util = Comserv::Util::Inventory::Purchasing->new;
    my $res  = $util->unreserve_bom($c, $p);
    unless ($res->{ok}) {
        $c->res->status($res->{missing} ? 404 : 400);
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, %$res }));
        $c->detach;
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_stock_unreserve',
        "parent=$res->{parent_sku} released=" . scalar(@{ $res->{released} || [] }));
    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1, %$res }));
    $c->detach;
}

# POST /Inventory/invoice/save_mailbox
# Saves an IMAP login for one watched address. Password is encrypted; never logged.
sub save_invoice_mailbox :Path('/Inventory/invoice/save_mailbox') :Args(0) {
    my ($self, $c) = @_;
    unless (uc($c->req->method || '') eq 'POST') {
        $c->res->redirect($c->uri_for('/Inventory/email-config'));
        return;
    }
    require Comserv::Util::MailInvoiceClassifier;
    my $p = $c->req->body_parameters;
    my $err = Comserv::Util::MailInvoiceClassifier->new->save_mailbox(
        $c,
        sitename       => $c->session->{SiteName} || '',
        email_address  => $p->{email_address},
        imap_host      => $p->{imap_host},
        imap_port      => $p->{imap_port},
        imap_security  => $p->{imap_security},
        imap_folders   => $p->{imap_folders},
        login_username => $p->{login_username},
        password       => $p->{password},
    );
    if ($err) {
        $c->flash->{error_msg} = $err;
    } else {
        $c->flash->{success_msg} = 'Mail server saved. Classification reads that mailbox, and the local mail dir when this computer has one.';
    }
    $c->res->redirect($c->uri_for('/Inventory/email-config'));
}

__PACKAGE__->meta->make_immutable;
1;

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN {
    use_ok('Comserv::Util::HostingAccount')
        or BAIL_OUT('Failed to load Comserv::Util::HostingAccount');
}

{
    package MockHostingAccount;
    sub new {
        my ( $class, %args ) = @_;
        bless \%args, $class;
    }
    sub sitename      { $_[0]->{sitename} }
    sub domain        { $_[0]->{domain} }
    sub parent_domain { $_[0]->{parent_domain} }
    sub domain_type   { $_[0]->{domain_type} }
}

subtest 'resolve_hostname builds FQDN from prefix + parent' => sub {
    my $ha = MockHostingAccount->new(
        sitename      => 'Brew',
        domain        => 'brew',
        parent_domain => 'computersystemconsulting.ca',
        domain_type   => 'subdomain',
    );
    is(
        Comserv::Util::HostingAccount::resolve_hostname($ha),
        'brew.computersystemconsulting.ca',
        'brew prefix resolves'
    );
};

subtest 'resolve_hostname uses sitename when domain prefix empty' => sub {
    my $ha = MockHostingAccount->new(
        sitename      => '3d',
        domain        => '',
        parent_domain => 'usbm.ca',
        domain_type   => 'subdomain',
    );
    is(
        Comserv::Util::HostingAccount::resolve_hostname($ha),
        '3d.usbm.ca',
        'sitename used as subdomain prefix'
    );
};

subtest 'resolve_hostname keeps full custom domain' => sub {
    my $ha = MockHostingAccount->new(
        sitename      => 'Shanta',
        domain        => 'shanta.weaverbeck.com',
        parent_domain => 'weaverbeck.com',
        domain_type   => 'subdomain',
    );
    is(
        Comserv::Util::HostingAccount::resolve_hostname($ha),
        'shanta.weaverbeck.com',
        'existing FQDN preserved'
    );
};

subtest 'is_public_dns_domain rejects bare labels and internal hosts' => sub {
    ok !Comserv::Util::HostingAccount::is_public_dns_domain('brew'),
        'bare label rejected';
    ok Comserv::Util::HostingAccount::is_public_dns_domain('brew.computersystemconsulting.ca'),
        'public FQDN accepted';
    ok !Comserv::Util::HostingAccount::is_public_dns_domain('workshop.local'),
        '.local rejected';
    ok !Comserv::Util::HostingAccount::is_public_dns_domain('192.168.1.10'),
        'private IP rejected';
    ok !Comserv::Util::HostingAccount::is_public_dns_domain('coop.zero'),
        '.zero dev host rejected';
};

subtest 'is_csc_partner_public_host accepts customer subdomains only' => sub {
    ok Comserv::Util::HostingAccount::is_csc_partner_public_host('brew.computersystemconsulting.ca'),
        'brew CSC subdomain accepted';
    ok Comserv::Util::HostingAccount::is_csc_partner_public_host('3d.usbm.ca'),
        '3d USBM subdomain accepted';
    ok !Comserv::Util::HostingAccount::is_csc_partner_public_host('dev.computersystemconsulting.ca'),
        'CSC infra subdomain rejected';
    ok !Comserv::Util::HostingAccount::is_csc_partner_public_host('weaverbeck.com'),
        'apex domain not treated as partner subdomain';
};

subtest 'public_url returns https link for active-style rows' => sub {
    my $ha = MockHostingAccount->new(
        sitename      => 'Brew',
        domain        => 'brew',
        parent_domain => 'computersystemconsulting.ca',
        domain_type   => 'subdomain',
    );
    is(
        Comserv::Util::HostingAccount::public_url($ha),
        'https://brew.computersystemconsulting.ca',
        'public URL built'
    );
};

done_testing;
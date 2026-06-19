#!/usr/bin/env perl
# Seed Sunfire Systems site — first full DB-page migration.
# Clones structure/content from sunfiresystems.ca into the page table.
# Run: cd Comserv && perl script/seed_sunfire_pages.pl [--update]
use strict;
use warnings;
use lib 'lib';
use Catalyst::Test 'Comserv';
use Getopt::Long qw(GetOptions);

my $update   = 0;
my $sitename = 'Sunfire';
GetOptions('update' => \$update, 'sitename=s' => \$sitename)
    or die "Usage: $0 [--update] [--sitename Sunfire]\n";

my $schema = Comserv->model('DBEncy');
my $rs     = $schema->resultset('Page');

my $shared_css = q{
<style>
.sf-page { font-family: var(--body-font, Verdana, Helvetica, sans-serif); color: var(--text-color, #333); line-height: 1.6; max-width: 1100px; margin: 0 auto; }
.sf-hero { background: linear-gradient(135deg, var(--primary-color, #8B2500) 0%, var(--accent-color, #FF6600) 100%); color: #fff; padding: 2rem 2.5rem; border-radius: 8px; margin-bottom: 2rem; }
.sf-hero h1 { margin: 0 0 0.5rem; font-family: var(--header-font, Verdana, sans-serif); font-size: var(--font-size-xlarge, 1.75rem); color: #fff; border: none; }
.sf-hero .sf-tagline { font-size: var(--font-size-large, 1.15rem); opacity: 0.95; margin: 0; }
.sf-section { margin-bottom: 2rem; }
.sf-section h2 { color: var(--primary-color, #8B2500); font-family: var(--header-font); border-bottom: 2px solid var(--border-color, #ddd); padding-bottom: 0.4rem; }
.sf-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 1.25rem; margin-top: 1rem; }
.sf-card { background: #fff; border: 1px solid var(--border-color, #ddd); border-radius: 8px; padding: 1.25rem; box-shadow: 0 2px 4px rgba(0,0,0,0.06); }
.sf-card h3 { margin-top: 0; color: var(--primary-color, #8B2500); }
.sf-card img { max-width: 100%; height: auto; border-radius: 4px; }
.sf-brands { display: flex; flex-wrap: wrap; gap: 1rem; align-items: center; justify-content: center; margin: 1.5rem 0; }
.sf-brands img { max-height: 60px; width: auto; }
.sf-cta { background: var(--secondary-color, #FFF8F0); border-left: 4px solid var(--accent-color, #FF6600); padding: 1rem 1.25rem; border-radius: 0 6px 6px 0; margin: 1.5rem 0; }
.sf-features { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; margin-top: 1rem; }
.sf-feature { background: var(--secondary-color, #f9f9f9); border-radius: 8px; padding: 1rem; border-left: 4px solid var(--accent-color, #FF6600); }
.sf-feature h4 { margin: 0 0 0.5rem; }
.sf-slideshow-note { font-style: italic; color: var(--text-color, #555); text-align: center; padding: 0.75rem; background: var(--secondary-color, #f5f5f5); border-radius: 6px; }
</style>
};

my @pages = (
    {
        page_code   => 'home',
        menu        => '',
        title       => 'Sunfire Systems',
        link_order  => 0,
        description => 'Energy independent solutions since 1992 — wood stoves, solar, and off-grid living.',
        keywords    => 'Sunfire Systems, wood stoves, solar, off-grid, Lumby BC, hearth, energy independence',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero">
  <h1>Sunfire Systems</h1>
  <p class="sf-tagline">Energy independent solutions since 1992</p>
</div>

<div class="sf-section">
  <div class="sf-slideshow-note">Serving the Greater Lumby Area in BC — check with the manufacturer for dealers outside this area.</div>
</div>

<div class="sf-grid">
  <div class="sf-card">
    <h3>Hearth</h3>
    <p>Wood stoves, gas stoves, pellet stoves, fireplaces, and accessories from trusted brands. Expert advice and professional installation.</p>
    <p><a href="/page/wood_stoves">Browse wood stoves</a> &middot; <a href="/page/gas_stoves">Gas stoves</a> &middot; <a href="/page/fireplaces">Fireplaces</a></p>
  </div>
  <div class="sf-card">
    <h3>Going Off-Grid?</h3>
    <p>Ask us how we can help you take the next step towards energy independence with solar panels, batteries, inverters, and off-grid appliances.</p>
    <p><a href="/page/solar">Explore solar solutions</a> &middot; <a href="/page/off_grid_appliances">Off-grid appliances</a></p>
  </div>
  <div class="sf-card">
    <h3>We Have Moved!</h3>
    <p>Stay tuned for announcements on our new location. <a href="/page/contact">Contact us</a> for directions and hours.</p>
  </div>
  <div class="sf-card">
    <h3>Featured Product</h3>
    <p><strong>EP Cube Residential Energy Storage System</strong> — ask us about availability and installation.</p>
  </div>
</div>

<div class="sf-section">
  <h2>Your Favourite Hearth Brands</h2>
  <div class="sf-brands">
    <img src="https://sunfiresystems.ca/cdn/shop/files/jotul_250x250.png?v=1613733999" alt="Jotul">
    <img src="https://sunfiresystems.ca/cdn/shop/files/regency_250x250.png?v=1613733999" alt="Regency">
    <img src="https://sunfiresystems.ca/cdn/shop/files/Blaze_King_250x250.png?v=1613733999" alt="Blaze King">
    <img src="https://sunfiresystems.ca/cdn/shop/files/hearthstone_250x250.png?v=1613733999" alt="Hearthstone">
    <img src="https://sunfiresystems.ca/cdn/shop/files/Pacific_Energy_Logo_250x250.png?v=1712343055" alt="Pacific Energy">
    <img src="https://sunfiresystems.ca/cdn/shop/files/vermont_castings-TopBar-Logo_250x250.jpg?v=1614302931" alt="Vermont Castings">
    <img src="https://sunfiresystems.ca/cdn/shop/files/quad_250x250.png?v=1613734000" alt="Quadra-Fire">
    <img src="https://sunfiresystems.ca/cdn/shop/files/Heatilator-Logo_250x250.png?v=1613785820" alt="Heatilator">
  </div>
  <p style="text-align:center;"><a href="/page/wood_stoves">Ask us about your favourite hearth brands!</a></p>
</div>

<div class="sf-cta">
  <h2 style="margin-top:0;border:none;color:inherit;">Flexible Payment Plans</h2>
  <p>You have a budget. We have a payment plan to match it. Make your large purchase more affordable with easy monthly or biweekly payments through Financeit.</p>
  <p><a href="/page/finance">Apply for financing</a> &middot; <a href="https://www.financeit.ca/s/zO6dcw" target="_blank" rel="noopener">Financeit pre-approval</a></p>
</div>

<div class="sf-section">
  <h2>Save More, Live Better</h2>
  <p>Becoming energy independent is good for the environment and good for your pocketbook. Wouldn't it be great to do more of the things you love while being ecologically responsible?</p>
  <p><a href="/page/contact">Ask us how!</a></p>
</div>

<div class="sf-section">
  <h2>Powered by CSC Platform</h2>
  <p>Your site runs on the Computer System Consulting platform with built-in tools:</p>
  <div class="sf-features">
    <div class="sf-feature"><h4>HelpDesk</h4><p>Submit service requests and browse our knowledge base.</p></div>
    <div class="sf-feature"><h4>Shop</h4><p>Browse products and place orders through our integrated shop.</p></div>
    <div class="sf-feature"><h4>Marketplace</h4><p>Community marketplace for local listings.</p></div>
    <div class="sf-feature"><h4>Page Editor</h4><p>Site owners can edit every page through Admin &rarr; Pages.</p></div>
  </div>
</div>

<p style="text-align:center;margin-top:2rem;"><a href="https://www.instagram.com/sunfiresystems/" target="_blank" rel="noopener">Follow @sunfiresystems on Instagram</a></p>
</div>
},
    },
    {
        page_code   => 'about_us',
        menu        => 'Main',
        title       => 'About Us',
        link_order  => 10,
        description => 'About Sunfire Systems — energy independence since 1992.',
        keywords    => 'Sunfire Systems, about, Lumby BC, hearth, solar',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>About Sunfire Systems</h1><p class="sf-tagline">Energy independent solutions since 1992</p></div>
<div class="sf-section">
  <p>Sunfire Systems has been helping families and businesses in the Greater Lumby area achieve energy independence for over three decades. We specialize in hearth products — wood stoves, gas stoves, pellet stoves, and fireplaces — as well as solar power systems and off-grid appliances.</p>
  <p>Our team provides expert advice, professional installation, and ongoing service for stoves and chimneys. Whether you are heating your home with wood, transitioning to solar, or outfitting an off-grid cabin, we are here to help.</p>
  <p>We share ownership with <a href="/page/icehorse">Icehorse</a> and are part of the CSC hosted platform family.</p>
</div>
</div>
},
    },
    {
        page_code   => 'contact',
        menu        => 'Main',
        title       => 'Contact Us',
        link_order  => 110,
        description => 'Contact Sunfire Systems in Lumby, BC.',
        keywords    => 'contact, Sunfire Systems, Lumby, phone, email',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Contact Us</h1><p class="sf-tagline">We have moved — contact us for our new location</p></div>
<div class="sf-section">
  <p>Reach out for product inquiries, stove and chimney service, solar consultations, or financing questions.</p>
  <div class="sf-grid">
    <div class="sf-card">
      <h3>Get in Touch</h3>
      <p>Use our <a href="/HelpDesk/contact">HelpDesk contact form</a> for the fastest response, or open a <a href="/HelpDesk/submit">support ticket</a> for service requests.</p>
    </div>
    <div class="sf-card">
      <h3>Service Area</h3>
      <p>Serving the Greater Lumby Area in BC. Check with the manufacturer for dealers outside this area.</p>
    </div>
    <div class="sf-card">
      <h3>Schedule Service</h3>
      <p><a href="/page/schedule_service">Book stove &amp; chimney service</a></p>
    </div>
  </div>
</div>
</div>
},
    },
    {
        page_code   => 'faq',
        menu        => 'Main',
        title       => 'FAQ',
        link_order  => 100,
        description => 'Frequently asked questions about Sunfire Systems products and services.',
        keywords    => 'FAQ, stoves, solar, off-grid, Sunfire',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Frequently Asked Questions</h1></div>
<div class="sf-section">
  <div class="sf-card"><h3>What brands do you carry?</h3><p>We carry Jotul, Regency, Blaze King, Hearthstone, Pacific Energy, Vermont Castings, Quadra-Fire, Heatilator, and many more. <a href="/page/wood_stoves">See our hearth products</a>.</p></div>
  <div class="sf-card"><h3>Do you offer financing?</h3><p>Yes — flexible monthly and biweekly payment plans are available through Financeit. <a href="/page/finance">Learn more</a>.</p></div>
  <div class="sf-card"><h3>Do you service stoves and chimneys?</h3><p>Yes. <a href="/page/schedule_service">Schedule a service appointment</a>.</p></div>
  <div class="sf-card"><h3>Can you help with off-grid and solar?</h3><p>Absolutely. We supply solar panels, batteries, inverters, charge controllers, and off-grid appliances. <a href="/page/solar">Explore solar</a>.</p></div>
  <div class="sf-card"><h3>More questions?</h3><p>Visit our <a href="/HelpDesk/kb">HelpDesk knowledge base</a> or <a href="/HelpDesk/submit">submit a ticket</a>.</p></div>
</div>
</div>
},
    },
    {
        page_code   => 'wood_stoves',
        menu        => 'Main',
        submenu     => 'products',
        title       => 'Wood Stoves',
        link_order  => 20,
        description => 'Wood stoves and wood cook stoves — Jotul, Blaze King, Pacific Energy, and more.',
        keywords    => 'wood stoves, wood cook stoves, hearth, Lumby BC',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Wood Stoves &amp; Cook Stoves</h1><p class="sf-tagline">Efficient, beautiful heat for your home</p></div>
<div class="sf-section">
  <p>We carry a wide selection of wood-burning stoves and wood cook stoves from leading manufacturers. Our team helps you choose the right size and style for your space and provides professional installation.</p>
  <div class="sf-grid">
    <div class="sf-card"><h3>Wood Stoves</h3><p>High-efficiency wood stoves for primary or supplemental heat. EPA-certified models available.</p></div>
    <div class="sf-card"><h3>Wood Cook Stoves</h3><p>Classic cook stoves that heat your home and your meals.</p></div>
    <div class="sf-card"><h3>Accessories</h3><p>Stove pipe, hearth pads, fans, and maintenance supplies. <a href="/page/hearth_accessories">View accessories</a>.</p></div>
  </div>
  <p class="sf-cta">Questions about sizing or installation? <a href="/page/contact">Contact us</a> or <a href="/page/schedule_service">schedule a consultation</a>.</p>
</div>
</div>
},
    },
    {
        page_code   => 'gas_stoves',
        menu        => 'Main',
        submenu     => 'products',
        title       => 'Gas Stoves',
        link_order  => 30,
        description => 'Gas stoves and gas fireplaces from Regency, Heatilator, and more.',
        keywords    => 'gas stoves, gas fireplaces, natural gas, propane',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Gas Stoves &amp; Fireplaces</h1><p class="sf-tagline">Convenient, clean-burning warmth</p></div>
<div class="sf-section">
  <p>Gas stoves and fireplaces offer instant ambiance and adjustable heat with natural gas or propane. We carry Regency, Heatilator, Heat &amp; Glo, and other top brands.</p>
  <p><a href="/page/contact">Contact us</a> for model availability and installation quotes.</p>
</div>
</div>
},
    },
    {
        page_code   => 'pellet_stoves',
        menu        => 'Main',
        submenu     => 'products',
        title       => 'Pellet Stoves',
        link_order  => 40,
        description => 'Pellet stoves — efficient automated wood heat.',
        keywords    => 'pellet stoves, wood pellets, automated heat',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Pellet Stoves</h1><p class="sf-tagline">Automated, efficient wood heat</p></div>
<div class="sf-section">
  <p>Pellet stoves offer the convenience of automated fuel delivery with the warmth of wood heat. Ask us about models suited to your home size and heating needs.</p>
  <p><a href="/page/contact">Contact us</a> for recommendations and pricing.</p>
</div>
</div>
},
    },
    {
        page_code   => 'fireplaces',
        menu        => 'Main',
        submenu     => 'products',
        title       => 'Fireplaces',
        link_order  => 50,
        description => 'Wood and gas fireplaces for new builds and retrofits.',
        keywords    => 'fireplaces, wood fireplace, gas fireplace',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Fireplaces</h1><p class="sf-tagline">Wood and gas fireplace inserts and units</p></div>
<div class="sf-section">
  <p>From traditional wood-burning fireplaces to modern gas units, we help you find the right fireplace for your renovation or new build.</p>
  <p><a href="/page/contact">Contact us</a> for a consultation.</p>
</div>
</div>
},
    },
    {
        page_code   => 'hearth_accessories',
        menu        => 'Main',
        submenu     => 'products',
        title       => 'Hearth Accessories',
        link_order  => 55,
        description => 'Stove accessories, thermostats, and fireplace parts.',
        keywords    => 'stove accessories, thermostats, hearth parts',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Hearth Accessories</h1></div>
<div class="sf-section">
  <p>Stove pipe, fans, thermostats, hearth pads, tools, and replacement parts for your hearth system.</p>
  <p><a href="/page/contact">Contact us</a> for parts availability.</p>
</div>
</div>
},
    },
    {
        page_code   => 'solar',
        menu        => 'Main',
        submenu     => 'products',
        title       => 'Solar',
        link_order  => 60,
        description => 'Solar panels, batteries, inverters, and complete off-grid kits.',
        keywords    => 'solar panels, batteries, inverters, off-grid, charge controllers',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Solar &amp; Off-Grid Power</h1><p class="sf-tagline">Take the next step towards energy independence</p></div>
<div class="sf-section">
  <div class="sf-grid">
    <div class="sf-card"><h3>Solar Panels</h3><p>Photovoltaic panels for grid-tied and off-grid systems.</p></div>
    <div class="sf-card"><h3>Batteries</h3><p>Deep-cycle and lithium storage for reliable off-grid power.</p></div>
    <div class="sf-card"><h3>Inverters &amp; Charge Controllers</h3><p>Convert and manage your solar energy efficiently.</p></div>
    <div class="sf-card"><h3>Solar Kits</h3><p>Complete kits sized for cabins, RVs, and homes.</p></div>
    <div class="sf-card"><h3>DC Lighting</h3><p>LED lighting designed for low-voltage off-grid systems.</p></div>
    <div class="sf-card"><h3>EP Cube</h3><p>Featured: EP Cube Residential Energy Storage System — ask us for details.</p></div>
  </div>
  <p class="sf-cta"><a href="/page/contact">Ask us how we can help you go off-grid!</a></p>
</div>
</div>
},
    },
    {
        page_code   => 'off_grid_appliances',
        menu        => 'Main',
        submenu     => 'products',
        title       => 'Off-Grid Appliances',
        link_order  => 70,
        description => 'DC refrigerators, off-grid ranges, and propane appliances.',
        keywords    => 'off-grid appliances, DC refrigerator, propane fridge, off-grid range',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Off-Grid Appliances</h1><p class="sf-tagline">Live comfortably off the grid</p></div>
<div class="sf-section">
  <div class="sf-grid">
    <div class="sf-card"><h3>DC Refrigerators &amp; Freezers</h3><p>Energy-efficient solar-powered refrigeration.</p></div>
    <div class="sf-card"><h3>Off-Grid Ranges</h3><p>Cooking solutions for off-grid kitchens.</p></div>
    <div class="sf-card"><h3>Propane Fridges</h3><p>Reliable propane-powered refrigeration.</p></div>
  </div>
  <p><a href="/page/contact">Contact us</a> for product recommendations.</p>
</div>
</div>
},
    },
    {
        page_code   => 'water_works',
        menu        => 'Main',
        submenu     => 'products',
        title       => 'Water Works',
        link_order  => 80,
        description => 'Water pumps and plumbing for off-grid water systems.',
        keywords    => 'water pumps, off-grid plumbing, solar pumps',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Water Works</h1><p class="sf-tagline">Pumps and plumbing for off-grid water</p></div>
<div class="sf-section">
  <p>Solar and DC water pumps, plumbing supplies, and accessories for off-grid and rural water systems.</p>
  <p><a href="/page/contact">Contact us</a> for sizing and availability.</p>
</div>
</div>
},
    },
    {
        page_code   => 'schedule_service',
        menu        => 'Main',
        submenu     => 'service',
        title       => 'Stove & Chimney Service',
        link_order  => 90,
        description => 'Schedule professional stove and chimney service.',
        keywords    => 'stove service, chimney cleaning, maintenance, Lumby',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Stove &amp; Chimney Service</h1><p class="sf-tagline">Professional maintenance and repairs</p></div>
<div class="sf-section">
  <p>Keep your hearth system safe and efficient with regular maintenance. We service wood stoves, gas stoves, pellet stoves, and chimneys.</p>
  <p><strong>Book service:</strong> <a href="/HelpDesk/submit">Submit a service request via HelpDesk</a> or <a href="/page/contact">contact us directly</a>.</p>
</div>
</div>
},
    },
    {
        page_code   => 'finance',
        menu        => 'Main',
        submenu     => 'service',
        title       => 'Payment Plans',
        link_order  => 95,
        description => 'Flexible financing for stoves, solar, and large purchases.',
        keywords    => 'financing, payment plans, Financeit',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Payment Plans &amp; Financing</h1><p class="sf-tagline">Flexible payments for your budget</p></div>
<div class="sf-section">
  <p>Make your large purchase more affordable by applying for an easy monthly or biweekly payment plan with Financeit. Get pre-approved in seconds!</p>
  <p class="sf-cta"><a href="https://www.financeit.ca/s/zO6dcw" target="_blank" rel="noopener"><strong>Apply for financing now</strong></a></p>
  <p>Questions? <a href="/page/contact">Contact us</a> before you apply.</p>
</div>
</div>
},
    },
    {
        page_code   => 'sale',
        menu        => 'Main',
        title       => 'Sale',
        link_order  => 120,
        description => 'Clearance items and special offers.',
        keywords    => 'sale, clearance, specials',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Sale &amp; Clearance</h1><p class="sf-tagline">Special offers while supplies last</p></div>
<div class="sf-section">
  <p>Check our <a href="/shop">shop</a> and <a href="/marketplace">marketplace</a> for current clearance items and specials. Inventory changes frequently — <a href="/page/contact">contact us</a> for availability.</p>
</div>
</div>
},
    },
    {
        page_code   => 'icehorse',
        menu        => 'Main',
        title       => 'Icehorse',
        link_order  => 130,
        description => 'Icehorse — sister company under the same ownership.',
        keywords    => 'Icehorse, Sunfire Systems',
        body        => $shared_css . q{
<div class="sf-page">
<div class="sf-hero"><h1>Icehorse</h1><p class="sf-tagline">Sister company — same ownership as Sunfire Systems</p></div>
<div class="sf-section">
  <p>Icehorse and Sunfire Systems share ownership. Visit the Icehorse site for additional products and services.</p>
</div>
</div>
},
    },
);

print "=== Seeding Sunfire pages (sitename=$sitename) ===\n";

my $created = 0;
my $updated = 0;
my $skipped = 0;

for my $page (@pages) {
    my %row = (
        sitename    => $sitename,
        menu        => $page->{menu} // 'Main',
        submenu     => $page->{submenu} // '',
        page_code   => $page->{page_code},
        title       => $page->{title},
        body        => $page->{body},
        description => $page->{description} // '',
        keywords    => $page->{keywords} // '',
        link_order  => $page->{link_order} // 0,
        status      => 'active',
        roles       => 'public',
        page_type   => 'standard',
        created_by  => 'seed_sunfire_pages',
    );

    my $existing = $rs->search(
        { sitename => $sitename, page_code => $row{page_code} },
        { rows => 1 }
    )->single;

    if ($existing) {
        if ($update) {
            $existing->update({
                map { $_ => $row{$_} } grep { $_ ne 'created_by' } keys %row
            });
            print "  Updated: $row{page_code} (id=" . $existing->id . ")\n";
            $updated++;
        } else {
            print "  Exists:  $row{page_code} (id=" . $existing->id . ") — use --update to refresh\n";
            $skipped++;
        }
    } else {
        my $new = $rs->create(\%row);
        print "  Created: $row{page_code} (id=" . $new->id . ")\n";
        $created++;
    }
}

# Update Site record for DB-only home routing
my $site = $schema->resultset('Site')->search({ name => $sitename }, { rows => 1 })->single;
if ($site) {
    my %site_updates = (
        home_view         => 'SiteHome',
        site_display_name => 'Sunfire Systems',
        description       => 'Energy independent solutions since 1992 — wood stoves, solar, off-grid.',
        css_view_name     => 'sunfire',
    );
    $site->update(\%site_updates);
    print "\nUpdated Site record: home_view=SiteHome, theme=sunfire\n";
} else {
    print "\nWARN: Site '$sitename' not found — create Site + SiteDomain rows first.\n";
}

# Stamp hosting account with source site URL if present
eval {
    my $ha = $schema->resultset('Accounting::HostingAccount')->search(
        { sitename => $sitename }, { rows => 1 }
    )->single;
    if ($ha) {
        my $notes = $ha->notes // '';
        unless ($notes =~ /sunfiresystems\.ca/i) {
            my $extra = "Migrated from: https://sunfiresystems.ca\nPublic domain (when ready): sunfiresystems.com";
            $ha->update({ notes => ($notes ? "$notes\n$extra" : $extra) });
            print "Updated HostingAccount notes with source URL.\n";
        }
    }
};

print "\nDone: $created created, $updated updated, $skipped skipped (existing).\n";
print "Home: / (SiteHome → page home)\n";
print "Pages: /page/about_us, /page/wood_stoves, etc.\n";
print "Re-run with --update to refresh page content from seed.\n";
exit 0;
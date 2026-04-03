[% PageVersion = 'Navigation/TopDropListENCY.tt,v 0.01 2025/10/01 shanta Exp shanta ' %]
[% IF c.session.debug_mode == 1 %]
    [%# PageVersion %]
[% END %]

<!-- Start /Navigation/TopDropListENCY.tt-->
<li class="horizontal-dropdown">
    <a href="/ENCY" class="dropbtn"><i class="icon-ency"></i>ENCY</a>
    <div class="dropdown-content">
        <!-- Core ENCY Navigation -->
        <a href="/ENCY"><i class="icon-home"></i>ENCY Home</a>
        <a href="/ENCY/documentation"><i class="icon-documentation"></i>ENCY Documentation</a>
        
        <div class="dropdown-divider"></div>
        
        <!-- Biological Categories -->
        <div class="submenu-item">
            <span class="submenu-header"><i class="icon-biology"></i>Biological Categories</span>
            <div class="submenu">
                <a href="/ENCY/plants"><i class="icon-plant"></i>Plants & Herbs</a>
                <a href="/ENCY/animals"><i class="icon-animal"></i>Animals</a>
                <a href="/ENCY/birds"><i class="icon-bird"></i>Birds</a>
                <a href="/ENCY/insects"><i class="icon-insect"></i>Insects</a>
                <a href="/ENCY/fungi"><i class="icon-fungi"></i>Fungi</a>
                <a href="/ENCY/microorganisms"><i class="icon-micro"></i>Microorganisms</a>
            </div>
        </div>

        <!-- Therapeutic & Medicinal -->
        <div class="submenu-item">
            <span class="submenu-header"><i class="icon-medical"></i>Therapeutic Resources</span>
            <div class="submenu">
                <a href="/ENCY/therapeutic_actions"><i class="icon-therapy"></i>Therapeutic Actions</a>
                <a href="/ENCY/constituents"><i class="icon-chemistry"></i>Chemical Constituents</a>
                <a href="/ENCY/medicinal_properties"><i class="icon-medicine"></i>Medicinal Properties</a>
                <a href="/ENCY/recipes"><i class="icon-recipe"></i>Herbal Recipes</a>
            </div>
        </div>

        <!-- Ecological Relationships -->
        <div class="submenu-item">
            <span class="submenu-header"><i class="icon-ecology"></i>Ecological Systems</span>
            <div class="submenu">
                <a href="/ENCY/pollinators"><i class="icon-pollinator"></i>Pollinators</a>
                <a href="/ENCY/ecosystems"><i class="icon-ecosystem"></i>Ecosystems</a>
                <a href="/ENCY/relationships"><i class="icon-network"></i>Species Relationships</a>
                <a href="/ENCY/conservation"><i class="icon-conservation"></i>Conservation Status</a>
            </div>
        </div>

        <!-- Cultivation & Growing -->
        <div class="submenu-item">
            <span class="submenu-header"><i class="icon-cultivation"></i>Cultivation & Growing</span>
            <div class="submenu">
                <a href="/ENCY/cultivation"><i class="icon-grow"></i>Cultivation Methods</a>
                <a href="/ENCY/yards"><i class="icon-yard"></i>Yard Management</a>
                <a href="/ENCY/growing_zones"><i class="icon-zone"></i>Growing Zones</a>
            </div>
        </div>

        <!-- Documentation & Resources -->
        <div class="submenu-item">
            <span class="submenu-header"><i class="icon-docs"></i>Documentation</span>
            <div class="submenu">
                <a href="/Documentation/ency/ENCY.md" target="_blank"><i class="icon-documentation"></i>ENCY Overview</a>
                <a href="/Documentation/ency/ENCYController.md" target="_blank"><i class="icon-code"></i>Controller Documentation</a>
                <a href="/Documentation/ency/ENCYModel.md" target="_blank"><i class="icon-database"></i>Model Documentation</a>
            </div>
        </div>

        [% IF c.session.username %]
        <div class="dropdown-divider"></div>
        
        <!-- User Management Options -->
        <div class="submenu-item">
            <span class="submenu-header"><i class="icon-user-manage"></i>Manage ENCY</span>
            <div class="submenu">
                <a href="/ENCY/add_herb"><i class="icon-add"></i>Add New Entry</a>
                <a href="/ENCY/my_entries"><i class="icon-user-entries"></i>My Entries</a>
                <a href="/ENCY/search"><i class="icon-search"></i>Advanced Search</a>
            </div>
        </div>
        [% END %]

        [% IF c.session.roles.grep('admin').size %]
        <div class="dropdown-divider"></div>
        <a href="/ENCY/admin"><i class="icon-admin"></i>ENCY Administration</a>
        <a href="/navigation/manage_links?menu=ENCY" class="menu-item"><i class="icon-manage"></i>Manage ENCY Menu</a>
        [% END %]
    </div>
</li>
<!-- End /Navigation/TopDropListENCY.tt-->

<style>
    /* ENCY Menu Specific Styles */
    .submenu-item {
        position: relative;
    }

    .submenu-header {
        display: block;
        padding: 8px 15px;
        background-color: #e9ecef;
        color: #495057;
        font-weight: bold;
        font-size: 0.9em;
        border-bottom: 1px solid #dee2e6;
        cursor: pointer;
    }

    .submenu {
        background-color: #f8f9fa;
        display: none; /* Hidden by default - show on hover */
        position: absolute;
        top: 0;
        left: 100%;
        min-width: 200px;
        box-shadow: 0px 8px 16px 0px rgba(0, 0, 0, 0.2);
        z-index: 101;
    }
    
    .submenu-item:hover .submenu {
        display: block;
    }

    .submenu a {
        padding: 8px 25px;
        display: flex;
        align-items: center;
        text-decoration: none;
        color: #495057;
        font-size: 0.9em;
        transition: background-color 0.2s;
    }

    .submenu a:hover {
        background-color: #e9ecef;
    }

    .submenu a i {
        margin-right: 6px;
        width: 14px;
        text-align: center;
    }

    /* ENCY-specific Icons */
    .icon-ency:before { content: "🌿"; }
    .icon-biology:before { content: "🧬"; }
    .icon-plant:before { content: "🌱"; }
    .icon-animal:before { content: "🦌"; }
    .icon-bird:before { content: "🦅"; }
    .icon-insect:before { content: "🐝"; }
    .icon-fungi:before { content: "🍄"; }
    .icon-micro:before { content: "🦠"; }
    .icon-medical:before { content: "⚕️"; }
    .icon-therapy:before { content: "💊"; }
    .icon-chemistry:before { content: "⚗️"; }
    .icon-medicine:before { content: "🏥"; }
    .icon-recipe:before { content: "📋"; }
    .icon-ecology:before { content: "🌍"; }
    .icon-pollinator:before { content: "🦋"; }
    .icon-ecosystem:before { content: "🌳"; }
    .icon-network:before { content: "🕸️"; }
    .icon-conservation:before { content: "🛡️"; }
    .icon-cultivation:before { content: "🌾"; }
    .icon-grow:before { content: "🌿"; }
    .icon-yard:before { content: "🏡"; }
    .icon-zone:before { content: "🗺️"; }
    .icon-docs:before { content: "📚"; }
    .icon-documentation:before { content: "📖"; }
    .icon-code:before { content: "💻"; }
    .icon-database:before { content: "🗄️"; }
    .icon-user-manage:before { content: "👤⚙️"; }
    .icon-user-entries:before { content: "📝"; }
    .icon-search:before { content: "🔍"; }
    .icon-admin:before { content: "⚙️"; }
    .icon-manage:before { content: "🔧"; }
    .icon-home:before { content: "🏠"; }
    .icon-add:before { content: "➕"; }
</style>
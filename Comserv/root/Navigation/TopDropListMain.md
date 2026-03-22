[% PageVersion = 'Navigation/TopDropListMain.tt,v 0.02 2025/09/03 shanta Exp shanta ' %]
[% IF c.session.debug_mode == 1 %]
    [%# PageVersion %]
    [%# "Debugging HostName: " _ HostName %]
    [%# INCLUDE 'debug.tt' %]
[% END %]
    [%# /HTMLTemplates/Default/TopDropListMain.ttml %]
[%# $Id: TopDropListMain.ttml,v 0.01 2019/12/09 06:33:25 shanta Exp shanta $ %]

<!-- Start /HTMLTemplates/Default/TopDropListMain.tt-->
<li class="horizontal-dropdown">
    <a href="/" class="dropbtn"><i class="icon-main"></i>Main</a>
    <div class="dropdown-content">
        <!-- Core Navigation -->
        <a href="/" onclick="activateSite('Home')"><i class="icon-home"></i>Home</a>
        <a href="[% c.session.return_url %]"><i class="icon-back"></i>Go Back</a>
        <a href="/workshop" onclick="activateSite('Workshops')" target="_blank"><i class="icon-workshop"></i>Workshops</a>
        
        [% IF c.session.username %]
        <div class="dropdown-divider"></div>
        <a href="/navigation/add_link"><i class="icon-add"></i>Add Link</a>
        [% END %]
        
        <div class="dropdown-divider"></div>
        
        <!-- Mail Services -->
        <div class="submenu-item">
            <span class="submenu-header"><i class="icon-mail"></i>Mail Services</span>
            <div class="submenu">
                [% IF c.session.username == 'Shanta' %]
                <a href="http://mail.coop.ca/roundcube/" target="_blank"><i class="icon-webmail"></i>COOP Webmail</a>
                <a href="http://wbeck.zapto.org/roundcube/" target="_blank"><i class="icon-webmail"></i>WB Webmail</a>
                [% END %]
                
                <!-- Public Main Links added by admin -->
                [% FOREACH link = c.stash.dbi.query("SELECT * FROM internal_links_tb WHERE category = 'Main_links' AND (sitename = '$SiteName' OR sitename = 'All') ORDER BY link_order") %]
                    <a href="[% link.url %]?site=[% SiteName %]&amp;[% session_string %]&amp;[% link.view_name %]" name="Contact" target="[% link.target %]" title="[% link.name %]">[% link.name %]</a>
                    [% IF c.session.roles.grep('admin').size %]
                        <a href="/navigation/edit_link?link_id=[% link.id %]" class="edit-link">Edit</a>
                    [% END %]
                [% END %]
            </div>
        </div>

        <!-- Shared Folders -->
        <div class="submenu-item">
            <span class="submenu-header"><i class="icon-folder"></i>Shared Folders</span>
            <div class="submenu">
                <a href="/Shares"><i class="icon-cloud"></i>File Shares</a>
                <a href="/media"><i class="icon-image"></i>Media Server</a>
                <a href="/" onclick="activateSite('BMaster')"><i class="icon-drive"></i>BMaster</a>
                <a href="/cloud"><i class="icon-sync"></i>Cloud Sync</a>
            </div>
        </div>

        <!-- Private Links for logged in users -->
        [% IF c.session.username %]
        <div class="submenu-item">
            <span class="submenu-header"><i class="icon-user-links"></i>My Main Links</span>
            <div class="submenu">
                [% SET found_private_main_links = 0 %]
                <!-- Get private links for this user in Main category -->
                [% IF c.stash.private_links %]
                    [% FOREACH link IN c.stash.private_links %]
                        [% IF link.category == 'Main_links' || link.menu == 'Main' %]
                            [% SET found_private_main_links = 1 %]
                            <a href="[% link.url %]" target="[% link.target || '_self' %]" title="[% link.name %]">
                                [% IF link.icon %]<i class="[% link.icon %]"></i>[% END %]
                                [% link.name %]
                            </a>
                            <a href="/navigation/edit_link?link_id=[% link.id %]" class="edit-link">Edit</a>
                        [% END %]
                    [% END %]
                [% END %]
                
                <!-- Fallback query if no private_links in stash -->
                [% IF !found_private_main_links %]
                    [% FOREACH link = c.stash.dbi.query("SELECT * FROM internal_links_tb WHERE (category = 'Main_links' OR menu = 'Main') AND description = '$username' AND (sitename = '$SiteName' OR sitename = 'All') ORDER BY link_order") %]
                        <a href="[% link.url %]" target="[% link.target || '_self' %]" title="[% link.name %]">
                            [% IF link.icon %]<i class="[% link.icon %]"></i>[% END %]
                            [% link.name %]
                        </a>
                        <a href="/navigation/edit_link?link_id=[% link.id %]" class="edit-link">Edit</a>
                    [% END %]
                [% END %]
                
                <!-- Add link option for this specific menu -->
                <a href="/navigation/add_link?menu=Main" class="add-submenu-link"><i class="icon-add"></i>Add Main Link</a>
            </div>
        </div>
        [% END %]

        <!-- Global/Public Links -->
        <div class="submenu-item">
            <span class="submenu-header"><i class="icon-globe"></i>Public Links</span>
            <div class="submenu">
                <!-- Page-based links for Main menu -->
                [% FOREACH link = c.stash.dbi.query("SELECT * FROM page_tb WHERE (menu = 'Main' AND status = 2) AND (sitename = '$SiteName' OR sitename = 'All') ORDER BY link_order") %]
                    <a href="/cgi-bin/index.cgi?site=[% SiteName %]&amp;[% session_string %]&amp;page=[% link.page_code %]" name="Contact" target="[% link.target %]" title="[% link.view_name %]">[% link.view_name %]</a>
                    [% IF c.session.roles.grep('admin').size %]
                        <a href="/pages/edit?page_id=[% link.id %]" class="edit-link">Edit</a>
                    [% END %]
                [% END %]
            </div>
        </div>
        
        [% IF c.session.roles.grep('admin').size %]
        <div class="dropdown-divider"></div>
        <a href="/navigation/manage_links?menu=Main" class="menu-item"><i class="icon-manage"></i>Manage Main Menu</a>
        [% END %]
    </div>
</li>
<!-- End /HTMLTemplates/Default/TopDropListMain.tt-->

<style>
    /* Main Menu Specific Styles */
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

    .edit-link {
        font-size: 0.8em;
        color: #6c757d;
        margin-left: 10px;
        text-decoration: none;
        padding: 2px 5px;
    }

    .edit-link:hover {
        color: #495057;
        text-decoration: underline;
    }

    .add-submenu-link {
        font-style: italic;
        color: #007bff !important;
    }

    .add-submenu-link:hover {
        background-color: #e3f2fd !important;
    }

    /* Icons */
    .icon-main:before { content: "🏠"; }
    .icon-home:before { content: "🏠"; }
    .icon-back:before { content: "⬅️"; }
    .icon-workshop:before { content: "🔧"; }
    .icon-add:before { content: "➕"; }
    .icon-mail:before { content: "✉️"; }
    .icon-webmail:before { content: "📧"; }
    .icon-folder:before { content: "📁"; }
    .icon-cloud:before { content: "☁️"; }
    .icon-image:before { content: "🖼️"; }
    .icon-drive:before { content: "💾"; }
    .icon-sync:before { content: "🔄"; }
    .icon-user-links:before { content: "👤🔗"; }
    .icon-globe:before { content: "🌍"; }
    .icon-manage:before { content: "⚙️"; }
</style>
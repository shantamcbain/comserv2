#!/usr/bin/env perl

use FindBin;

BEGIN {
    $ENV{CATALYST_SCRIPT_GEN} = 40;
    
    # Ensure we're using the correct Perl version via perlbrew
    my $required_perl_version = "perl-5.40.0";
    my $current_perl = $^X;
    
    # Check if we're already using the correct perlbrew Perl
    if ($current_perl !~ /perlbrew.*\Q$required_perl_version\E/) {
        # Try to find and use the correct perlbrew Perl
        my $perlbrew_perl = "$ENV{HOME}/perl5/perlbrew/perls/$required_perl_version/bin/perl";
        
        if (-x $perlbrew_perl) {
            print "Switching to perlbrew Perl $required_perl_version...\n";
            # Re-execute with the correct Perl version
            exec($perlbrew_perl, $0, @ARGV);
            exit;
        } else {
            warn "Warning: $required_perl_version not found via perlbrew at $perlbrew_perl\n";
            warn "Please install it with: perlbrew install $required_perl_version\n";
            warn "Continuing with current Perl version, but some modules may not work correctly.\n";
        }
    }

    # Add the lib directory to @INC
    use FindBin;
    use lib "$FindBin::Bin/../lib";
    use lib "$FindBin::Bin/..";

    # Install local::lib if not already installed
    eval { require local::lib; }; # Check if local::lib is loaded
    if ($@) { # $@ contains error message if require failed
        system("cpanm local::lib") == 0
            or die "Failed to install local::lib. Please install it manually with: cpanm local::lib\n";

        # Reload the environment to activate the newly installed local::lib
        exec($^X, $0, @ARGV);
        exit; # This line is technically redundant but good practice
    }

    # Set up local::lib for local installations
    use local::lib "$FindBin::Bin/../local";
    use lib "$FindBin::Bin/../local/lib/perl5";
    $ENV{PERL5LIB} = "$FindBin::Bin/../local/lib/perl5:$ENV{PERL5LIB}";
    $ENV{PATH} = "$FindBin::Bin/../local/bin:$ENV{PATH}";
    
    # Add architecture-specific paths early
    use Config;
    my $archname = $Config{archname};
    my $version = $Config{version};
    
    # Add all possible architecture paths to @INC
    use lib "$FindBin::Bin/../local/lib/perl5/$archname";
    use lib "$FindBin::Bin/../local/lib/perl5/$version/$archname";
    use lib "$FindBin::Bin/../local/lib/perl5/$version";
    
    # Also add the actual installed architecture path (for systems where archname differs)
    # This handles cases where the actual installed path uses a different architecture name
    my @arch_paths = (
        "$FindBin::Bin/../local/lib/perl5/x86_64-linux-gnu-thread-multi",
        "$FindBin::Bin/../local/lib/perl5/auto",
        "$FindBin::Bin/../local/lib/perl5/site_perl",
        "$FindBin::Bin/../local/lib/perl5/site_perl/$version",
        "$FindBin::Bin/../local/lib/perl5/site_perl/$version/$archname"
    );
    
    foreach my $path (@arch_paths) {
        if (-d $path) {
            unshift @INC, $path;
        }
    }
    
    # Debug: Print the paths being added
    if ($ENV{CATALYST_DEBUG}) {
        print "Debug: Adding architecture paths to \@INC:\n";
        print "  $FindBin::Bin/../local/lib/perl5/$archname\n";
        print "  $FindBin::Bin/../local/lib/perl5/$version/$archname\n";
        print "  $FindBin::Bin/../local/lib/perl5/$version\n";
        foreach my $path (@arch_paths) {
            print "  $path\n" if -d $path;
        }
    }
}

# Ensure the local directory exists
unless (-d "$FindBin::Bin/../local") {
    mkdir "$FindBin::Bin/../local" or die "Could not create local directory: $!";
}

# Automatically install dependencies locally
unless ($ENV{SKIP_DEPS}) {
    print "Installing dependencies from cpanfile...\n";
} else {
    print "Skipping dependency installation (SKIP_DEPS=1)...\n";
    goto SKIP_DEPENDENCY_INSTALLATION;
}
my $cpanfile_path = "$FindBin::Bin/../cpanfile";
if (-e $cpanfile_path) {
    print "Found cpanfile at: $cpanfile_path\n";
    
    # Check if cpanm is installed
    my $cpanm_check = system("which cpanm > /dev/null 2>&1");
    if ($cpanm_check != 0) {
        print "cpanm not found. Installing App::cpanminus...\n";
        system("curl -L https://cpanmin.us | perl - --sudo App::cpanminus") == 0
            or die "Failed to install cpanm. Please install it manually with: curl -L https://cpanmin.us | perl - --sudo App::cpanminus\n";
    }
    
    # Install all dependencies from cpanfile first
    print "Installing all dependencies from cpanfile...\n";
    my $cpanfile_result = system("cpanm --local-lib=$FindBin::Bin/../local --installdeps $FindBin::Bin/..");
    
    # Force reinstall XS modules to ensure they're compiled with current Perl version
    print "Force reinstalling XS modules to ensure compatibility...\n";
    my @xs_modules = ('YAML::XS', 'JSON::XS');
    foreach my $xs_module (@xs_modules) {
        print "Force reinstalling $xs_module...\n";
        system("cpanm --local-lib=$FindBin::Bin/../local --force --reinstall $xs_module");
    }
    
    # If there were issues with cpanfile installation, try installing critical modules individually
    if ($cpanfile_result != 0) {
        warn "Some dependencies from cpanfile may not have been installed correctly.\n";
        print "Installing critical modules individually...\n";
        
        # First, install the base modules that other modules depend on
        print "Installing base modules...\n";
        my $base_result = system("cpanm --local-lib=$FindBin::Bin/../local Module::Runtime Class::Load Moose");
        
        # Then install email-related modules
        print "Installing email-related modules...\n";
        
        # Define a list of essential modules without duplicates
        my @essential_modules = (
            # Base modules
            "Module::Runtime",
            "Class::Load",
            "Moose",
            
            # Email modules
            "Email::Abstract",
            "Email::Address",
            "Email::Date::Format",
            "Email::MIME", 
            "Email::MIME::ContentType",
            "Email::MIME::Encodings",
            "Email::MessageID",
            "Email::Sender::Simple",
            "Email::Sender::Transport::SMTP",
            "Email::Simple",
            "Email::Simple::Creator",
            "Email::MIME::Creator",
            "Catalyst::View::Email",
            "Catalyst::View::Email::Template",
            
            # Core Catalyst modules
            "Catalyst::Runtime",
            "Catalyst::Model",
            "Catalyst::View::TT",
            "Catalyst::Plugin::ConfigLoader",
            "Catalyst::Plugin::Static::Simple",
            "Catalyst::Plugin::Session",
            "Catalyst::Plugin::Authentication",
            "DBIx::Class",
            "Template",
            
            # Network modules
            "Net::CIDR",
            
            # YAML modules
            "YAML::XS"
        );
        
        my @failed_modules = ();
        
        foreach my $module (@essential_modules) {
            print "Installing $module...\n";
            my $result = system("cpanm --local-lib=$FindBin::Bin/../local $module");
            if ($result != 0) {
                warn "Failed to install $module\n";
                push @failed_modules, $module;
            } else {
                print "Successfully installed $module\n";
            }
        }
        
        if (@failed_modules) {
            warn "Some essential modules may not have been installed correctly.\n";
            print "Retrying failed modules with force flag...\n";
            
            foreach my $module (@failed_modules) {
                print "Force installing $module...\n";
                my $result = system("cpanm --local-lib=$FindBin::Bin/../local --force $module");
                if ($result != 0) {
                    warn "Still failed to install $module even with force flag\n";
                    warn "Some functionality may be limited\n";
                } else {
                    print "Successfully installed $module with force flag\n";
                }
            }
        } else {
            print "All essential modules installed successfully\n";
        }
    } else {
        print "All dependencies from cpanfile installed successfully\n";
        
        # Try again with force flag for any problematic modules
        print "Running a final check with force flag to ensure all modules are installed...\n";
        system("cpanm --local-lib=$FindBin::Bin/../local --force --installdeps $FindBin::Bin/..");
    }
    
    # Add the newly installed modules' path to @INC
    unshift @INC, "$FindBin::Bin/../local/lib/perl5";
    
    # Also add architecture-specific paths
    use Config;
    my $archname = $Config{archname};
    my $version = $Config{version};
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/$archname" if -d "$FindBin::Bin/../local/lib/perl5/$archname";
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/x86_64-linux-gnu-thread-multi" if -d "$FindBin::Bin/../local/lib/perl5/x86_64-linux-gnu-thread-multi";
    
    print "Installation complete. New modules are now available.\n";
} else {
    warn "cpanfile not found at $cpanfile_path. Skipping dependency installation.\n";
}

SKIP_DEPENDENCY_INSTALLATION:

# Specifically install Catalyst::ScriptRunner if not already installed
eval { require Catalyst::ScriptRunner; };
if ($@) {
    print "Installing Catalyst::ScriptRunner...\n";
    my $result = system("cpanm --local-lib=$FindBin::Bin/../local Catalyst::ScriptRunner");

    if ($result != 0) {
        die "Failed to install Catalyst::ScriptRunner. Please install it manually with: cpanm --local-lib=$FindBin::Bin/../local Catalyst::ScriptRunner\n";
    }

    # Add the newly installed module's path to @INC
    unshift @INC, "$FindBin::Bin/../local/lib/perl5";
    
    # Also add architecture-specific paths
    use Config;
    my $archname = $Config{archname};
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/$archname" if -d "$FindBin::Bin/../local/lib/perl5/$archname";
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/x86_64-linux-gnu-thread-multi" if -d "$FindBin::Bin/../local/lib/perl5/x86_64-linux-gnu-thread-multi";

    # Restart the script to ensure the newly installed module is properly loaded
    print "Restarting script to load the newly installed module...\n";
    exec($^X, $0, @ARGV);
    exit;
}

# Now try to use Catalyst::ScriptRunner
eval {
    require Catalyst::ScriptRunner;
    Catalyst::ScriptRunner->import();
};
if ($@) {
    die "Failed to load Catalyst::ScriptRunner even after installation: $@\nPlease install it manually.\n";
}

# Check for all required modules before starting Catalyst
my @required_modules = (
    'YAML::XS',
    'Net::CIDR',
    'Email::MIME',
    'Email::Sender::Simple',
    'Catalyst::View::Email',
    'Catalyst::View::Email::Template',
    'GD',           # For image manipulation
    'GD::Text',
    'PDF::API2',
    'PDF::TextBlock'
);

my @missing_modules = ();
my $need_restart = 0;

# Ensure local lib paths are in @INC before checking modules (already done in BEGIN block)
# Architecture-specific paths are also already added in BEGIN block

# Check if we've already tried installing modules (to prevent infinite loops)
my $install_marker = "$FindBin::Bin/../local/.modules_installed";
my $already_tried_install = -e $install_marker;

# Special handling for YAML modules with fallback options
my $yaml_module_loaded = 0;
my @yaml_alternatives = ('YAML::XS', 'YAML::Syck', 'YAML::Tiny', 'YAML');

foreach my $yaml_module (@yaml_alternatives) {
    eval "require $yaml_module";
    if (!$@) {
        print "Debug: Successfully loaded YAML module: $yaml_module\n" if $ENV{CATALYST_DEBUG};
        $yaml_module_loaded = 1;
        last;
    } else {
        print "Debug: Failed to load $yaml_module: $@\n" if $ENV{CATALYST_DEBUG};
    }
}

if (!$yaml_module_loaded && !$already_tried_install) {
    print "No YAML module found, will install YAML::XS and fallbacks...\n";
    push @missing_modules, 'YAML::XS', 'YAML::Tiny';
}

# Check other required modules
my @other_modules = grep { $_ ne 'YAML::XS' } @required_modules;
foreach my $module (@other_modules) {
    eval "require $module";
    if ($@) {
        print "Debug: Failed to load $module: $@\n" if $ENV{CATALYST_DEBUG};
        push @missing_modules, $module unless $already_tried_install;
    } else {
        print "Debug: Successfully loaded $module\n" if $ENV{CATALYST_DEBUG};
    }
}

if (@missing_modules && !$already_tried_install) {
    print "Installing missing modules: " . join(', ', @missing_modules) . "\n";
    
    # Special handling for GD module which requires system libraries
    if (grep { $_ eq 'GD' } @missing_modules) {
        print "GD module requires system libraries. Checking if they're installed...\n";
        
        # Try to detect Linux distribution
        my $is_debian_based = -f '/etc/debian_version' || -f '/etc/ubuntu_version';
        my $is_redhat_based = -f '/etc/redhat-release' || -f '/etc/centos-release';
        
        if ($is_debian_based) {
            print "Detected Debian/Ubuntu-based system. The following command may need to be run with sudo:\n";
            print "sudo apt-get install -y libgd-dev libpng-dev libjpeg-dev libfreetype6-dev\n";
            print "Please run this command if the installation fails, then restart the application.\n";
        } elsif ($is_redhat_based) {
            print "Detected RedHat/CentOS-based system. The following command may need to be run with sudo:\n";
            print "sudo yum install -y gd-devel libpng-devel libjpeg-devel freetype-devel\n";
            print "Please run this command if the installation fails, then restart the application.\n";
        } else {
            print "Could not detect Linux distribution. You may need to install GD development libraries manually.\n";
            print "Common package names: libgd-dev, gd-devel, libpng-dev, libjpeg-dev, freetype-dev\n";
        }
    }
    
    foreach my $module (@missing_modules) {
        print "Installing $module...\n";
        my $result;
        
        if ($module eq 'GD') {
            # Use force flag for GD module and increase timeout
            print "Installing GD module with extended timeout and force flag...\n";
            $result = system("cpanm --local-lib=$FindBin::Bin/../local --force --verbose --timeout 600 $module");
        } else {
            $result = system("cpanm --local-lib=$FindBin::Bin/../local --force $module");
        }
        
        if ($result != 0) {
            if ($module eq 'GD') {
                warn "Failed to install GD module. This often requires system libraries.\n";
                warn "Please install the required system libraries as mentioned above and retry.\n";
            } else {
                warn "Failed to install $module. Some functionality may be limited.\n";
            }
        } else {
            print "Successfully installed $module\n";
            $need_restart = 1;
        }
    }
    
    if ($need_restart) {
        # Create marker file to prevent infinite loops
        open my $fh, '>', $install_marker or warn "Could not create install marker: $!";
        close $fh if $fh;
        
        # Restart the script to ensure the newly installed modules are properly loaded
        print "Restarting script to load the newly installed modules...\n";
        exec($^X, $0, @ARGV);
        exit;
    }
} elsif (@missing_modules && $already_tried_install) {
    # We've already tried installing, but modules are still missing
    # Continue anyway but warn about missing functionality
    warn "Warning: The following modules are still missing after installation attempt: " . 
         join(', ', @missing_modules) . "\n";
    warn "Some functionality may be limited.\n";
}

Catalyst::ScriptRunner->run('Comserv', 'Server');

1;

# ... (rest of your POD documentation)
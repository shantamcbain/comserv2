#!/usr/bin/env perl

use FindBin;

BEGIN {
    $ENV{CATALYST_SCRIPT_GEN} = 40;

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
}

# Ensure the local directory exists
unless (-d "$FindBin::Bin/../local") {
    mkdir "$FindBin::Bin/../local" or die "Could not create local directory: $!";
}

# Automatically install dependencies locally
print "Installing dependencies from cpanfile...\n";
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
            "Template"
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
    
    print "Installation complete. New modules are now available.\n";
} else {
    warn "cpanfile not found at $cpanfile_path. Skipping dependency installation.\n";
}

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

# Check if email-related modules are properly loaded
eval {
    require Catalyst::View::Email;
    require Catalyst::View::Email::Template;
    require Email::MIME;
    require Email::Sender::Simple;
};
if ($@) {
    warn "Warning: Some email modules could not be loaded: $@\n";
    warn "Email functionality may not work correctly.\n";
    warn "Installing missing email modules...\n";
    
    # Extract the specific modules that failed to load from the error message
    my @missing_modules = ();
    if ($@ =~ /Can't locate (.*?)\.pm/) {
        my $missing_module = $1;
        $missing_module =~ s|/|::|g;
        push @missing_modules, $missing_module;
    }
    
    # If we couldn't extract specific modules, install all email modules
    if (!@missing_modules) {
        @missing_modules = (
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
            "Catalyst::View::Email::Template"
        );
    }
    
    # Install only the missing modules
    print "Installing " . scalar(@missing_modules) . " missing email modules...\n";
    foreach my $module (@missing_modules) {
        print "Installing $module...\n";
        my $result = system("cpanm --local-lib=$FindBin::Bin/../local --force $module");
        if ($result != 0) {
            warn "Failed to install $module. Email functionality may be limited.\n";
        } else {
            print "Successfully installed $module\n";
        }
    }
    
    # Add the newly installed modules' path to @INC
    unshift @INC, "$FindBin::Bin/../local/lib/perl5";
}

Catalyst::ScriptRunner->run('Comserv', 'Server');

1;

# ... (rest of your POD documentation)
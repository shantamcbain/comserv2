package Comserv::Util::PDFConverter;

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);
use JSON;
use Carp qw(croak);
use Log::Log4perl qw(:easy);
use IPC::Open3;
use Symbol qw(gensym);

# Initialize logging if not already done
BEGIN {
    unless (Log::Log4perl->initialized()) {
        # Set up a more detailed logging configuration
        my $log_conf = qq(
            log4perl.rootLogger              = DEBUG, SCREEN, LOGFILE
            log4perl.appender.SCREEN         = Log::Log4perl::Appender::Screen
            log4perl.appender.SCREEN.stderr  = 0
            log4perl.appender.SCREEN.layout  = PatternLayout
            log4perl.appender.SCREEN.layout.ConversionPattern = [%d] [%p] %m%n
            log4perl.appender.LOGFILE        = Log::Log4perl::Appender::File
            log4perl.appender.LOGFILE.filename = /home/shanta/PycharmProjects/comserv2/Comserv/logs/pdfconverter.log
            log4perl.appender.LOGFILE.mode   = append
            log4perl.appender.LOGFILE.layout = PatternLayout
            log4perl.appender.LOGFILE.layout.ConversionPattern = [%d] [%p] %F{1}:%L %M - %m%n
        );
        Log::Log4perl->init(\$log_conf);
    }
}

# Try to load optional modules
our $USE_PERL_MODULES = 1;
BEGIN {
    eval {
        require PDF::API2;
        require PDF::TextBlock;
        require GD;
        require GD::Text;
        
        PDF::API2->import();
        PDF::TextBlock->import();
        GD->import(qw(:all)); # Import all constants including gdLargeFont
        GD::Text->import();
    };
    if ($@) {
        warn "Could not load Perl PDF/GD modules: $@";
        warn "Will fall back to Python-based PDF conversion";
        $USE_PERL_MODULES = 0;
    }
}

=head1 NAME

Comserv::Util::PDFConverter - Utility module for PDF conversion to web format

=head1 SYNOPSIS

    use Comserv::Util::PDFConverter;
    
    my $converter = Comserv::Util::PDFConverter->new();
    my $result = $converter->convert_pdf_to_web(
        pdf_path => '/path/to/file.pdf',
        output_dir => '/path/to/output',
        base_name => 'presentation',
        format => 'jpg',      # optional, default: jpg
        quality => 85,        # optional, default: 85
        dpi => 200,           # optional, default: 200
        width => 1024         # optional, default: no resize
    );
    
    if ($result->{status} eq 'success') {
        print "Converted PDF: $result->{html_file}\n";
    } else {
        die "Error: $result->{message}\n";
    }

=head1 DESCRIPTION

This module provides functionality to convert PDF files to web-viewable content.
It extracts each page as an image and creates HTML files for viewing.

=head1 FEATURES

=over 4

=item * Converts PDF files to image sequences (JPG or PNG)

=item * Creates HTML slideshows with navigation and thumbnails

=item * Generates metadata JSON files

=item * Automatic fallback from Perl to Python if Perl modules are missing

=item * Automatic Python dependency installation

=back

=head1 DEPENDENCIES

=head2 Perl Dependencies

=over 4

=item * PDF::API2

=item * PDF::TextBlock

=item * GD

=item * GD::Text

=back

=head2 Python Dependencies (automatically installed if needed)

=over 4

=item * pdf2image

=item * Pillow

=item * poppler-utils (system dependency)

=back

=head1 FALLBACK MECHANISM

The module tries to use Perl modules first (PDF::API2, GD, etc.). If these are not available, 
it automatically falls back to a Python-based conversion using the included Python script 
(C<pdf_converter.py>). This script automatically installs its own dependencies if they're missing.

=head1 TROUBLESHOOTING

=head2 Perl Module Installation Issues

If you encounter issues with Perl module installation, particularly with GD, the fallback to 
Python should work automatically. However, if you still want to use the Perl modules, you 
might need to install some system dependencies:

=head3 Debian/Ubuntu

    sudo apt-get install libgd-dev libpng-dev libjpeg-dev libfreetype6-dev

=head3 RHEL/CentOS

    sudo yum install gd-devel libpng-devel libjpeg-devel freetype-devel

=head2 Python Dependency Issues

If you encounter issues with the Python fallback, ensure you have poppler-utils installed:

=head3 Debian/Ubuntu

    sudo apt-get install poppler-utils

=head3 RHEL/CentOS

    sudo yum install poppler-utils

=head1 OUTPUT STRUCTURE

=over 4

=item * C<{base_name}.html> - The main HTML slideshow

=item * C<{base_name}_slide_{n}.{format}> - Individual slide images

=item * C<{base_name}_metadata.json> - Metadata about the slideshow

=back

=head1 METHODS

=head2 new

Creates a new PDFConverter object.

=cut

sub new {
    my ($class) = @_;
    my $self = {};
    bless $self, $class;
    $self->{logger} = get_logger();
    return $self;
}

=head2 convert_pdf_to_web

Converts a PDF file to web-viewable format.

Parameters:
    pdf_path   - Path to the PDF file
    output_dir - Directory where output files will be stored
    base_name  - Base name for output files
    format     - Image format (jpg or png, default: jpg)
    quality    - Image quality 1-100 (default: 85)
    dpi        - DPI for rendering (default: 200)
    width      - Width to resize images (optional)

Returns a hashref with:
    status       - 'success' or 'error'
    message      - Description of result or error
    html_file    - Path to the generated HTML file (if successful)
    metadata_file - Path to the generated metadata JSON file (if successful)
    slide_count  - Number of slides converted (if successful)

=cut

sub convert_pdf_to_web {
    my ($self, %params) = @_;
    
    # Required parameters
    my $pdf_path = $params{pdf_path} or croak "Missing required parameter: pdf_path";
    my $output_dir = $params{output_dir} or croak "Missing required parameter: output_dir";
    my $base_name = $params{base_name} or croak "Missing required parameter: base_name";
    
    # Optional parameters with defaults
    my $format = $params{format} || 'jpg';
    my $quality = $params{quality} || 85;
    my $dpi = $params{dpi} || 200;
    my $width = $params{width}; # Optional, no default
    
    # Validate parameters
    unless (-f $pdf_path) {
        return {
            status => 'error',
            message => "PDF file not found: $pdf_path"
        };
    }
    
    unless ($format =~ /^(jpg|png)$/i) {
        return {
            status => 'error',
            message => "Invalid format: $format (must be jpg or png)"
        };
    }
    
    # Create output directory if it doesn't exist
    unless (-d $output_dir) {
        make_path($output_dir) or die "Cannot create output directory: $!";
    }
    
    $self->{logger}->info("Converting PDF: $pdf_path");
    $self->{logger}->info("Output directory: $output_dir");
    
    # Try Python conversion first if Perl modules are not available
    if (!$USE_PERL_MODULES) {
        $self->{logger}->info("Using Python-based PDF conversion");
        my $python_result = $self->_convert_pdf_with_python(%params);
        return $python_result if $python_result;
        
        # If Python conversion failed, fall back to error
        $self->{logger}->error("Python-based conversion failed");
        return {
            status => 'error',
            message => "Both Perl and Python PDF conversion methods failed"
        };
    }

    # If we're here, we're using Perl modules
    # Start the conversion process with Perl modules
    eval {
        # Open the PDF file
        my $pdf = PDF::API2->open($pdf_path) or die "Cannot open PDF: $!";
        my $num_pages = $pdf->pages();
        
        $self->{logger}->info("PDF has $num_pages pages");
        
        # Process each page
        for my $page_num (1 .. $num_pages) {
            $self->{logger}->info("Processing page $page_num of $num_pages");
            
            # Get page dimensions
            my $page = $pdf->openpage($page_num);
            my @box = $page->mediabox();
            my $width_pt = $box[2] - $box[0];
            my $height_pt = $box[3] - $box[1];
            
            # Convert points to pixels using DPI
            my $scale_factor = $dpi / 72;  # 72 points per inch
            my $img_width = int($width_pt * $scale_factor);
            my $img_height = int($height_pt * $scale_factor);
            
            # Resize if width is specified
            if ($width && $img_width > $width) {
                my $aspect = $img_height / $img_width;
                $img_width = $width;
                $img_height = int($img_width * $aspect);
            }
            
            # Create a new GD image
            my $gd = GD::Image->new($img_width, $img_height);
            
            # Allocate colors
            my $white = $gd->colorAllocate(255, 255, 255);
            my $black = $gd->colorAllocate(0, 0, 0);
            my $gray = $gd->colorAllocate(200, 200, 200);
            
            # Fill background
            $gd->filledRectangle(0, 0, $img_width-1, $img_height-1, $white);
            
            # Draw a border and "PDF Page $page_num" text
            $gd->rectangle(0, 0, $img_width-1, $img_height-1, $gray);
            
            # Create a simple representation of the PDF page
            my $fontsize = int($img_height / 20);
            $fontsize = 12 if $fontsize < 12;
            
            # Draw page number
            my $text = "PDF Page $page_num";
            my $text_width = $fontsize * length($text) * 0.6;  # Estimate text width
            my $x = int(($img_width - $text_width) / 2);
            my $y = int($img_height / 2);
            
            # Use GD::Font object instead of bareword constant to avoid strict errors
            my $large_font = GD::Font->Large;
            $gd->string($large_font, $x, $y, $text, $black);
            
            # Save the image
            my $img_path = File::Spec->catfile($output_dir, "${base_name}_slide_${page_num}.${format}");
            
            open my $img_fh, '>', $img_path or die "Cannot open $img_path for writing: $!";
            binmode $img_fh;
            
            # Save in the appropriate format
            my $img_data;
            if (lc($format) eq 'jpg' || lc($format) eq 'jpeg') {
                $img_data = $gd->jpeg($quality);
            }
            elsif (lc($format) eq 'png') {
                $img_data = $gd->png();
            }
            else {
                die "Unsupported image format: $format";
            }
            
            print $img_fh $img_data;
            close $img_fh;
            
            $self->{logger}->info("Saved slide $page_num to $img_path");
        }
        
        # Create HTML slideshow
        my $html_path = $self->_create_slideshow_html($output_dir, $base_name, $num_pages, $format);
        
        # Create metadata JSON
        my $json_path = $self->_create_metadata_json($output_dir, $base_name, $num_pages, $format);
        
        return {
            status => 'success',
            message => "Successfully converted $num_pages pages using Perl modules",
            html_file => $html_path,
            metadata_file => $json_path,
            slide_count => $num_pages
        };
    };
    
    if ($@) {
        $self->{logger}->error("Perl module error: $@");
        $self->{logger}->info("Falling back to Python-based PDF conversion");
        
        # Try Python conversion as a fallback
        my $python_result = $self->_convert_pdf_with_python(%params);
        return $python_result if $python_result;
        
        # If Python fallback also failed, return the original error
        return {
            status => 'error',
            message => "Perl error: $@\nPython fallback also failed."
        };
    }
}

# Helper method to convert PDF using Python
sub _convert_pdf_with_python {
    my ($self, %params) = @_;
    
    # Required parameters
    my $pdf_path = $params{pdf_path};
    my $output_dir = $params{output_dir};
    my $base_name = $params{base_name};
    
    # Optional parameters with defaults
    my $format = $params{format} || 'jpg';
    my $quality = $params{quality} || 85;
    my $dpi = $params{dpi} || 200;
    my $width = $params{width} || 0; # 0 means no resizing
    
    # Create Python converter script if it doesn't exist
    my $python_script = $self->_ensure_python_converter();
    
    # Build command
    my $command = "python3 $python_script";
    $command .= " --pdf_path " . quotemeta($pdf_path);
    $command .= " --output_dir " . quotemeta($output_dir);
    $command .= " --base_name " . quotemeta($base_name);
    $command .= " --format " . quotemeta($format);
    $command .= " --quality $quality";
    $command .= " --dpi $dpi";
    $command .= " --width $width" if $width;
    
    $self->{logger}->info("Running Python converter: $command");
    
    # Capture stdout, stderr
    my ($child_in, $child_out, $child_err);
    $child_err = gensym();  # Autovivify file handle for stderr
    
    my $pid = open3($child_in, $child_out, $child_err, $command);
    
    # Close child's stdin as we don't need to write to it
    close($child_in);
    
    # Read output from the command
    my @output = <$child_out>;
    my @errors = <$child_err>;
    
    # Wait for the command to finish
    waitpid($pid, 0);
    my $exit_code = $? >> 8;
    
    # Close file handles
    close($child_out);
    close($child_err);
    
    # Always log the command and output for debugging
    $self->{logger}->debug("Command executed: $command");
    $self->{logger}->debug("Standard output length: " . length(join("", @output)) . " bytes");
    
    # Try to install dependencies first if they might be missing
    if (grep { /ModuleNotFoundError|ImportError/i } @errors) {
        $self->{logger}->info("Python module not found, attempting to install dependencies...");
        $self->_install_python_dependencies();
        
        # Try the command again after installing dependencies
        my ($child_in2, $child_out2, $child_err2);
        $child_err2 = gensym();
        
        my $pid2 = open3($child_in2, $child_out2, $child_err2, $command);
        close($child_in2);
        
        my @output2 = <$child_out2>;
        my @errors2 = <$child_err2>;
        
        waitpid($pid2, 0);
        my $exit_code2 = $? >> 8;
        
        close($child_out2);
        close($child_err2);
        
        if ($exit_code2 == 0) {
            $self->{logger}->info("Command succeeded after installing dependencies");
            @output = @output2;
            @errors = @errors2;
            $exit_code = 0;
        } else {
            $self->{logger}->error("Command still failed after installing dependencies");
            $self->{logger}->error("Error output: " . join("", @errors2));
        }
    }
    
    if ($exit_code != 0) {
        $self->{logger}->error("Python conversion failed with exit code $exit_code");
        $self->{logger}->error("Error output: " . join("", @errors));
        
        # Try to parse any JSON in stdout that might contain error details
        my $json_error = undef;
        eval {
            my $output_str = join("", @output);
            if ($output_str =~ /\{.*\}/) {
                my $json_result = decode_json($output_str);
                if ($json_result && $json_result->{status} eq 'error') {
                    $json_error = $json_result;
                }
            }
        };
        
        # If we have a proper JSON error from the Python script, use it
        if ($json_error) {
            $self->{logger}->error("Structured error from Python: $json_error->{message}");
            return $json_error;
        }
        
        # Check if poppler-utils is the issue
        if (grep { /poppler/i } @errors) {
            $self->{logger}->error("Poppler utilities appear to be missing. Try installing poppler-utils package.");
            return {
                status => 'error',
                message => "PDF conversion failed: poppler-utils not installed. Please run 'sudo apt-get install poppler-utils' and try again."
            };
        }
        
        # Check for Python module installation issues
        if (grep { /ModuleNotFoundError|ImportError/i } @errors) {
            $self->{logger}->error("Python module installation failed. Check Python environment.");
            return {
                status => 'error',
                message => "PDF conversion failed: Python module installation error. " . 
                           "Error details: " . join("", @errors)
            };
        }
        
        # Check for permission issues
        if (grep { /permission denied/i } @errors) {
            $self->{logger}->error("Permission issues detected during PDF conversion.");
            return {
                status => 'error',
                message => "PDF conversion failed: Permission denied. Check file and directory permissions."
            };
        }
        
        # Check for file format issues
        if (grep { /not a PDF file|invalid PDF/i } @errors) {
            $self->{logger}->error("Invalid PDF format detected.");
            return {
                status => 'error',
                message => "The file is not a valid PDF or is corrupted."
            };
        }
        
        # Check for memory issues
        if (grep { /memory|allocation/i } @errors) {
            $self->{logger}->error("Memory allocation issues detected.");
            return {
                status => 'error',
                message => "PDF conversion failed: Not enough memory. The PDF might be too large or complex."
            };
        }
        
        # General error case
        return {
            status => 'error',
            message => "PDF conversion failed. Check logs for details."
        };
    }
    
    # Try to parse JSON output from Python script
    my $json_output = join("", @output);
    my $result;
    
    eval {
        $result = decode_json($json_output);
    };
    
    if ($@ || !$result) {
        $self->{logger}->error("Failed to parse JSON output from Python script: $@");
        $self->{logger}->error("Raw output: $json_output");
        return undef;
    }
    
    return $result;
}

# Helper method to install Python dependencies
sub _install_python_dependencies {
    my ($self) = @_;
    
    $self->{logger}->info("Checking Python dependencies...");
    
    # Path to requirements file
    my $requirements_file = "pdf_converter_requirements.txt";
    
    # Check if requirements file exists
    unless (-f $requirements_file) {
        $self->{logger}->warn("Requirements file not found: $requirements_file");
        return;
    }
    
    # Try to install dependencies using pip
    eval {
        my $cmd = "python3 -m pip install --user -r $requirements_file";
        $self->{logger}->info("Installing Python dependencies: $cmd");
        
        my $output = `$cmd 2>&1`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            $self->{logger}->warn("Failed to install Python dependencies: $output");
        } else {
            $self->{logger}->info("Python dependencies installed successfully");
        }
    };
    
    if ($@) {
        $self->{logger}->warn("Error installing Python dependencies: $@");
    }
}

# Create Python converter script if it doesn't exist
sub _ensure_python_converter {
    my ($self) = @_;
    
    my $script_dir = File::Spec->catdir(File::Spec->curdir(), "script");
    my $script_path = File::Spec->catfile($script_dir, "pdf_converter.py");
    
    # Check if script already exists
    if (-f $script_path) {
        $self->{logger}->debug("Found existing Python converter script: $script_path");
        
        # Try to install dependencies automatically
        $self->_install_python_dependencies();
        
        return $script_path;
    }
    
    # Create directory if needed
    unless (-d $script_dir) {
        make_path($script_dir) or die "Cannot create script directory: $!";
    }
    
    # Create the Python script - only create it if it doesn't exist
    my $fh;
    unless (open $fh, '>', $script_path) {
        $self->{logger}->error("Cannot create Python script: $!");
        die "Cannot create Python script: $!";
    }
    
    # Write the Python script content
    print $fh <<'PYTHON_SCRIPT';
#!/usr/bin/env python3
"""
PDF to Web Converter - Converts PDF files to web-viewable format

This script converts PDF files to image files and creates an HTML slideshow.
It can be used as a standalone script or as a module.

Dependencies:
- pdf2image (which requires poppler-utils)
- Pillow
- argparse
- json
- os
- sys

Installation:
If dependencies are missing, the script will attempt to install them automatically.
"""

import os
import sys
import json
import argparse
import tempfile
import shutil
from pathlib import Path
import subprocess
import importlib.util

# Function to check if a module is installed
def is_module_installed(module_name):
    """Check if a Python module is installed."""
    return importlib.util.find_spec(module_name) is not None

# Function to install required modules
def install_required_modules():
    """Install required Python modules if they are not already installed."""
    required_modules = ['pdf2image', 'pillow']
    
    modules_to_install = []
    for module in required_modules:
        if not is_module_installed(module):
            if module == 'pillow':
                modules_to_install.append('Pillow')  # Correct package name for pip
            else:
                modules_to_install.append(module)
    
    if modules_to_install:
        print(f"Installing required modules: {', '.join(modules_to_install)}")
        subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--user'] + modules_to_install)
        
        # After installing pdf2image, we need to check for poppler-utils
        if 'pdf2image' in modules_to_install:
            try:
                # Try to import pdf2image
                from pdf2image import convert_from_path
                # Try a simple conversion to see if poppler is installed
                with tempfile.NamedTemporaryFile(suffix='.pdf') as temp_pdf:
                    try:
                        convert_from_path(temp_pdf.name, dpi=72, first_page=1, last_page=1)
                    except Exception as e:
                        if "poppler" in str(e).lower():
                            print("pdf2image requires poppler-utils to be installed.")
                            print("Please install poppler-utils for your system.")
                            print("For Debian/Ubuntu: sudo apt-get install poppler-utils")
                            print("For CentOS/RHEL: sudo yum install poppler-utils")
                            print("For macOS: brew install poppler")
                            sys.exit(1)
            except ImportError:
                print("Failed to import pdf2image after installation.")
                sys.exit(1)

# Install required modules before importing them
install_required_modules()

# Now we can safely import these modules
from pdf2image import convert_from_path
from PIL import Image, ImageDraw, ImageFont

def convert_pdf_to_web(pdf_path, output_dir, base_name, format='jpg', quality=85, dpi=200, width=None):
    """
    Convert a PDF file to web-viewable format.
    
    Args:
        pdf_path (str): Path to the PDF file
        output_dir (str): Directory where output files will be stored
        base_name (str): Base name for output files
        format (str, optional): Image format ('jpg' or 'png'). Defaults to 'jpg'.
        quality (int, optional): Image quality (1-100). Defaults to 85.
        dpi (int, optional): DPI for rendering. Defaults to 200.
        width (int, optional): Width to resize images. Defaults to None.
    
    Returns:
        dict: Result of the conversion
    """
    # Validate parameters
    if not os.path.isfile(pdf_path):
        return {
            'status': 'error',
            'message': f"PDF file not found: {pdf_path}"
        }
    
    if format.lower() not in ['jpg', 'jpeg', 'png']:
        return {
            'status': 'error',
            'message': f"Invalid format: {format} (must be jpg or png)"
        }
    
    # Create output directory if it doesn't exist
    os.makedirs(output_dir, exist_ok=True)
    
    try:
        # Convert PDF to images
        images = convert_from_path(
            pdf_path,
            dpi=dpi,
            fmt=format.lower(),
            output_folder=None  # Don't save to disk yet
        )
        
        # Process and save each image
        slide_paths = []
        for i, img in enumerate(images, 1):
            # Resize if width is specified
            if width and img.width > width:
                ratio = img.height / img.width
                new_height = int(width * ratio)
                img = img.resize((width, new_height), Image.LANCZOS)
            
            # Save the image
            img_filename = f"{base_name}_slide_{i}.{format.lower()}"
            img_path = os.path.join(output_dir, img_filename)
            
            if format.lower() in ['jpg', 'jpeg']:
                img.save(img_path, quality=quality, optimize=True)
            else:  # png
                img.save(img_path, optimize=True)
            
            slide_paths.append(img_path)
        
        # Create HTML slideshow
        html_path = create_slideshow_html(output_dir, base_name, len(images), format)
        
        # Create metadata JSON
        json_path = create_metadata_json(output_dir, base_name, len(images), format)
        
        return {
            'status': 'success',
            'message': f"Successfully converted {len(images)} pages using Python",
            'html_file': html_path,
            'metadata_file': json_path,
            'slide_count': len(images)
        }
        
    except Exception as e:
        error_message = str(e)
        return {
            'status': 'error',
            'message': f"Error in Python PDF conversion: {error_message}"
        }

def create_slideshow_html(output_dir, base_name, num_pages, img_format):
    """Create an HTML slideshow from the converted images."""
    
    title = base_name.replace('_', ' ')
    title = ' '.join(word.capitalize() for word in title.split())
    title += " Presentation"
    
    html_path = os.path.join(output_dir, f"{base_name}.html")
    
    with open(html_path, 'w') as f:
        f.write(f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{title}</title>
    <style>
        body {{
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 0;
            background-color: #f5f5f5;
        }}
        .slideshow-container {{
            max-width: 1000px;
            position: relative;
            margin: auto;
            background-color: white;
            box-shadow: 0 0 10px rgba(0,0,0,0.1);
            padding: 20px;
            border-radius: 8px;
            margin-top: 20px;
        }}
        .slide {{
            display: none;
            text-align: center;
        }}
        .slide.active {{
            display: block;
        }}
        .slide img {{
            max-width: 100%;
            height: auto;
            border: 1px solid #ddd;
        }}
        .navigation {{
            text-align: center;
            margin: 20px 0;
        }}
        .nav-button {{
            background-color: #4CAF50;
            color: white;
            border: none;
            padding: 10px 15px;
            text-align: center;
            text-decoration: none;
            display: inline-block;
            font-size: 16px;
            margin: 4px 2px;
            cursor: pointer;
            border-radius: 4px;
        }}
        .slide-number {{
            color: #555;
            font-size: 14px;
            padding: 8px 12px;
            position: absolute;
            top: 0;
            right: 0;
        }}
        .thumbnails {{
            display: flex;
            flex-wrap: wrap;
            justify-content: center;
            margin-top: 20px;
        }}
        .thumbnail {{
            margin: 5px;
            cursor: pointer;
            border: 2px solid transparent;
            width: 100px;
            height: 75px;
            background-size: cover;
            background-position: center;
        }}
        .thumbnail.active {{
            border-color: #4CAF50;
        }}
    </style>
</head>
<body>
    <div class="slideshow-container">
        <div class="navigation">
            <button class="nav-button" onclick="prevSlide()">Previous</button>
            <span id="slide-counter">Slide 1 of {num_pages}</span>
            <button class="nav-button" onclick="nextSlide()">Next</button>
        </div>
""")
        
        # Add slides
        for i in range(1, num_pages + 1):
            f.write(f"""        <div class="slide" data-slide="{i}">
            <img src="{base_name}_slide_{i}.{img_format}" alt="Slide {i}">
            <div class="slide-number">{i} / {num_pages}</div>
        </div>
""")
        
        # Add thumbnails
        f.write("""        <div class="thumbnails">
""")
        
        for i in range(1, num_pages + 1):
            f.write(f"""            <div class="thumbnail" onclick="showSlide({i})" style="background-image: url('{base_name}_slide_{i}.{img_format}')"></div>
""")
        
        f.write("""        </div>
    </div>

    <script>
        let currentSlide = 1;
        const totalSlides = """ + str(num_pages) + """;
        
        // Show the first slide initially
        document.querySelector('.slide[data-slide="1"]').classList.add('active');
        document.querySelector('.thumbnail:nth-child(1)').classList.add('active');
        
        function showSlide(slideNumber) {
            // Hide all slides
            document.querySelectorAll('.slide').forEach(slide => {
                slide.classList.remove('active');
            });
            
            // Remove active class from all thumbnails
            document.querySelectorAll('.thumbnail').forEach(thumb => {
                thumb.classList.remove('active');
            });
            
            // Show the selected slide
            document.querySelector(`.slide[data-slide="${slideNumber}"]`).classList.add('active');
            
            // Highlight the current thumbnail
            document.querySelector(`.thumbnail:nth-child(${slideNumber})`).classList.add('active');
            
            // Update slide counter
            document.getElementById('slide-counter').textContent = `Slide ${slideNumber} of ${totalSlides}`;
            
            // Update current slide tracker
            currentSlide = slideNumber;
        }
        
        function nextSlide() {
            if (currentSlide < totalSlides) {
                showSlide(currentSlide + 1);
            }
        }
        
        function prevSlide() {
            if (currentSlide > 1) {
                showSlide(currentSlide - 1);
            }
        }
        
        // Add keyboard navigation
        document.addEventListener('keydown', function(e) {
            if (e.key === 'ArrowRight' || e.key === ' ') {
                nextSlide();
            } else if (e.key === 'ArrowLeft') {
                prevSlide();
            }
        });
    </script>
</body>
</html>
""")
    
    return html_path

def create_metadata_json(output_dir, base_name, num_pages, img_format):
    """Create a metadata JSON file for the slideshow."""
    
    json_path = os.path.join(output_dir, f"{base_name}_metadata.json")
    
    metadata = {
        'title': base_name.replace('_', ' ').title(),
        'slide_count': num_pages,
        'format': img_format,
        'slides': []
    }
    
    for i in range(1, num_pages + 1):
        metadata['slides'].append({
            'number': i,
            'filename': f"{base_name}_slide_{i}.{img_format}",
            'title': f"Slide {i}"
        })
    
    with open(json_path, 'w') as f:
        json.dump(metadata, f, indent=2)
    
    return json_path

def main():
    """Main function when running as a script."""
    parser = argparse.ArgumentParser(description='Convert PDF to web-viewable format')
    parser.add_argument('--pdf_path', required=True, help='Path to the PDF file')
    parser.add_argument('--output_dir', required=True, help='Directory where output files will be stored')
    parser.add_argument('--base_name', required=True, help='Base name for output files')
    parser.add_argument('--format', default='jpg', help='Image format (jpg or png)')
    parser.add_argument('--quality', type=int, default=85, help='Image quality (1-100)')
    parser.add_argument('--dpi', type=int, default=200, help='DPI for rendering')
    parser.add_argument('--width', type=int, default=0, help='Width to resize images (0 means no resizing)')
    
    args = parser.parse_args()
    
    # Convert width=0 to None (no resizing)
    width = args.width if args.width > 0 else None
    
    result = convert_pdf_to_web(
        args.pdf_path,
        args.output_dir,
        args.base_name,
        args.format,
        args.quality,
        args.dpi,
        width
    )
    
    # Print the result as JSON to stdout (will be captured by the Perl script)
    print(json.dumps(result))

if __name__ == "__main__":
    main()
PYTHON_SCRIPT

    close $fh;
    chmod 0755, $script_path or die "Cannot make Python script executable: $!";
    
    $self->{logger}->info("Created Python PDF converter script at $script_path");
    return $script_path;
}

# Private method to create HTML slideshow
sub _create_slideshow_html {
    my ($self, $output_dir, $base_name, $num_pages, $img_format) = @_;
    
    my $title = $base_name;
    $title =~ s/_/ /g;
    $title = join ' ', map { ucfirst $_ } split /\s+/, $title;
    $title .= " Presentation";
    
    my $html_path = File::Spec->catfile($output_dir, "${base_name}.html");
    
    open my $fh, '>', $html_path or die "Cannot open $html_path for writing: $!";
    
    print $fh <<HTML;
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$title</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 0;
            background-color: #f5f5f5;
        }
        .slideshow-container {
            max-width: 1000px;
            position: relative;
            margin: auto;
            background-color: white;
            box-shadow: 0 0 10px rgba(0,0,0,0.1);
            padding: 20px;
            border-radius: 8px;
            margin-top: 20px;
        }
        .slide {
            display: none;
            text-align: center;
        }
        .slide.active {
            display: block;
        }
        .slide img {
            max-width: 100%;
            height: auto;
            border: 1px solid #ddd;
        }
        .navigation {
            text-align: center;
            margin: 20px 0;
        }
        .nav-button {
            background-color: #4CAF50;
            color: white;
            border: none;
            padding: 10px 15px;
            text-align: center;
            text-decoration: none;
            display: inline-block;
            font-size: 16px;
            margin: 4px 2px;
            cursor: pointer;
            border-radius: 4px;
        }
        .slide-number {
            color: #555;
            font-size: 14px;
            padding: 8px 12px;
            position: absolute;
            top: 0;
            right: 0;
        }
        .thumbnails {
            display: flex;
            flex-wrap: wrap;
            justify-content: center;
            margin-top: 20px;
        }
        .thumbnail {
            margin: 5px;
            cursor: pointer;
            border: 2px solid transparent;
            width: 100px;
            height: 75px;
            background-size: cover;
            background-position: center;
        }
        .thumbnail.active {
            border-color: #4CAF50;
        }
    </style>
</head>
<body>
    <div class="slideshow-container">
        <div class="navigation">
            <button class="nav-button" onclick="prevSlide()">Previous</button>
            <span id="slide-counter">Slide 1 of $num_pages</span>
            <button class="nav-button" onclick="nextSlide()">Next</button>
        </div>
HTML
    
    # Add slides
    for my $i (1 .. $num_pages) {
        print $fh <<HTML;
        <div class="slide" data-slide="$i">
            <img src="${base_name}_slide_${i}.${img_format}" alt="Slide $i">
            <div class="slide-number">$i / $num_pages</div>
        </div>
HTML
    }
    
    # Add thumbnails
    print $fh <<HTML;
        <div class="thumbnails">
HTML
    
    for my $i (1 .. $num_pages) {
        print $fh <<HTML;
            <div class="thumbnail" onclick="showSlide($i)" style="background-image: url('${base_name}_slide_${i}.${img_format}')"></div>
HTML
    }
    
    print $fh <<HTML;
        </div>
    </div>

    <script>
        let currentSlide = 1;
        const totalSlides = $num_pages;
        
        // Show the first slide initially
        document.querySelector('.slide[data-slide="1"]').classList.add('active');
        document.querySelector('.thumbnail:nth-child(1)').classList.add('active');
        
        function showSlide(slideNumber) {
            // Hide all slides
            document.querySelectorAll('.slide').forEach(slide => {
                slide.classList.remove('active');
            });
            
            // Remove active class from all thumbnails
            document.querySelectorAll('.thumbnail').forEach(thumb => {
                thumb.classList.remove('active');
            });
            
            // Show the selected slide
            document.querySelector(\`.slide[data-slide="\${slideNumber}"]\`).classList.add('active');
            
            // Highlight the current thumbnail
            document.querySelector(\`.thumbnail:nth-child(\${slideNumber})\`).classList.add('active');
            
            // Update slide counter
            document.getElementById('slide-counter').textContent = \`Slide \${slideNumber} of \${totalSlides}\`;
            
            // Update current slide tracker
            currentSlide = slideNumber;
        }
        
        function nextSlide() {
            if (currentSlide < totalSlides) {
                showSlide(currentSlide + 1);
            }
        }
        
        function prevSlide() {
            if (currentSlide > 1) {
                showSlide(currentSlide - 1);
            }
        }
        
        // Add keyboard navigation
        document.addEventListener('keydown', function(e) {
            if (e.key === 'ArrowRight' || e.key === ' ') {
                nextSlide();
            } else if (e.key === 'ArrowLeft') {
                prevSlide();
            }
        });
    </script>
</body>
</html>
HTML
    
    close $fh;
    
    $self->{logger}->info("Created HTML slideshow at $html_path");
    return $html_path;
}

# Private method to create metadata JSON
sub _create_metadata_json {
    my ($self, $output_dir, $base_name, $num_pages, $img_format) = @_;
    
    my $title = $base_name;
    $title =~ s/_/ /g;
    $title = join ' ', map { ucfirst $_ } split /\s+/, $title;
    $title .= " Presentation";
    
    my @slide_images = map { "${base_name}_slide_${_}.${img_format}" } (1 .. $num_pages);
    
    my $metadata = {
        title => $title,
        slides_count => $num_pages,
        image_format => $img_format,
        base_name => $base_name,
        html_file => "${base_name}.html",
        slide_images => \@slide_images
    };
    
    my $json_path = File::Spec->catfile($output_dir, "${base_name}_metadata.json");
    open my $fh, '>', $json_path or die "Cannot open $json_path for writing: $!";
    print $fh encode_json($metadata);
    close $fh;
    
    $self->{logger}->info("Created metadata JSON at $json_path");
    return $json_path;
}

1;
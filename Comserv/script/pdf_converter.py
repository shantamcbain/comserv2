#!/usr/bin/env python3
"""
PDF Converter for Workshop Presentations

This script converts PDF presentations to web-viewable content.
It extracts each page as an image and creates HTML files for viewing.
"""

import os
import sys
import json
import argparse
from pathlib import Path
import tempfile
import logging
import traceback
import subprocess
import re
import importlib

# Setup basic logging first (will be enhanced later)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger('pdf_converter')

# First, try to ensure dependencies are installed
def ensure_dependencies():
    """Check and install required dependencies."""
    try:
        # Try to import required modules
        try:
            import pdf2image
            from PIL import Image
            logger.info("Required Python modules are already installed.")
            return True
        except ImportError as e:
            missing_module = str(e).split("'")[1] if "'" in str(e) else "unknown module"
            logger.warning(f"Missing Python module: {missing_module}")
            
            # Check if pip is available for auto-installation
            try:
                import pip
                logger.info("Pip is available for installing dependencies.")
            except ImportError:
                logger.error("Pip is not available. Cannot install dependencies automatically.")
                print(json.dumps({
                    "status": "error",
                    "message": "Missing required Python modules and pip is not available for automatic installation."
                }))
                sys.exit(1)
            
            # Install missing dependencies
            try:
                logger.info("Attempting to install required Python modules...")
                requirements = ["pdf2image", "Pillow"]
                
                for req in requirements:
                    logger.info(f"Installing {req}...")
                    subprocess.check_call([
                        sys.executable, "-m", "pip", "install", "--user", req
                    ])
                
                # Verify installation
                import importlib
                importlib.invalidate_caches()
                
                # Try imports again
                import pdf2image
                from PIL import Image
                logger.info("Successfully installed and imported required modules.")
                return True
            except Exception as install_error:
                logger.error(f"Failed to install dependencies: {str(install_error)}")
                print(json.dumps({
                    "status": "error",
                    "message": f"Failed to install required Python modules: {str(install_error)}"
                }))
                sys.exit(1)
    except Exception as e:
        logger.error(f"Error checking dependencies: {str(e)}")
        logger.error(traceback.format_exc())
        print(json.dumps({
            "status": "error",
            "message": f"Error checking dependencies: {str(e)}"
        }))
        sys.exit(1)

# Check for system dependencies
def check_system_dependencies():
    """Check if required system dependencies are installed."""
    try:
        # Check for poppler-utils (needed by pdf2image)
        try:
            result = subprocess.run(['pdftoppm', '-v'], 
                                   stdout=subprocess.PIPE, 
                                   stderr=subprocess.PIPE,
                                   text=True)
            logger.info(f"Poppler utilities found: {result.stderr.strip() if result.stderr else 'Unknown version'}")
            return True
        except (FileNotFoundError, subprocess.SubprocessError):
            logger.error("Poppler utilities (poppler-utils) are not installed.")
            logger.error("This is required by pdf2image for PDF conversion.")
            logger.error("Please install poppler-utils:")
            logger.error("  - On Debian/Ubuntu: sudo apt-get install poppler-utils")
            logger.error("  - On RHEL/CentOS: sudo yum install poppler-utils")
            logger.error("  - On macOS: brew install poppler")
            
            print(json.dumps({
                "status": "error",
                "message": "Missing system dependency: poppler-utils. This must be installed by a system administrator."
            }))
            sys.exit(1)
    except Exception as e:
        logger.error(f"Error checking system dependencies: {str(e)}")
        print(json.dumps({
            "status": "error",
            "message": f"Error checking system dependencies: {str(e)}"
        }))
        sys.exit(1)

# Run the dependency checks before proceeding
ensure_dependencies()
check_system_dependencies()

# Function to check if poppler-utils is installed
def is_poppler_installed():
    try:
        # Try to run pdftoppm -v to check if poppler-utils is installed
        result = subprocess.run(['pdftoppm', '-v'], 
                               stdout=subprocess.PIPE, 
                               stderr=subprocess.PIPE, 
                               text=True)
        return True
    except (FileNotFoundError, subprocess.SubprocessError):
        return False

# Function to check and install dependencies
def ensure_dependencies():
    try:
        # Check for poppler-utils first
        if not is_poppler_installed():
            error_msg = (
                "The 'poppler-utils' package is required but not installed.\n"
                "This is a system dependency that needs to be installed separately.\n"
                "Please install it using your system's package manager:\n"
                "  - Ubuntu/Debian: sudo apt-get install poppler-utils\n"
                "  - CentOS/RHEL: sudo yum install poppler-utils\n"
                "  - macOS: brew install poppler\n"
            )
            logger.error(error_msg)
            return False
            
        # Try to import required modules
        try:
            import pdf2image
            from PIL import Image
            logger.info("All required Python modules are already installed.")
            return True
        except ImportError as e:
            missing_module = str(e).split("'")[1]
            logger.warning(f"Missing Python module: {missing_module}")
            
            # Automatically install missing dependencies
            logger.info("Attempting to install missing dependencies...")
            
            # Check if pip is available
            try:
                subprocess.check_call([sys.executable, "-m", "pip", "--version"], 
                                     stdout=subprocess.DEVNULL, 
                                     stderr=subprocess.DEVNULL)
            except subprocess.CalledProcessError:
                logger.error("pip is not available. Cannot install dependencies.")
                return False
                
            # Install dependencies
            requirements = ["pdf2image", "Pillow"]
            try:
                logger.info(f"Installing Python packages: {', '.join(requirements)}")
                subprocess.check_call([
                    sys.executable, "-m", "pip", "install", 
                    "--user", # Install for current user only
                    *requirements
                ])
                logger.info("Dependencies installed successfully.")
                
                # Now try to import the modules again
                import pdf2image
                from PIL import Image
                
                # Verify it works by checking pdf2image version
                logger.info(f"pdf2image version: {pdf2image.__version__}")
                return True
            except subprocess.CalledProcessError as e:
                logger.error(f"Failed to install dependencies: {str(e)}")
                return False
    except Exception as e:
        logger.error(f"Error in dependency management: {str(e)}")
        logger.error(traceback.format_exc())
        return False

# Ensure dependencies are installed before proceeding
if not ensure_dependencies():
    logger.error("Cannot proceed without required dependencies.")
    print(json.dumps({
        "status": "error",
        "message": "Missing required Python dependencies. Check logs for details."
    }))
    sys.exit(1)

# Import modules after ensuring they're installed
from pdf2image import convert_from_path
from PIL import Image

# Setup logging
# Add file handler to write to application.log
log_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'logs'))
if not os.path.exists(log_dir):
    os.makedirs(log_dir)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(os.path.join(log_dir, 'application.log'))
    ]
)
logger = logging.getLogger('pdf_converter')

def parse_arguments():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(description='Convert PDF presentations to web-viewable format')
    parser.add_argument('pdf_path', help='Path to the PDF file')
    parser.add_argument('--output-dir', '-o', help='Output directory (default: same as PDF)')
    parser.add_argument('--base-name', '-b', help='Base name for output files (default: PDF filename)')
    parser.add_argument('--format', '-f', choices=['jpg', 'png'], default='jpg', 
                      help='Image format (default: jpg)')
    parser.add_argument('--quality', '-q', type=int, default=85, 
                      help='Image quality 1-100 (default: 85)')
    parser.add_argument('--dpi', '-d', type=int, default=200, 
                      help='DPI for rendering (default: 200)')
    parser.add_argument('--width', '-w', type=int, 
                      help='Width to resize images (default: no resize)')
    return parser.parse_args()

def create_slideshow_html(output_dir, base_name, num_pages, img_format, title=None):
    """Create HTML file for the slideshow."""
    if not title:
        title = f"{base_name.replace('_', ' ').title()} Presentation"
    
    html_path = os.path.join(output_dir, f"{base_name}.html")
    
    html_content = f"""<!DOCTYPE html>
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
"""
    
    # Add slides
    for i in range(1, num_pages + 1):
        html_content += f"""
        <div class="slide" data-slide="{i}">
            <img src="{base_name}_slide_{i}.{img_format}" alt="Slide {i}">
            <div class="slide-number">{i} / {num_pages}</div>
        </div>
"""
    
    # Add thumbnails
    html_content += """
        <div class="thumbnails">
"""
    for i in range(1, num_pages + 1):
        html_content += f"""
            <div class="thumbnail" onclick="showSlide({i})" style="background-image: url('{base_name}_slide_{i}.{img_format}')"></div>
"""
    
    html_content += """
        </div>
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
"""
    
    with open(html_path, 'w', encoding='utf-8') as f:
        f.write(html_content)
    
    logger.info(f"Created HTML slideshow at {html_path}")
    return html_path

def create_metadata_json(output_dir, base_name, num_pages, img_format, title=None):
    """Create a metadata JSON file with presentation information."""
    if not title:
        title = f"{base_name.replace('_', ' ').title()} Presentation"
        
    metadata = {
        "title": title,
        "slides_count": num_pages,
        "image_format": img_format,
        "base_name": base_name,
        "html_file": f"{base_name}.html",
        "slide_images": [f"{base_name}_slide_{i}.{img_format}" for i in range(1, num_pages + 1)]
    }
    
    json_path = os.path.join(output_dir, f"{base_name}_metadata.json")
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(metadata, f, indent=2)
    
    logger.info(f"Created metadata JSON at {json_path}")
    return json_path

def convert_pdf_to_images(pdf_path, output_dir, base_name, img_format='jpg', quality=85, dpi=200, width=None):
    """Convert PDF pages to images."""
    try:
        # Create output directory if it doesn't exist
        os.makedirs(output_dir, exist_ok=True)
        
        logger.info(f"Converting PDF: {pdf_path}")
        logger.info(f"Output directory: {output_dir}")
        
        # Verify PDF file exists and is accessible
        if not os.path.exists(pdf_path):
            error_msg = f"PDF file not found: {pdf_path}"
            logger.error(error_msg)
            return {
                "status": "error",
                "message": error_msg
            }
            
        if not os.path.isfile(pdf_path):
            error_msg = f"Not a valid file: {pdf_path}"
            logger.error(error_msg)
            return {
                "status": "error",
                "message": error_msg
            }
            
        # Check file permissions
        if not os.access(pdf_path, os.R_OK):
            error_msg = f"No read permission for file: {pdf_path}"
            logger.error(error_msg)
            return {
                "status": "error",
                "message": error_msg
            }
        
        # Check if output directory is writable
        if not os.access(os.path.dirname(output_dir), os.W_OK):
            error_msg = f"No write permission for output directory: {output_dir}"
            logger.error(error_msg)
            return {
                "status": "error",
                "message": error_msg
            }
        
        # Log file details
        file_size = os.path.getsize(pdf_path) / (1024 * 1024)  # Size in MB
        logger.info(f"PDF file size: {file_size:.2f} MB")
        
        try:
            # Convert PDF to images
            logger.info(f"Starting PDF conversion with pdf2image (dpi={dpi}, format={img_format})")
            images = convert_from_path(
                pdf_path, 
                dpi=dpi,
                fmt=img_format,
                output_folder=tempfile.gettempdir(),
                thread_count=4
            )
            
            logger.info(f"Successfully converted {len(images)} pages")
        except Exception as pdf_error:
            # Detailed error logging for PDF conversion failure
            error_msg = f"PDF conversion error: {str(pdf_error)}"
            logger.error(error_msg)
            logger.error(f"Error details: {traceback.format_exc()}")
            
            # Check for common issues
            if "poppler" in str(pdf_error).lower():
                error_msg = "Poppler utilities missing. System administrator should install poppler-utils package."
                logger.error(error_msg)
            elif "not a PDF file" in str(pdf_error).lower():
                error_msg = f"The file is not a valid PDF: {pdf_path}"
                logger.error(error_msg)
            elif "encrypted" in str(pdf_error).lower():
                error_msg = "The PDF file is encrypted and cannot be processed"
                logger.error(error_msg)
            
            return {
                "status": "error",
                "message": error_msg
            }
        
        # Save each image
        for i, image in enumerate(images):
            try:
                # Resize if width is specified
                if width and image.width > width:
                    # Calculate height to maintain aspect ratio
                    height = int(image.height * (width / image.width))
                    image = image.resize((width, height), Image.LANCZOS)
                
                # Save the image
                img_path = os.path.join(output_dir, f"{base_name}_slide_{i+1}.{img_format}")
                image.save(img_path, quality=quality, optimize=True)
                logger.info(f"Saved slide {i+1} to {img_path}")
            except Exception as img_error:
                error_msg = f"Error saving slide {i+1}: {str(img_error)}"
                logger.error(error_msg)
                logger.error(f"Image save error details: {traceback.format_exc()}")
                return {
                    "status": "error",
                    "message": error_msg
                }
        
        try:
            # Create HTML slideshow
            html_path = create_slideshow_html(output_dir, base_name, len(images), img_format)
            
            # Create metadata JSON
            json_path = create_metadata_json(output_dir, base_name, len(images), img_format)
        except Exception as file_error:
            error_msg = f"Error creating output files: {str(file_error)}"
            logger.error(error_msg)
            logger.error(f"File creation error details: {traceback.format_exc()}")
            return {
                "status": "error",
                "message": error_msg
            }
        
        logger.info(f"PDF conversion completed successfully: {pdf_path}")
        return {
            "status": "success",
            "message": f"Successfully converted {len(images)} pages",
            "html_file": html_path,
            "metadata_file": json_path,
            "slide_count": len(images)
        }
    
    except Exception as e:
        # Catch-all for any unexpected errors
        error_msg = f"Error converting PDF: {str(e)}"
        logger.error(error_msg)
        logger.error(f"Exception details: {traceback.format_exc()}")
        return {
            "status": "error",
            "message": error_msg
        }

def check_dependencies_and_print_versions():
    """Check and report on all dependencies and their versions."""
    import platform
    
    # System information
    logger.info(f"System: {platform.system()} {platform.release()}")
    logger.info(f"Python version: {sys.version.split()[0]}")
    logger.info(f"Executable: {sys.executable}")
    
    # Check Python modules
    dependencies_ok = True
    
    # Check PIL/Pillow
    try:
        import PIL
        logger.info(f"PIL/Pillow version: {PIL.__version__}")
    except ImportError:
        logger.error("PIL/Pillow module is not installed")
        dependencies_ok = False
    except Exception as e:
        logger.error(f"Error checking PIL/Pillow: {str(e)}")
        dependencies_ok = False
    
    # Check pdf2image
    try:
        import pdf2image
        logger.info(f"pdf2image version: {pdf2image.__version__}")
    except ImportError:
        logger.error("pdf2image module is not installed")
        dependencies_ok = False
    except Exception as e:
        logger.error(f"Error checking pdf2image: {str(e)}")
        dependencies_ok = False
    
    # Check poppler-utils
    try:
        result = subprocess.run(['pdftoppm', '-v'], 
                              stdout=subprocess.PIPE, 
                              stderr=subprocess.PIPE, 
                              text=True)
        # Output is usually on stderr for version info
        version_info = result.stderr or result.stdout
        logger.info(f"Poppler utilities: {version_info.strip()}")
    except FileNotFoundError:
        logger.error("poppler-utils is not installed (pdftoppm command not found)")
        dependencies_ok = False
    except Exception as e:
        logger.error(f"Error checking poppler-utils: {str(e)}")
        dependencies_ok = False
    
    return dependencies_ok

def main():
    """Main function."""
    try:
        # Parse command line arguments
        args = parse_arguments()
        
        pdf_path = args.pdf_path
        logger.info(f"Starting PDF conversion process for: {pdf_path}")
        
        # Check if the PDF file exists
        if not os.path.isfile(pdf_path):
            error_msg = f"PDF file not found: {pdf_path}"
            logger.error(error_msg)
            print(json.dumps({"status": "error", "message": error_msg}))
            return 1
        
        # Determine output directory
        output_dir = args.output_dir
        if not output_dir:
            output_dir = os.path.dirname(os.path.abspath(pdf_path))
        
        # Determine base name
        base_name = args.base_name
        if not base_name:
            base_name = os.path.splitext(os.path.basename(pdf_path))[0]
            # Clean up the base name to use as a file prefix
            base_name = re.sub(r'[^\w\-_]', '_', base_name)
        
        # Log file information
        file_size_mb = os.path.getsize(pdf_path) / (1024 * 1024)
        logger.info(f"PDF file: {pdf_path} (Size: {file_size_mb:.2f} MB)")
        logger.info(f"Output directory: {output_dir}")
        logger.info(f"Base name: {base_name}")
        logger.info(f"Format: {args.format}, Quality: {args.quality}, DPI: {args.dpi}")
        
        # Log system information
        logger.info(f"Python version: {sys.version.split()[0]}")
        logger.info(f"Python executable: {sys.executable}")
        
        # Import required modules again to ensure they're available
        try:
            import pdf2image
            from PIL import Image
            logger.info(f"Using pdf2image version: {pdf2image.__version__}")
            logger.info(f"Using PIL/Pillow version: {Image.__version__}")
        except (ImportError, AttributeError) as e:
            error_msg = f"Failed to import required modules: {str(e)}"
            logger.error(error_msg)
            print(json.dumps({"status": "error", "message": error_msg}))
            return 1
        
        # Perform the conversion
        result = convert_pdf_to_images(
            pdf_path, 
            output_dir, 
            base_name, 
            img_format=args.format,
            quality=args.quality,
            dpi=args.dpi,
            width=args.width
        )
        
        # Output the result as JSON for the Perl code to parse
        print(json.dumps(result))
        
        if result["status"] == "success":
            logger.info(result["message"])
            logger.info(f"HTML file: {result['html_file']}")
            logger.info(f"Metadata file: {result['metadata_file']}")
            return 0
        else:
            logger.error(f"Conversion failed: {result['message']}")
            return 1
            
    except Exception as e:
        # Catch any unexpected exceptions in the main function
        error_msg = f"Unexpected error in PDF converter: {str(e)}"
        logger.error(error_msg)
        logger.error(f"Full exception details: {traceback.format_exc()}")
        
        # Output JSON error for the Perl code to parse
        print(json.dumps({"status": "error", "message": error_msg}))
        return 1

if __name__ == "__main__":
    sys.exit(main())
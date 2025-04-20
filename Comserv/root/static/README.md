# Comserv Static Assets

This directory contains all static assets used by the Comserv application, including CSS, JavaScript, images, and fonts.

## No External Dependencies

All assets are hosted locally to ensure:

1. **Security**: No external scripts that could introduce vulnerabilities
2. **Offline Access**: The application works without internet access
3. **Performance**: No reliance on external CDNs that could slow down the application
4. **Privacy**: No third-party tracking or data collection

## Directory Structure

- **css/**: Contains all CSS files
  - **base.css**: Base styles and CSS variables
  - **themes/**: Theme-specific CSS files
  - **simple-icons.css**: Icon system using SVG data URLs
  - **icon-fix.css**: Fixes for icon styling to respect theme colors

- **js/**: Contains all JavaScript files
  - **sub-menu.js**: Menu functionality using vanilla JavaScript
  - **menu.js**: Additional menu functionality
  - **local-chat.js**: Local chat implementation (replaces external chat service)

- **fonts/**: Contains font files (if needed)

- **images/**: Contains image assets

## Icon System

Instead of using external icon libraries like Font Awesome, we use a custom icon system with SVG data URLs embedded directly in CSS. This approach:

- Eliminates the need for external font files
- Works offline
- Respects theme colors
- Reduces HTTP requests

## JavaScript

All JavaScript is written in vanilla JS with no external dependencies. This ensures:

- No reliance on external libraries like jQuery
- Better performance
- Offline functionality
- Improved security

## Maintenance

When adding new features:

1. Always add new assets to this directory rather than linking to external resources
2. Use vanilla JavaScript instead of external libraries
3. Document any new additions in this README
4. Update the version numbers in the files

## Last Updated

June 2, 2024
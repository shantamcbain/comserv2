# Back to Top Feature

**Last Updated:** August 20, 2024  
**Author:** Shanta  
**Status:** Active

## Overview

The "Back to Top" feature adds a floating button to all pages in the application that allows users to quickly scroll back to the top of the page. This is especially useful for long pages with a lot of content.

## Implementation

The feature is implemented using HTML, CSS, and JavaScript:

1. **HTML**: A button element with the ID `back-to-top` is added to the main wrapper template.
2. **CSS**: Styles for the button are defined in `/static/css/back-to-top.css`.
3. **JavaScript**: Functionality for the button is implemented in `/static/js/back-to-top.js`.

## Features

- **Responsive Design**: The button adapts to different screen sizes.
- **Smooth Scrolling**: The page scrolls smoothly to the top when the button is clicked.
- **Automatic Show/Hide**: The button only appears when the user has scrolled down the page.
- **Theme Integration**: The button's appearance adapts to the current site theme.
- **Accessibility**: The button includes ARIA attributes for screen readers and keyboard navigation support.

## Code Details

### HTML

```html
<!-- Back to Top Button -->
<button id="back-to-top" title="Back to Top" aria-label="Back to Top">
    <i class="fas fa-arrow-up" aria-hidden="true"></i>
</button>
```

### CSS

The CSS for the button is defined in `/static/css/back-to-top.css`. Key styles include:

- Fixed positioning in the bottom-right corner of the viewport
- Circular shape with a background color that matches the site theme
- Hover effects for better user interaction
- Responsive adjustments for mobile devices

### JavaScript

The JavaScript functionality is defined in `/static/js/back-to-top.js`. Key features include:

- Show the button when the user scrolls down more than 300 pixels
- Hide the button when the user is near the top of the page
- Smooth scrolling animation when the button is clicked
- Keyboard shortcut (Alt + Home) for accessibility

## Keyboard Shortcuts

- **Alt + Home**: Scroll to the top of the page

## Browser Compatibility

The "Back to Top" feature is compatible with all modern browsers:

- Chrome 60+
- Firefox 60+
- Safari 12+
- Edge 16+
- Opera 50+

## Customization

The appearance of the button can be customized by modifying the CSS file. The following aspects can be changed:

- Button size
- Button position
- Button colors
- Animation speed
- Scroll threshold

## Accessibility

The "Back to Top" button includes the following accessibility features:

- ARIA label for screen readers
- Keyboard navigation support
- High contrast colors
- Adequate button size for touch targets

## Integration with Themes

The button's appearance automatically adapts to the current site theme:

- **Default Theme**: Blue button
- **CSC Theme**: Green button
- **APIS Theme**: Red button
- **USBM Theme**: Purple button

## Troubleshooting

If the "Back to Top" button is not appearing or functioning correctly:

1. Check if jQuery is loaded before the back-to-top.js script
2. Verify that the CSS file is correctly linked in the head section
3. Check the browser console for any JavaScript errors
4. Ensure that the button HTML is present in the page source

## Future Enhancements

Potential future enhancements for the "Back to Top" feature:

1. Add animation to the button icon
2. Add a progress indicator showing scroll position
3. Allow users to customize the button position in their profile settings
4. Add analytics to track button usage
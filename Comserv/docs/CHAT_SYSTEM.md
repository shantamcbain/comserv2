# Chat System Documentation

## Overview

The Comserv Chat System provides a real-time communication channel between users and administrators. It allows users to send messages to administrators, who can then respond through an admin interface.

## Features

- Theme-integrated chat widget on all pages
- Persistent message storage in the database
- Admin interface for responding to user messages
- Notification system for new messages
- Mobile-friendly design

## Technical Implementation

The chat system consists of the following components:

1. **Frontend Widget**: A JavaScript-based chat widget that appears on all pages
2. **Backend API**: Perl-based API endpoints for sending and receiving messages
3. **Database Storage**: SQLite table for storing chat messages
4. **Admin Interface**: Web interface for administrators to view and respond to messages

## Theme Integration

The chat widget is designed to integrate with the existing theme system:

- Uses CSS variables from the theme system (`--primary-color`, `--text-on-primary`, etc.)
- Adapts to different themes automatically
- Maintains consistent styling across different domains

## Installation

### 1. Create the Database Table

Run the provided script to create the necessary database table:

```bash
cd /path/to/comserv
perl Comserv/script/create_chat_table.pl
```

### 2. Verify Installation

- Visit any page on the site and check that the chat widget appears in the bottom-right corner
- Send a test message through the chat widget
- Log in as an administrator and visit `/chat/admin` to see the admin interface

## Usage

### For Users

1. Click on the chat button in the bottom-right corner of any page
2. Type your message in the text box
3. Press Enter or click Send
4. Wait for an administrator to respond

### For Administrators

1. Log in with an administrator account
2. Navigate to `/chat/admin`
3. View all messages from users
4. Click "Respond" next to a message to reply
5. Type your response and click "Send Response"

## API Endpoints

The chat system provides the following API endpoints:

- `/chat/send_message` - POST endpoint for sending a message
- `/chat/get_messages` - GET endpoint for retrieving messages
- `/chat/respond` - POST endpoint for admin responses

## Multi-Domain Support

The chat system works across all domains hosted by the application:

- Messages are associated with the domain they were sent from
- Administrators can see which domain a message came from
- Responses are routed back to the appropriate domain

## Customization

### Styling

The chat widget styling can be customized by modifying the CSS in:
- `/static/js/local-chat.js` (inline CSS)

The widget already uses theme variables, so it will automatically adapt to your theme changes.

### Behavior

To modify the behavior of the chat widget, edit:
- `/static/js/local-chat.js`

### Backend Logic

To modify the backend logic, edit:
- `/lib/Comserv/Controller/Chat.pm`

## Troubleshooting

### Common Issues

1. **Chat widget doesn't appear**
   - Check that `local-chat.js` is being loaded in the footer
   - Check browser console for JavaScript errors

2. **Messages not sending**
   - Verify the database table was created correctly
   - Check application logs for API errors

3. **Admin interface not showing messages**
   - Verify you're logged in with an admin account
   - Check that the database contains messages

### Logs

Check the application logs for errors:
```
tail -f Comserv/logs/application.log
```

## Future Enhancements

Potential future enhancements for the chat system:

1. Real-time WebSocket communication
2. File attachment support
3. User typing indicators
4. Chat history for returning users
5. Integration with email notification system
# AI Chat System Documentation

## Overview

The Comserv AI Chat System provides an intelligent chat interface powered by AI. Users can ask questions and receive instant responses from an AI assistant, providing immediate help and support without waiting for human administrators.

## Features

- Theme-integrated AI chat widget on all pages
- Real-time AI responses powered by Ollama LLM
- No waiting time - instant responses
- Mobile-friendly responsive design
- Seamless integration with existing theme system

## Technical Implementation

The AI chat system consists of the following components:

1. **Frontend Widget**: A JavaScript-based AI chat widget that appears on all pages
2. **Backend API**: AI Controller endpoints (`/ai/generate`) for processing AI queries
3. **AI Engine**: Ollama LLM integration for generating intelligent responses
4. **Real-time Interface**: Instant query processing without polling or delays

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

1. Click on the "Chat with AI" button (🤖) in the bottom-right corner of any page
2. Type your question or message in the text box
3. Press Enter or click Send
4. Receive an instant AI-generated response
5. Continue the conversation as needed

### For Administrators

The AI chat system operates autonomously and doesn't require administrator intervention. However, administrators can:
- Monitor system performance through logs
- Manage AI models and configuration through `/ai/models`
- Access the full AI interface at `/ai/` for advanced interactions

## API Endpoints

The AI chat system uses the following API endpoints:

- `/ai/generate` - POST endpoint for sending queries to AI and receiving responses
- `/ai/` - Main AI interface page
- `/ai/models` - AI model management interface

## Multi-Domain Support

The AI chat system works seamlessly across all domains hosted by the application:

- AI responses are consistent across all domains
- Theme integration adapts to each domain's styling automatically
- No domain-specific configuration required

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
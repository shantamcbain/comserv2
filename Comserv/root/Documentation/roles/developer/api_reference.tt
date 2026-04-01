# API Reference

This comprehensive API reference is intended for developers working with the Comserv platform.

## API Overview

The Comserv API provides programmatic access to system functionality, allowing developers to:

- Retrieve and manipulate data
- Integrate with external systems
- Extend platform functionality
- Automate workflows
- Build custom interfaces

## Authentication

### Obtaining API Credentials

1. Navigate to Admin > Developer > API Credentials
2. Click "Generate New API Key"
3. Name your application and select appropriate scopes
4. Store the generated client_id and client_secret securely

### Authentication Methods

The API supports two authentication methods:

#### OAuth 2.0 (Recommended)

```
POST /api/v1/oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials&
client_id=YOUR_CLIENT_ID&
client_secret=YOUR_CLIENT_SECRET
```

Response:
```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "scope": "read write"
}
```

Use the access token in subsequent requests:
```
GET /api/v1/users
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

#### API Key (Simple)

Include your API key in the request header:
```
GET /api/v1/users
X-API-Key: YOUR_API_KEY
```

## Core Endpoints

### Users

#### List Users

```
GET /api/v1/users
```

Query parameters:
- `page`: Page number (default: 1)
- `limit`: Results per page (default: 20, max: 100)
- `role`: Filter by role (optional)
- `status`: Filter by status (optional)

Response:
```json
{
  "data": [
    {
      "id": 1,
      "username": "johndoe",
      "email": "john@example.com",
      "role": "editor",
      "status": "active",
      "created_at": "2023-01-15T08:30:00Z",
      "last_login": "2023-05-20T14:22:10Z"
    },
    ...
  ],
  "meta": {
    "current_page": 1,
    "total_pages": 5,
    "total_count": 98
  }
}
```

#### Get User

```
GET /api/v1/users/{id}
```

Response:
```json
{
  "id": 1,
  "username": "johndoe",
  "email": "john@example.com",
  "role": "editor",
  "status": "active",
  "created_at": "2023-01-15T08:30:00Z",
  "last_login": "2023-05-20T14:22:10Z",
  "profile": {
    "first_name": "John",
    "last_name": "Doe",
    "phone": "+1234567890",
    "bio": "System editor and content manager"
  }
}
```

#### Create User

```
POST /api/v1/users
Content-Type: application/json

{
  "username": "newuser",
  "email": "newuser@example.com",
  "password": "securepassword",
  "role": "normal",
  "profile": {
    "first_name": "New",
    "last_name": "User"
  }
}
```

Response:
```json
{
  "id": 99,
  "username": "newuser",
  "email": "newuser@example.com",
  "role": "normal",
  "status": "active",
  "created_at": "2023-05-21T10:15:30Z"
}
```

### Documents

#### List Documents

```
GET /api/v1/documents
```

Query parameters:
- `page`: Page number (default: 1)
- `limit`: Results per page (default: 20, max: 100)
- `category`: Filter by category (optional)
- `status`: Filter by status (optional)

Response:
```json
{
  "data": [
    {
      "id": 1,
      "title": "Annual Report 2023",
      "category": "reports",
      "status": "published",
      "created_at": "2023-03-15T08:30:00Z",
      "updated_at": "2023-03-16T14:22:10Z",
      "author_id": 5
    },
    ...
  ],
  "meta": {
    "current_page": 1,
    "total_pages": 8,
    "total_count": 156
  }
}
```

## Error Handling

The API uses standard HTTP status codes and returns detailed error information:

```json
{
  "error": {
    "code": "invalid_request",
    "message": "The request is missing a required parameter",
    "details": "The 'email' field is required"
  }
}
```

Common error codes:
- `invalid_request`: Missing or invalid parameters
- `authentication_failed`: Invalid credentials
- `permission_denied`: Insufficient permissions
- `resource_not_found`: Requested resource doesn't exist
- `rate_limit_exceeded`: Too many requests

## Rate Limiting

API requests are subject to rate limiting:
- 100 requests per minute for standard API keys
- 300 requests per minute for premium API keys

Rate limit headers are included in all responses:
```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 95
X-RateLimit-Reset: 1621612345
```

## Webhooks

### Configuring Webhooks

1. Go to Admin > Developer > Webhooks
2. Click "Add Webhook"
3. Enter the destination URL
4. Select events to subscribe to
5. Set a secret key for signature verification

### Event Types

- `user.created`: New user registration
- `user.updated`: User profile update
- `document.created`: New document created
- `document.updated`: Document updated
- `document.published`: Document published

### Webhook Payload

```json
{
  "event": "document.published",
  "timestamp": "2023-05-21T15:32:10Z",
  "data": {
    "id": 42,
    "title": "New Policy Document",
    "category": "policies",
    "status": "published",
    "author_id": 5
  }
}
```

### Signature Verification

Each webhook includes an `X-Webhook-Signature` header containing an HMAC-SHA256 signature. Verify this signature using your webhook secret to ensure the request is authentic.

## SDKs and Libraries

Official client libraries:
- [JavaScript SDK](https://github.com/comserv/comserv-js)
- [Python SDK](https://github.com/comserv/comserv-python)
- [PHP SDK](https://github.com/comserv/comserv-php)

## API Versioning

The API uses versioning in the URL path (e.g., `/api/v1/`). When breaking changes are introduced, a new version will be released. We maintain backward compatibility for at least 12 months after a new version is released.

## Support and Feedback

For API support:
- Check the developer forums
- Submit issues on GitHub
- Contact api-support@comserv.example.com

We welcome feedback and feature requests for the API.
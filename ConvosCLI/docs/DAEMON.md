# Convos CLI Daemon

The daemon mode provides an HTTP server with JSON-RPC 2.0 and Server-Sent Events (SSE) endpoints for programmatic access to Convos messaging. This is designed for integration with bots, automation tools, and other services.

## Starting the Daemon

```bash
# Start with default settings (127.0.0.1:8080)
convos daemon

# Specify port and host
convos daemon --http-port 3000 --host 0.0.0.0

# With environment and data directory
convos daemon --environment production --data-dir ~/.convos
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--http-port` | 8080 | HTTP port to listen on |
| `--host` | 127.0.0.1 | Host to bind to |
| `--environment` | dev | Convos environment (dev/production) |
| `--data-dir` | Platform default | Custom data directory path |

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/jsonrpc` | POST | JSON-RPC 2.0 endpoint for commands |
| `/events` | GET | SSE stream for real-time messages |
| `/health` | GET | Health check endpoint |

---

## JSON-RPC API

All requests use [JSON-RPC 2.0](https://www.jsonrpc.org/specification) format:

```json
{
  "jsonrpc": "2.0",
  "method": "method.name",
  "params": { ... },
  "id": 1
}
```

### Available Methods

#### `conversations.list`

List all conversations.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `limit` | integer | No | Maximum conversations to return |
| `includeHidden` | boolean | No | Include blocked/hidden conversations (default: false) |

**Example:**
```bash
curl -X POST http://localhost:8080/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "conversations.list",
    "params": {"limit": 10},
    "id": 1
  }'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": [
    {
      "id": "conv_abc123",
      "displayName": "Team Chat",
      "memberCount": 5,
      "isUnread": true,
      "isPinned": false,
      "isMuted": false,
      "kind": "group",
      "createdAt": "2024-01-15T10:30:00Z",
      "lastMessagePreview": "Hello everyone!"
    }
  ],
  "id": 1
}
```

---

#### `conversations.create`

Create a new conversation and get an invite slug.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `name` | string | No | Optional conversation name |

**Example:**
```bash
curl -X POST http://localhost:8080/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "conversations.create",
    "params": {"name": "Project Discussion"},
    "id": 1
  }'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "conversationId": "conv_xyz789",
    "inviteSlug": "abc123def456"
  },
  "id": 1
}
```

---

#### `conversations.join`

Join a conversation using an invite slug or URL.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `invite` | string | Yes | Invite slug or full invite URL |
| `noWait` | boolean | No | Return immediately without waiting for acceptance (default: false) |

**Example:**
```bash
curl -X POST http://localhost:8080/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "conversations.join",
    "params": {"invite": "https://convos.app/v2?i=abc123def456"},
    "id": 1
  }'
```

**Response (with noWait: false):**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "status": "joined",
    "conversationId": "conv_xyz789"
  },
  "id": 1
}
```

**Response (with noWait: true):**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "status": "waiting_for_acceptance",
    "conversationId": null
  },
  "id": 1
}
```

---

#### `conversations.invite`

Generate an invite slug for an existing conversation.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `conversationId` | string | Yes | The conversation ID |

**Example:**
```bash
curl -X POST http://localhost:8080/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "conversations.invite",
    "params": {"conversationId": "conv_abc123"},
    "id": 1
  }'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "inviteSlug": "abc123def456"
  },
  "id": 1
}
```

---

#### `messages.list`

List messages in a conversation.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `conversationId` | string | Yes | The conversation ID |
| `limit` | integer | No | Maximum messages to return (default: 50) |

**Example:**
```bash
curl -X POST http://localhost:8080/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "messages.list",
    "params": {"conversationId": "conv_abc123", "limit": 20},
    "id": 1
  }'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": [
    {
      "id": "msg_001",
      "conversationId": "conv_abc123",
      "senderId": "user_xyz",
      "senderName": "Alice",
      "content": "Hello!",
      "timestamp": "2024-01-15T10:35:00Z"
    }
  ],
  "id": 1
}
```

---

#### `messages.send`

Send a message to a conversation.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `conversationId` | string | Yes | The conversation ID |
| `message` | string | Yes | Message text to send |

**Example:**
```bash
curl -X POST http://localhost:8080/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "messages.send",
    "params": {"conversationId": "conv_abc123", "message": "Hello from the bot!"},
    "id": 1
  }'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "success": true
  },
  "id": 1
}
```

---

#### `messages.react`

Add or remove a reaction to a message.

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|
| `conversationId` | string | Yes | The conversation ID |
| `messageId` | string | Yes | The message ID to react to |
| `emoji` | string | Yes | Emoji reaction (e.g., "👍") |
| `remove` | boolean | No | Remove reaction instead of adding (default: false) |

**Example:**
```bash
curl -X POST http://localhost:8080/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "messages.react",
    "params": {"conversationId": "conv_abc123", "messageId": "msg_001", "emoji": "👍"},
    "id": 1
  }'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "success": true,
    "action": "added"
  },
  "id": 1
}
```

---

#### `account.info`

Get account information.

**Parameters:** None

**Example:**
```bash
curl -X POST http://localhost:8080/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "account.info",
    "id": 1
  }'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "conversationCount": 5,
    "environment": "dev"
  },
  "id": 1
}
```

---

## Error Responses

Errors follow JSON-RPC 2.0 error format:

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32602,
    "message": "Invalid params: conversationId is required"
  },
  "id": 1
}
```

### Error Codes

| Code | Name | Description |
|------|------|-------------|
| -32700 | Parse error | Invalid JSON |
| -32600 | Invalid Request | Invalid JSON-RPC request |
| -32601 | Method not found | Unknown method |
| -32602 | Invalid params | Invalid or missing parameters |
| -32603 | Internal error | Server error |

---

## Server-Sent Events (SSE)

Connect to `/events` to receive real-time message updates.

```bash
curl -N http://localhost:8080/events
```

### Event Types

#### `connected`
Sent when connection is established.

```
event: connected
data: {"status":"ok"}
```

#### `message`
New message received.

```
event: message
id: 1
data: {"channel":"convos","conversationId":"conv_abc123","messageId":"msg_001","from":"inbox_xyz","body":"Hello!","type":"text","timestamp":"2024-01-15T10:35:00Z"}
```

#### `reaction`
Reaction added or removed.

```
event: reaction
id: 2
data: {"channel":"convos","conversationId":"conv_abc123","messageId":"msg_001","from":"inbox_xyz","emoji":"👍","targetMessageId":"msg_000","action":"added","timestamp":"2024-01-15T10:36:00Z"}
```

#### `system`
System events (group updates, etc).

```
event: system
id: 3
data: {"channel":"convos","conversationId":"conv_abc123","messageId":"msg_002","type":"group_update","body":"[Group updated]","timestamp":"2024-01-15T10:37:00Z"}
```

#### `error`
Error event.

```
event: error
data: {"message":"Failed to initialize inbox"}
```

### Heartbeat

The server sends periodic heartbeats (every 30 seconds) to keep the connection alive:

```
: heartbeat
```

---

## Integration Examples

### Python Bot

```python
import requests
import sseclient

BASE_URL = "http://localhost:8080"

def send_message(conversation_id, message):
    response = requests.post(f"{BASE_URL}/jsonrpc", json={
        "jsonrpc": "2.0",
        "method": "messages.send",
        "params": {"conversationId": conversation_id, "message": message},
        "id": 1
    })
    return response.json()

def listen_for_messages():
    response = requests.get(f"{BASE_URL}/events", stream=True)
    client = sseclient.SSEClient(response)

    for event in client.events():
        if event.event == "message":
            data = json.loads(event.data)
            print(f"New message: {data['body']}")

            # Auto-reply example
            if "hello" in data['body'].lower():
                send_message(data['conversationId'], "Hello! I'm a bot.")
```

### Node.js Bot

```javascript
const EventSource = require('eventsource');

const BASE_URL = 'http://localhost:8080';

async function sendMessage(conversationId, message) {
  const response = await fetch(`${BASE_URL}/jsonrpc`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      method: 'messages.send',
      params: { conversationId, message },
      id: 1
    })
  });
  return response.json();
}

function listenForMessages() {
  const es = new EventSource(`${BASE_URL}/events`);

  es.addEventListener('message', (event) => {
    const data = JSON.parse(event.data);
    console.log(`New message: ${data.body}`);

    // Auto-reply example
    if (data.body.toLowerCase().includes('hello')) {
      sendMessage(data.conversationId, "Hello! I'm a bot.");
    }
  });

  es.addEventListener('error', (err) => {
    console.error('SSE error:', err);
  });
}

listenForMessages();
```

### Shell Script

```bash
#!/bin/bash

# Send a message
send_message() {
  curl -s -X POST http://localhost:8080/jsonrpc \
    -H "Content-Type: application/json" \
    -d "{
      \"jsonrpc\": \"2.0\",
      \"method\": \"messages.send\",
      \"params\": {\"conversationId\": \"$1\", \"message\": \"$2\"},
      \"id\": 1
    }"
}

# List conversations
list_conversations() {
  curl -s -X POST http://localhost:8080/jsonrpc \
    -H "Content-Type: application/json" \
    -d '{
      "jsonrpc": "2.0",
      "method": "conversations.list",
      "id": 1
    }' | jq '.result'
}

# Usage
list_conversations
send_message "conv_abc123" "Hello from shell!"
```

---

## OpenClaw Integration

This daemon is designed to work with [OpenClaw](https://github.com/openclaw/openclaw) as a "convos" channel. A complete channel plugin is provided in the `openclaw-channel/` directory.

### Quick Start

1. Start the Convos daemon:
   ```bash
   convos daemon --http-port 8080
   ```

2. Install the channel plugin:
   ```bash
   cp -r openclaw-channel/ ~/.openclaw/extensions/convos/
   ```

3. Add to your `~/.openclaw/openclaw.json`:
   ```json
   {
     "channels": {
       "convos": {
         "accounts": {
           "default": {
             "daemonUrl": "http://127.0.0.1:8080"
           }
         }
       }
     }
   }
   ```

4. Restart OpenClaw gateway

### Channel Capabilities

```typescript
{
  chatTypes: ["group"],  // Convos uses group-based model
  reactions: true,
  reply: true,
  media: true,      // XMTP supports, daemon pending
  edit: false,      // Not yet implemented
  unsend: false,    // Not yet implemented
  typing: false,    // Not supported by Convos
}
```

### Full Documentation

See [`openclaw-channel/README.md`](../openclaw-channel/README.md) for complete integration documentation including:
- Configuration options
- Privacy benefits over other channels
- Troubleshooting

---

## Health Check

```bash
curl http://localhost:8080/health
```

Response:
```json
{"status":"ok","version":"1.0.0"}
```

Use this endpoint for load balancer health checks or container orchestration.

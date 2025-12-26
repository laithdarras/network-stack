# Chat Client and Server

## Introduction

Build a simple text chat (client/server) on top of reliable transport. Server runs on node 1, port 41. Clients issue CRLF-terminated commands (hello, msg, whisper, listusr) and receive formatted replies.

## Architecture

- **ChatServer**: `ChatServerP.nc` / `ChatServerC.nc`
- **ChatClient**: `ChatClientP.nc` / `ChatClientC.nc`
- **Command handling**: New chat CommandHandler events to drive ChatClient

### Wiring

- `ChatServerC` wires `ChatServerP` to `Transport` and two timers (AcceptTimer, ReadTimer).
- `ChatClientC` wires `ChatClientP` to `Transport` and `ReadTimer`.
- `Node.nc` listens/forwards TCP traffic; chat server starts automatically on node 1; CommandHandler events forward to ChatClient.

## Application Protocol

All messages are ASCII lines ending with `\r\n`:

- `hello <username>`: register username (12-byte max)
- `msg <message>`: broadcast to all connected users
- `whisper <username> <message>`: unicast to a specific user
- `listusr`: reply with `listUsrRply user1,user2,...`

Server responses:

- `msgFrom <user> <message>`
- `whisperFrom <user> <message>`
- `listUsrRply user1,user2,...`

## Data Structures

### Server (`ChatServerP`)

- `serverSocket`: listening socket (port 41)
- `clients[MAX_CLIENTS=8]`:
  - `inUse`
  - `fd`
  - `addr`, `port`
  - `username[13]` (12 + null character)
  - `lineBuf[128]`, `lineLen` for partial line assembly
- `readBuf[64]`: temp per-read buffer

### Client (`ChatClientP`)

- `fd`: active socket or `NULL_SOCKET`
- `connected`: handshake + hello done
- `username[13]`
- `serverAddr` (addr=1, port=41)
- `readBuf[64]`, `lineBuf[128]`, `lineLen`

## ChatServer Behavior

- `start()`: socket(), bind(port 41), listen(); start AcceptTimer & ReadTimer periodic (200 ms).
- `AcceptTimer.fired`: accept all pending connections; allocate a client slot.
- `ReadTimer.fired`: for each active client, read into `readBuf`, append to `lineBuf`, extract lines on CR/LF, call `processLine`.
- `processLine`:
  - If no username yet: expect `hello <username>`, store username.
  - `msg`: broadcast `msgFrom <user> <message>` to all clients.
  - `whisper`: send `whisperFrom <sender> <message>` to target username.
  - `listusr`: reply with `listUsrRply user1,user2,...` to the requester.

## ChatClient Behavior

- `startHello(username, clientPort)`: socket(), bind(src=clientPort), connect(dest=1:41), send `hello <username>\r\n`, start ReadTimer, set connected=TRUE.
- `sendMsg(msg)`: send `msg <msg>\r\n` if connected.
- `sendWhisper(user, msg)`: send `whisper <user> <msg>\r\n` if connected.
- `sendListUsr()`: send `listusr\r\n` if connected.
- `ReadTimer.fired`: read bytes, assemble lines in `lineBuf`, on complete line call `processLine`.
- `processLine`: logs incoming lines
// Chat Server implementation

#include <string.h>
#include "../../includes/channels.h"
#include "../../includes/socket.h"
#include "../../includes/Transport.h"

module ChatServerP {
   provides interface ChatServer;
   uses interface Transport;
   uses interface Timer<TMilli> as AcceptTimer;
   uses interface Timer<TMilli> as ReadTimer;
}

implementation {
   enum {
      MAX_CLIENTS = 8,        // 8 concurrent chat clients
      USERNAME_MAX = 12,      // Username bytes
      USERNAME_BUF = USERNAME_MAX + 1,       // Username storage with null character
      LINE_BUF_SIZE = 128,                   // Per-client assembled line buffer (commands + payload + CRLF)
      READ_BUF_SIZE = 64,                    // Temporary read buffer per socket read
      CHAT_PORT = 41                         // TCP port
   };

   typedef struct {
      bool inUse;
      socket_t fd;
      uint16_t addr;
      uint16_t port;
      char username[USERNAME_BUF];
      char lineBuf[LINE_BUF_SIZE];
      uint8_t lineLen;
   } client_entry_t;

   socket_t serverSocket = NULL_SOCKET;
   client_entry_t clients[MAX_CLIENTS];
   uint8_t readBuf[READ_BUF_SIZE];

   // helper functions
   client_entry_t* allocClient(socket_t fd) {
      uint8_t i;
      for (i = 0; i < MAX_CLIENTS; i++) {
         if (!clients[i].inUse) {
            clients[i].inUse = TRUE;
            clients[i].fd = fd;
            clients[i].addr = 0;
            clients[i].port = 0;
            clients[i].username[0] = '\0';
            clients[i].lineBuf[0] = '\0';
            clients[i].lineLen = 0;
            return &clients[i];
         }
      }
      return NULL;
   }

   client_entry_t* findClientByUsername(char *username) {
      uint8_t i;
      for (i = 0; i < MAX_CLIENTS; i++) {
         if (clients[i].inUse && clients[i].username[0] != '\0' &&
             strncmp(clients[i].username, username, USERNAME_MAX) == 0) {
            return &clients[i];
         }
      }
      return NULL;
   }

   void sendToClient(socket_t fd, char *msg) {
      uint16_t len = strlen(msg);
      if (len == 0) {
         return;
      }
      call Transport.write(fd, (uint8_t *)msg, len);
   }

   uint16_t appendStr(char *dst, uint16_t idx, char *src, uint16_t maxLen) {
      uint16_t i = 0;
      while (src[i] != '\0' && idx + 1 < maxLen) {
         dst[idx++] = src[i++];
      }
      return idx;
   }

   uint16_t appendChar(char *dst, uint16_t idx, char ch, uint16_t maxLen) {
      if (idx + 1 < maxLen) {
         dst[idx++] = ch;
      }
      return idx;
   }

   void finalizeCrlf(char *buf, uint16_t idx, uint16_t maxLen) {
      if (idx + 2 < maxLen) {
         buf[idx++] = '\r';
         buf[idx++] = '\n';
      }
      buf[idx] = '\0';
   }

   void broadcast(char *sender, char *msg) {
      char outBuf[LINE_BUF_SIZE];
      uint16_t idx = 0;
      uint8_t i;

      idx = appendStr(outBuf, idx, "msgFrom ", sizeof(outBuf));
      idx = appendStr(outBuf, idx, sender, sizeof(outBuf));
      idx = appendChar(outBuf, idx, ' ', sizeof(outBuf));
      idx = appendStr(outBuf, idx, msg, sizeof(outBuf));
      finalizeCrlf(outBuf, idx, sizeof(outBuf));

      for (i = 0; i < MAX_CLIENTS; i++) {
         if (clients[i].inUse && clients[i].fd != NULL_SOCKET) {
            sendToClient(clients[i].fd, outBuf);
         }
      }
   }

   void whisperTo(char *target, char *sender, char *msg) {
      client_entry_t *dest = findClientByUsername(target);
      if (dest == NULL) {
         return;
      }
      {
         char outBuf[LINE_BUF_SIZE];
         uint16_t idx = 0;
         idx = appendStr(outBuf, idx, "whisperFrom ", sizeof(outBuf));
         idx = appendStr(outBuf, idx, sender, sizeof(outBuf));
         idx = appendChar(outBuf, idx, ' ', sizeof(outBuf));
         idx = appendStr(outBuf, idx, msg, sizeof(outBuf));
         finalizeCrlf(outBuf, idx, sizeof(outBuf));
         sendToClient(dest->fd, outBuf);
      }
   }

   void listUsers(client_entry_t *c) {
      char outBuf[LINE_BUF_SIZE];
      uint16_t idx = 0;
      uint8_t i;

      idx = appendStr(outBuf, idx, "listUsrRply ", sizeof(outBuf));

      for (i = 0; i < MAX_CLIENTS && idx + 1 < sizeof(outBuf); i++) {
         if (clients[i].inUse && clients[i].username[0] != '\0') {
            if (idx > 12) { // already appended at least one username
               idx = appendChar(outBuf, idx, ',', sizeof(outBuf));
            }
            idx = appendStr(outBuf, idx, clients[i].username, sizeof(outBuf));
         }
      }

      finalizeCrlf(outBuf, idx, sizeof(outBuf));
      dbg(PROJECT4_CHAT_CHANNEL, "ChatServer listUsrRply to %s: %s\n",
          (c->username[0] != '\0') ? c->username : "<nouser>", outBuf);
      sendToClient(c->fd, outBuf);
   }

   void processLine(client_entry_t *c, char *line) {
      if (c->username[0] == '\0') {
         if (strncmp(line, "hello ", 6) == 0) {
            char *u = line + 6;
            uint8_t i;
            for (i = 0; i < USERNAME_MAX && u[i] != '\0'; i++) {
               c->username[i] = u[i];
            }
            c->username[i] = '\0';
            dbg(PROJECT4_CHAT_CHANNEL, "ChatServer: user=%s joined\n", c->username);
         }
         return;
      }

      if (strncmp(line, "msg ", 4) == 0) {
         char *m = line + 4;
         broadcast(c->username, m);
         return;
      }

      if (strncmp(line, "whisper ", 8) == 0) {
         char *rest = line + 8;
         char target[USERNAME_BUF];
         char *space;
         uint8_t i;
         space = strchr(rest, ' ');
         if (space == NULL) {
            return;
         }
         {
            uint8_t len = space - rest;
            if (len > USERNAME_MAX) {
               len = USERNAME_MAX;
            }

            for (i = 0; i < len; i++) {
               target[i] = rest[i];
            }
            
            target[len] = '\0';
         }
         whisperTo(target, c->username, space + 1);
         return;
      }

      if (strncmp(line, "listusr", 7) == 0) {
         listUsers(c);
         return;
      }
   }

   void handleRead(client_entry_t *c) {
      uint16_t n = call Transport.read(c->fd, readBuf, READ_BUF_SIZE);
      if (n == 0) {
         return;
      }

      // Append to line buffer
      if (c->lineLen + n >= LINE_BUF_SIZE) {
         // Overflow protection: reset buffer
         c->lineLen = 0;
         c->lineBuf[0] = '\0';
         return;
      }
      {
         uint8_t i;
         for (i = 0; i < n; i++) {
            c->lineBuf[c->lineLen + i] = readBuf[i];
         }
         c->lineLen += n;
         c->lineBuf[c->lineLen] = '\0';
      }

      // Extract complete lines terminated by \r\n or lone \r/\n
      while (1) {
         uint8_t i;
         bool found = FALSE;
         for (i = 0; i + 1 < c->lineLen; i++) {
            if (c->lineBuf[i] == '\r' || c->lineBuf[i] == '\n') {
               uint8_t consume = 1;
               if (c->lineBuf[i] == '\r' && (i + 1 < c->lineLen) && c->lineBuf[i + 1] == '\n') {
                  consume = 2;
               }
               c->lineBuf[i] = '\0';
               processLine(c, c->lineBuf);
               // shift remaining
               {
                  uint8_t remaining = c->lineLen - (i + consume);
                  if (remaining > 0) {
                     memmove(c->lineBuf, &c->lineBuf[i + consume], remaining);
                  }
                  c->lineLen = remaining;
                  c->lineBuf[c->lineLen] = '\0';
               }
               found = TRUE;
               break;
            }
         }
         if (!found) {
            break;
         }
      }
   }

   command void ChatServer.start() {
      socket_addr_t addr;
      error_t err;
      uint8_t i;

      for (i = 0; i < MAX_CLIENTS; i++) {
         clients[i].inUse = FALSE;
         clients[i].fd = NULL_SOCKET;
         clients[i].addr = 0;
         clients[i].port = 0;
         clients[i].username[0] = '\0';
         clients[i].lineBuf[0] = '\0';
         clients[i].lineLen = 0;
      }


      // sanity checks
      serverSocket = call Transport.socket();
      if (serverSocket == NULL_SOCKET) {
         dbg(PROJECT4_CHAT_CHANNEL, "ChatServer: socket alloc failed\n");
         return;
      }

      addr.addr = TOS_NODE_ID;
      addr.port = CHAT_PORT;
      err = call Transport.bind(serverSocket, &addr);
      if (err != SUCCESS) {
         dbg(PROJECT4_CHAT_CHANNEL, "ChatServer: bind failed port=%hu\n", CHAT_PORT);
         call Transport.close(serverSocket);
         serverSocket = NULL_SOCKET;
         return;
      }

      err = call Transport.listen(serverSocket);
      if (err != SUCCESS) {
         dbg(PROJECT4_CHAT_CHANNEL, "ChatServer: listen failed port=%hu\n", CHAT_PORT);
         call Transport.close(serverSocket);
         serverSocket = NULL_SOCKET;
         return;
      }

      call AcceptTimer.startPeriodic(200);
      call ReadTimer.startPeriodic(200);
      dbg(PROJECT4_CHAT_CHANNEL, "ChatServer: listening on port %hu\n", CHAT_PORT);
   }

   event void AcceptTimer.fired() {
      if (serverSocket == NULL_SOCKET) {
         call AcceptTimer.stop();
         call ReadTimer.stop();
         return;
      }
      while (1) {
         socket_t fd = call Transport.accept(serverSocket);
         client_entry_t *c;
         if (fd == NULL_SOCKET) {
            break;
         }
         c = allocClient(fd);
         if (c == NULL) {
            dbg(PROJECT4_CHAT_CHANNEL, "ChatServer: max clients reached, closing fd=%hhu\n", fd);
            call Transport.close(fd);
         } else {
            dbg(PROJECT4_CHAT_CHANNEL, "ChatServer: accepted fd=%hhu\n", fd);
         }
      }
   }

   event void ReadTimer.fired() {
      uint8_t i;
      for (i = 0; i < MAX_CLIENTS; i++) {
         if (clients[i].inUse && clients[i].fd != NULL_SOCKET) {
            handleRead(&clients[i]);
         }
      }
   }
}
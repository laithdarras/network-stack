// Chat Client implementation

#include <string.h>
#include "../../includes/channels.h"
#include "../../includes/socket.h"
#include "../../includes/Transport.h"

module ChatClientP {
   provides interface ChatClient;
   uses interface Transport;
   uses interface Timer<TMilli> as ReadTimer;
}

implementation {
   enum {
      USERNAME_MAX = 12,      // username bytes
      USERNAME_BUF = USERNAME_MAX + 1,  // username storage with null terminating character
      LINE_BUF_SIZE = 128,       // per client assembled line buffer (commands + payload + clrf)
      READ_BUF_SIZE = 64,     // temporary read buffer per socket read
      CHAT_PORT = 41,      // tcp port
      SERVER_NODE = 1      // server node
   };

   socket_t fd = NULL_SOCKET;
   bool connected = FALSE;
   char username[USERNAME_BUF];
   socket_addr_t serverAddr;
   uint8_t readBuf[READ_BUF_SIZE];
   char lineBuf[LINE_BUF_SIZE];
   uint8_t lineLen = 0;


   // helper functions
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

   void processLine(char *line) {
      dbg(PROJECT4_CHAT_CHANNEL, "ChatClient recv: %s\n", line);
   }


   // connect client to server
   command void ChatClient.startHello(char *user, uint16_t clientPort) {
      socket_addr_t addr;
      error_t err;
      uint8_t i;
      char outBuf[32];
      uint16_t idx;

      if (connected || fd != NULL_SOCKET) {
         return;
      }

      fd = call Transport.socket();
      if (fd == NULL_SOCKET) {
         dbg(PROJECT4_CHAT_CHANNEL, "ChatClient: socket alloc failed\n");
         return;
      }

      addr.addr = TOS_NODE_ID;
      addr.port = clientPort;
      err = call Transport.bind(fd, &addr);
      if (err != SUCCESS) {
         dbg(PROJECT4_CHAT_CHANNEL, "ChatClient: bind failed port=%hu\n", clientPort);
         call Transport.close(fd);
         fd = NULL_SOCKET;
         return;
      }

      serverAddr.addr = SERVER_NODE;
      serverAddr.port = CHAT_PORT;
      err = call Transport.connect(fd, &serverAddr);
      if (err != SUCCESS) {
         dbg(PROJECT4_CHAT_CHANNEL, "ChatClient: connect failed to %hu:%hu\n", SERVER_NODE, CHAT_PORT);
         call Transport.close(fd);
         fd = NULL_SOCKET;
         return;
      }

      for (i = 0; i < USERNAME_MAX && user[i] != '\0'; i++) {
         username[i] = user[i];
      }
      username[i] = '\0';

      idx = 0;
      idx = appendStr(outBuf, idx, "hello ", sizeof(outBuf));
      idx = appendStr(outBuf, idx, username, sizeof(outBuf));
      finalizeCrlf(outBuf, idx, sizeof(outBuf));
      call Transport.write(fd, (uint8_t *)outBuf, strlen(outBuf));

      connected = TRUE;
      lineLen = 0;
      lineBuf[0] = '\0';
      call ReadTimer.startPeriodic(200);

      dbg(PROJECT4_CHAT_CHANNEL, "ChatClient: connected to server %hu:%hu as %s on port %hu\n",
          SERVER_NODE, CHAT_PORT, username, clientPort);
   }

   // broadcast a message to connected clients
   command void ChatClient.sendMsg(char *msg) {
      char outBuf[128];
      uint16_t idx;

      if (!connected || fd == NULL_SOCKET) {
         dbg(PROJECT4_CHAT_CHANNEL, "ChatClient: sendMsg skipped (not connected)\n");
         return;
      }

      idx = 0;
      idx = appendStr(outBuf, idx, "msg ", sizeof(outBuf));
      idx = appendStr(outBuf, idx, msg, sizeof(outBuf));
      finalizeCrlf(outBuf, idx, sizeof(outBuf));
      dbg(PROJECT4_CHAT_CHANNEL, "ChatClient sendMsg: %s\n", outBuf);
      call Transport.write(fd, (uint8_t *)outBuf, strlen(outBuf));
   }  

   // send a message to a specified client
   command void ChatClient.sendWhisper(char *user, char *msg) {
      char outBuf[128];
      uint16_t idx;

      if (!connected || fd == NULL_SOCKET) {
         dbg(PROJECT4_CHAT_CHANNEL, "ChatClient: sendWhisper skipped (not connected)\n");
         return;
      }

      idx = 0;
      idx = appendStr(outBuf, idx, "whisper ", sizeof(outBuf));
      idx = appendStr(outBuf, idx, user, sizeof(outBuf));
      idx = appendChar(outBuf, idx, ' ', sizeof(outBuf));
      idx = appendStr(outBuf, idx, msg, sizeof(outBuf));
      finalizeCrlf(outBuf, idx, sizeof(outBuf));
      dbg(PROJECT4_CHAT_CHANNEL, "ChatClient sendWhisper: %s\n", outBuf);
      call Transport.write(fd, (uint8_t *)outBuf, strlen(outBuf));
   }

   // print a list of users connected to the server
   command void ChatClient.sendListUsr() {
      char outBuf[16];
      uint16_t idx;

      if (!connected || fd == NULL_SOCKET) {
         dbg(PROJECT4_CHAT_CHANNEL, "ChatClient: sendListUsr skipped (not connected)\n");
         return;
      }

      idx = 0;
      idx = appendStr(outBuf, idx, "listusr", sizeof(outBuf));
      finalizeCrlf(outBuf, idx, sizeof(outBuf));
      dbg(PROJECT4_CHAT_CHANNEL, "ChatClient sendListUsr: %s\n", outBuf);
      call Transport.write(fd, (uint8_t *)outBuf, strlen(outBuf));
   }
   
   event void ReadTimer.fired() {
      uint16_t n;
      if (!connected || fd == NULL_SOCKET) {
         call ReadTimer.stop();
         return;
      }

      n = call Transport.read(fd, readBuf, READ_BUF_SIZE);
      if (n == 0) {
         return;
      }

      if (lineLen + n >= LINE_BUF_SIZE) {
         lineLen = 0;
         lineBuf[0] = '\0';
         return;
      }
      {
         uint8_t i;
         for (i = 0; i < n; i++) {
            lineBuf[lineLen + i] = readBuf[i];
         }
         lineLen += n;
         lineBuf[lineLen] = '\0';
      }

      while (1) {
         uint8_t i;
         bool found = FALSE;
         for (i = 0; i + 1 < lineLen; i++) {
            if (lineBuf[i] == '\r' && lineBuf[i + 1] == '\n') {
               lineBuf[i] = '\0';
               processLine(lineBuf);
               {
                  uint8_t remaining = lineLen - (i + 2);
                  if (remaining > 0) {
                     memmove(lineBuf, &lineBuf[i + 2], remaining);
                  }
                  lineLen = remaining;
                  lineBuf[lineLen] = '\0';
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
}
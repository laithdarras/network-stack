#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/socket.h"
#include "../../includes/protocol.h"
#include "../../includes/Transport.h"
#include "../../includes/channels.h"

// TCP connection states
enum {
   TCP_STATE_CLOSED = 0,
   TCP_STATE_LISTEN,
   TCP_STATE_SYN_SENT,
   TCP_STATE_SYN_RCVD,
   TCP_STATE_ESTABLISHED
};

// Buffer size constants (must be defined before socket_cb_t struct)
#ifndef SEND_BUF_SIZE
#define SEND_BUF_SIZE 128
#endif

#ifndef RECV_BUF_SIZE
#define RECV_BUF_SIZE 128
#endif

// RTT / timeout tuning
#ifndef TCP_RTT_EST
#define TCP_RTT_EST 500  // ms, conservative fixed estimate
#endif

#ifndef TCP_TIMEOUT
#define TCP_TIMEOUT (2 * TCP_RTT_EST)
#endif

// Max segment data size (MSS) – keep within existing packet size constraints
// PACKET_MAX_PAYLOAD_SIZE = 20, TCP header = 15 bytes, so max TCP data = 5 bytes
#ifndef TCP_MSS
#define TCP_MSS 5   // Max TCP data that fits in pack.payload (20 - 15 header)
#endif

#define MAX_SOCKETS 8
#define NULL_SOCKET 0xFF

// Retransmission tracking
typedef struct {
   socket_t fd;
   uint32_t seqStart;
   uint16_t len;
   uint32_t timeoutAt;
   bool inUse;
} retrans_entry_t;

#define MAX_RETRANS_QUEUE 16

static retrans_entry_t retransQueue[MAX_RETRANS_QUEUE];
static bool retransTimerRunning = FALSE;

// Internal socket control block (NOT the public socket_store_t)
typedef struct {
   bool inUse;
   uint8_t state;           // One of TCP_STATE_* values
   uint16_t localAddr;
   uint16_t localPort;
   uint16_t remoteAddr;
   uint16_t remotePort;
   // Handshake sequence numbers
   uint32_t iss;            // Initial send sequence number
   uint32_t irs;            // Initial receive sequence number from peer
   uint32_t sndNext;        // Next send sequence number
   uint32_t rcvNext;        // Next expected receive sequence number (legacy, prefer nextByteExpected)
   
   // Send-side state (for reliability / sliding window)
   uint8_t  sendBuf[SEND_BUF_SIZE];   // app data waiting to be (or already) sent
   uint32_t lastByteWritten;          // highest byte index written by app into sendBuf
   uint32_t lastByteSent;             // highest byte index actually sent in segments
   uint32_t lastByteAcked;            // highest byte index cumulatively acknowledged by peer
   uint16_t remoteAdvWindow;          // last advertised window from peer
   
   // Receive-side state (for Go-Back-N + flow control)
   uint8_t  recvBuf[RECV_BUF_SIZE];   // buffer for in-order received data
   uint32_t nextByteExpected;         // seq number of next byte we expect from peer
   uint32_t lastByteRead;             // last byte index returned to the app (for later read())
   uint16_t advWindow;                // this connection's advertised window (free space in recvBuf)
} socket_cb_t;

module TransportP {
   provides interface Transport;
   uses interface LinkState;
   uses interface SimpleSend;
   uses interface Packet;
   uses interface Timer<TMilli> as TestTimer;
   uses interface Timer<TMilli> as RetransTimer;
   uses interface Boot;
}

implementation {
   // Internal socket control block array
   static socket_cb_t sockets[MAX_SOCKETS];
   
   // Legacy socket_store_t array (kept for compatibility, may be used later)
   socket_store_t socketStores[MAX_NUM_OF_SOCKETS];
   uint8_t socketCount = 0;
   
   // Forward declarations
   static error_t sendSegment(uint16_t dstAddr, uint16_t srcPort, uint16_t dstPort, 
                             uint32_t seq, uint32_t ack, uint8_t flags, 
                             uint16_t advWindow, uint8_t *data, uint8_t dataLen);
   static void scheduleRetransTimer();
   static void enqueueRetrans(socket_t fd, uint32_t seqStart, uint16_t len, uint32_t now);
   static void initRetransQueue();
   static void cleanupAckedRetrans(socket_t fd, uint32_t lastByteAcked);
   static void clearRetransEntriesForSocket(socket_t fd);
   
   /**
    * Allocate a new socket from the socket table
    * @return socket_t - index of allocated socket, or NULL_SOCKET if table is full
    */
   static socket_t allocSocket() {
      uint8_t i;
      uint16_t j;
      for (i = 0; i < MAX_SOCKETS; i++) {
         if (!sockets[i].inUse) {
            sockets[i].inUse = TRUE;
            sockets[i].state = TCP_STATE_CLOSED;
            sockets[i].localAddr = TOS_NODE_ID;
            sockets[i].localPort = 0;
            sockets[i].remoteAddr = 0;
            sockets[i].remotePort = 0;
            sockets[i].iss = 0;
            sockets[i].irs = 0;
            sockets[i].sndNext = 0;
            sockets[i].rcvNext = 0;
            
            // Initialize send-side state
            sockets[i].lastByteWritten = 0;
            sockets[i].lastByteSent = 0;
            sockets[i].lastByteAcked = 0;
            sockets[i].remoteAdvWindow = SEND_BUF_SIZE;
            for (j = 0; j < SEND_BUF_SIZE; j++) {
               sockets[i].sendBuf[j] = 0;
            }
            
            // Initialize receive-side state
            sockets[i].nextByteExpected = 1;
            sockets[i].lastByteRead = 0;
            sockets[i].advWindow = RECV_BUF_SIZE;
            for (j = 0; j < RECV_BUF_SIZE; j++) {
               sockets[i].recvBuf[j] = 0;
            }
            
            return i;
         }
      }
      return NULL_SOCKET;
   }
   
   /**
    * Free a socket, clearing its state
    * @param fd - socket file descriptor to free
    */
   static void freeSocket(socket_t fd) {
      if (fd < MAX_SOCKETS) {
         sockets[fd].inUse = FALSE;
         sockets[fd].state = TCP_STATE_CLOSED;
      }
   }
   
   /**
    * Find a listening socket by local port
    * @param port - local port to search for
    * @return socket_t - index of matching socket, or NULL_SOCKET if not found
    */
   static socket_t findListeningSocketByPort(uint16_t port) {
      uint8_t i;
      for (i = 0; i < MAX_SOCKETS; i++) {
         if (sockets[i].inUse && 
             sockets[i].state == TCP_STATE_LISTEN && 
             sockets[i].localPort == port) {
            return i;
         }
      }
      return NULL_SOCKET;
   }
   
   /**
    * Find a socket by 4-tuple (localAddr, localPort, remoteAddr, remotePort)
    * @param localAddr - local address
    * @param localPort - local port
    * @param remoteAddr - remote address
    * @param remotePort - remote port
    * @return socket_t - index of matching socket, or NULL_SOCKET if not found
    */
   static socket_t findSocketBy4Tuple(uint16_t localAddr, uint16_t localPort, 
                                      uint16_t remoteAddr, uint16_t remotePort) {
      uint8_t i;
      for (i = 0; i < MAX_SOCKETS; i++) {
         if (sockets[i].inUse &&
             sockets[i].localAddr == localAddr &&
             sockets[i].localPort == localPort &&
             sockets[i].remoteAddr == remoteAddr &&
             sockets[i].remotePort == remotePort) {
            return i;
         }
      }
      return NULL_SOCKET;
   }
   
   /**
    * Start client-side handshake (sends SYN)
    * NOTE: This will be called from Transport.connect() when that is implemented
    * @param fd - socket file descriptor
    * @param remoteAddr - remote node address
    * @param remotePort - remote port
    * @param localPort - local port to use
    * @return error_t - SUCCESS if SYN sent, FAIL otherwise
    */
   static error_t startClientHandshake(socket_t fd, uint16_t remoteAddr, uint16_t remotePort, uint16_t localPort) {
      socket_cb_t *s;
      
      if (fd >= MAX_SOCKETS || !sockets[fd].inUse) {
         return FAIL;
      }
      
      s = &sockets[fd];
      
      // Initialize 4-tuple
      s->localAddr = TOS_NODE_ID;
      s->localPort = localPort;
      s->remoteAddr = remoteAddr;
      s->remotePort = remotePort;
      
      // Set state to SYN_SENT
      s->state = TCP_STATE_SYN_SENT;
      
      // Choose initial sequence number
      s->iss = 1;
      s->sndNext = s->iss + 1;  // SYN consumes one sequence number
      
      // Initialize receive sequence numbers and advertised window
      s->irs = 0;
      s->rcvNext = 0;
      s->advWindow = RECV_BUF_SIZE;
      
      // Send SYN segment
      if (sendSegment(remoteAddr, localPort, remotePort, 
                      s->iss, 0, TCP_FLAG_SYN, s->advWindow, NULL, 0) == SUCCESS) {
         dbg("Project3TCP", "Client: SYN sent (fd=%hhu, iss=%lu)\n", fd, s->iss);
         return SUCCESS;
      }
      
      return FAIL;
   }
   
   /**
    * Compute receive buffer free space for flow control
    * @param fd - socket file descriptor
    * @return uint16_t - free space in receive buffer
    */
   static uint16_t computeRecvFreeSpace(socket_t fd) {
      socket_cb_t *s = &sockets[fd];
      uint32_t used;
      
      if (s->nextByteExpected == 0) {
         // no data yet
         used = 0;
      } else {
         // bytes between lastByteRead+1 and nextByteExpected-1 are "in buffer but unread"
         used = (s->nextByteExpected - 1) - s->lastByteRead;
      }
      
      if (used >= RECV_BUF_SIZE) {
         return 0;
      }
      return (uint16_t)(RECV_BUF_SIZE - used);
   }

   /**
    * Initialize retransmission queue
    */
   static void initRetransQueue() {
      uint8_t i;
      for (i = 0; i < MAX_RETRANS_QUEUE; i++) {
         retransQueue[i].inUse = FALSE;
      }
      retransTimerRunning = FALSE;
   }

   /**
    * Helper to find earliest timeout and schedule timer
    */
   static void scheduleRetransTimer() {
      uint8_t i;
      bool found;
      uint32_t minTimeout;
      uint32_t now;
      uint32_t delta;

      found = FALSE;
      minTimeout = 0;
      for (i = 0; i < MAX_RETRANS_QUEUE; i++) {
         if (retransQueue[i].inUse) {
            if (!found || retransQueue[i].timeoutAt < minTimeout) {
               minTimeout = retransQueue[i].timeoutAt;
               found = TRUE;
            }
         }
      }

      if (!found) {
         if (retransTimerRunning) {
            call RetransTimer.stop();
            retransTimerRunning = FALSE;
         }
         return;
      }

      now = call RetransTimer.getNow();
      if (minTimeout <= now) {
         delta = 1;
      } else {
         delta = minTimeout - now;
         if (delta == 0) {
            delta = 1;
         }
      }

      call RetransTimer.startOneShot(delta);
      retransTimerRunning = TRUE;
   }

   /**
    * Enqueue a retransmission entry
    */
   static void enqueueRetrans(socket_t fd, uint32_t seqStart, uint16_t len, uint32_t now) {
      uint8_t i;
      for (i = 0; i < MAX_RETRANS_QUEUE; i++) {
         if (!retransQueue[i].inUse) {
            retransQueue[i].fd = fd;
            retransQueue[i].seqStart = seqStart;
            retransQueue[i].len = len;
            retransQueue[i].timeoutAt = now + TCP_TIMEOUT;
            retransQueue[i].inUse = TRUE;
            scheduleRetransTimer();
            return;
         }
      }

      dbg("Project3TCP", "Retrans queue full, dropping seqStart=%lu len=%hu\n",
          (unsigned long)seqStart, len);
   }

   /**
    * Cleanup retrans entries fully acknowledged
    */
   static void cleanupAckedRetrans(socket_t fd, uint32_t lastByteAcked) {
      uint8_t i;
      uint32_t seqEnd;

      for (i = 0; i < MAX_RETRANS_QUEUE; i++) {
         if (retransQueue[i].inUse && retransQueue[i].fd == fd) {
            seqEnd = retransQueue[i].seqStart + retransQueue[i].len - 1;
            if (seqEnd <= lastByteAcked) {
               retransQueue[i].inUse = FALSE;
            }
         }
      }

      scheduleRetransTimer();
   }

   /**
    * Clear retrans entries for socket (used when retransmitting Go-Back-N)
    */
   static void clearRetransEntriesForSocket(socket_t fd) {
      uint8_t i;
      for (i = 0; i < MAX_RETRANS_QUEUE; i++) {
         if (retransQueue[i].inUse && retransQueue[i].fd == fd) {
            retransQueue[i].inUse = FALSE;
         }
      }
   }
   
   /**
    * Try to send data from send buffer using Go-Back-N sliding window
    * @param fd - socket file descriptor (must be in ESTABLISHED state)
    */
   static void trySendData(socket_t fd) {
      socket_cb_t *s;
      uint32_t inFlight;
      uint16_t effectiveWindow;
      uint32_t bytesAvailable;
      uint32_t windowSpace;
      uint16_t dataLen;
      uint32_t seqNum;
      uint16_t bufIndex;
      uint32_t ackToSend;
      
      if (fd >= MAX_SOCKETS || !sockets[fd].inUse) {
         return;
      }
      
      s = &sockets[fd];
      
      if (s->state != TCP_STATE_ESTABLISHED) {
         return;
      }
      
      dbg("Project3TCP", "trySendData: entered (fd=%hhu, lastByteWritten=%lu, lastByteSent=%lu, lastByteAcked=%lu)\n",
          fd, s->lastByteWritten, s->lastByteSent, s->lastByteAcked);
      
      // Compute in-flight bytes and effective window
      inFlight = s->lastByteSent - s->lastByteAcked;
      effectiveWindow = s->remoteAdvWindow;
      if (effectiveWindow > SEND_BUF_SIZE) {
         effectiveWindow = SEND_BUF_SIZE;
      }
      
      // Update our advertised window before sending
      s->advWindow = computeRecvFreeSpace(fd);
      ackToSend = s->nextByteExpected;
      
      // While we have unsent data and window space available
      while (s->lastByteSent < s->lastByteWritten && inFlight < effectiveWindow) {
         // Determine how many bytes we can send in this segment
         bytesAvailable = s->lastByteWritten - s->lastByteSent;
         windowSpace = effectiveWindow - inFlight;
         dataLen = (uint16_t)bytesAvailable;
         
         if (dataLen > TCP_MSS) {
            dataLen = TCP_MSS;
         }
         if (dataLen > windowSpace) {
            dataLen = (uint16_t)windowSpace;
         }
         
         if (dataLen == 0) {
            break;
         }
         
         // Compute sequence number of first byte in this segment
         seqNum = s->lastByteSent + 1;
         
         // Map seqNum (1-based) to buffer index (0-based)
         bufIndex = (uint16_t)(seqNum - 1);
         
         // Build and send segment
         if (sendSegment(
               s->remoteAddr,
               s->localPort,
               s->remotePort,
               seqNum,
               ackToSend,
               TCP_FLAG_ACK,
               s->advWindow,
               &s->sendBuf[bufIndex],
               dataLen
            ) == SUCCESS) {
            
            // Update send state
            s->lastByteSent += dataLen;
            inFlight = s->lastByteSent - s->lastByteAcked;
            s->sndNext = s->lastByteSent + 1;

            // Track segment for possible retransmission
            {
               uint32_t now = call RetransTimer.getNow();
               enqueueRetrans(fd, seqNum, dataLen, now);
            }
            
            dbg("Project3TCP", "trySendData: sent segment seq=%lu dataLen=%hu inFlight=%lu effectiveWindow=%hu\n",
                seqNum, dataLen, inFlight, effectiveWindow);
         } else {
            dbg("Project3TCP", "trySendData: sendSegment failed, breaking\n");
            break;
         }
      }
      
      dbg("Project3TCP", "trySendData: exited (fd=%hhu, lastByteSent=%lu, inFlight=%lu)\n",
          fd, s->lastByteSent, inFlight);
   }
   
   /**
    * Handle a received TCP segment for a specific socket
    * @param fd - socket file descriptor
    * @param seg - pointer to received TCP segment
    * @param dataLen - length of data in segment
    */
   static void handleSegmentForSocket(socket_t fd, tcp_segment_t *seg, uint8_t dataLen) {
      socket_cb_t *s;
      uint8_t flags;
      
      if (fd >= MAX_SOCKETS || !sockets[fd].inUse) {
         return;
      }
      
      s = &sockets[fd];
      flags = seg->header.flags;
      
      // Handle handshake based on current state
      switch (s->state) {
         case TCP_STATE_SYN_SENT:
            // Client waiting for SYN+ACK
            if ((flags & TCP_FLAG_SYN) && (flags & TCP_FLAG_ACK)) {
               // Validate ACK acknowledges our SYN
               if (seg->header.ack == s->sndNext) {
                  // Record peer's initial sequence number
                  s->irs = seg->header.seq;
                  s->rcvNext = seg->header.seq + 1;  // SYN consumes one sequence number
                  
                  // Send final ACK
                  if (sendSegment(s->remoteAddr, s->localPort, s->remotePort,
                                  s->sndNext, s->rcvNext, TCP_FLAG_ACK, 0, NULL, 0) == SUCCESS) {
                     s->state = TCP_STATE_ESTABLISHED;
                     dbg("Project3TCP", "Client: connection ESTABLISHED (fd=%hhu)\n", fd);
                  }
               } else {
                  dbg("Project3TCP", "Client: invalid ACK in SYN+ACK (expected %lu, got %lu)\n", 
                      s->sndNext, seg->header.ack);
               }
            }
            // Ignore other segments in SYN_SENT state
            break;
            
         case TCP_STATE_SYN_RCVD:
            // Server waiting for final ACK
            if ((flags & TCP_FLAG_ACK) && !(flags & TCP_FLAG_SYN)) {
               // Validate ACK acknowledges our SYN and sequence matches
               if (seg->header.ack == s->sndNext && seg->header.seq == s->rcvNext) {
                  s->state = TCP_STATE_ESTABLISHED;
                  dbg("Project3TCP", "Server: connection ESTABLISHED (fd=%hhu)\n", fd);
               } else {
                  dbg("Project3TCP", "Server: invalid ACK (ack=%lu expected %lu, seq=%lu expected %lu)\n",
                      seg->header.ack, s->sndNext, seg->header.seq, s->rcvNext);
               }
            }
            // Ignore other segments in SYN_RCVD state
            break;
            
         case TCP_STATE_ESTABLISHED: {
            // Declare all variables at the top
            uint32_t ackNum;
            uint32_t seqNum;
            uint32_t expected;
            uint16_t bufIndex;
            uint32_t ackToSend;
            uint16_t freeSpace;
            
            ackNum = seg->header.ack;
            seqNum = seg->header.seq;
            
            // 1) Handle ACKs (even if data is also present)
            if (flags & TCP_FLAG_ACK) {
               // Update lastByteAcked if this ACK moves us forward
               if (ackNum > 0 && ackNum - 1 > s->lastByteAcked) {
                  s->lastByteAcked = ackNum - 1;
               }
               // Also update remoteAdvWindow from header
               s->remoteAdvWindow = seg->header.advWindow;
               
               // Remove fully ACKed retransmission entries
               cleanupAckedRetrans(fd, s->lastByteAcked);

               // Try to send more data now that window space may have opened
               trySendData(fd);
            }
            
            // 2) Handle data (Go-Back-N receiver behavior)
            if (dataLen > 0) {
               expected = s->nextByteExpected;
               
               if (seqNum == expected) {
                  // In-order segment: accept and place in recvBuf
                  // Map seqNum (1-based) to buffer index (0-based)
                  bufIndex = (uint16_t)(seqNum - 1);
                  if (bufIndex + dataLen <= RECV_BUF_SIZE) {
                     memcpy(&s->recvBuf[bufIndex], seg->data, dataLen);
                     s->nextByteExpected += dataLen;
                  } else {
                     // Out of buffer bounds; drop payload but still ACK current expected
                     dbg("Project3TCP", "EST: data exceeds recvBuf, dropping payload\n");
                  }
               } else if (seqNum < expected) {
                  // Duplicate or already received; ignore payload
                  dbg("Project3TCP", "EST: duplicate data seq=%lu expected=%lu\n",
                      (unsigned long)seqNum, (unsigned long)expected);
               } else { // seqNum > expected
                  // Out-of-order ahead; Go-Back-N receiver drops payload
                  dbg("Project3TCP", "EST: out-of-order seq=%lu expected=%lu (drop)\n",
                      (unsigned long)seqNum, (unsigned long)expected);
               }
               
               // After any data, we always send a cumulative ACK
               // (even if payload was dropped/duplicate).
               ackToSend = s->nextByteExpected;
               freeSpace = computeRecvFreeSpace(fd);
               s->advWindow = freeSpace;
               
               dbg("Project3TCP",
                   "EST: sending ACK ack=%lu advWindow=%u\n",
                   (unsigned long)ackToSend, freeSpace);
               
               // We don't advance sndNext here since this is a pure ACK.
               sendSegment(
                  s->remoteAddr,
                  s->localPort,
                  s->remotePort,
                  s->sndNext,           // current send seq (no new data)
                  ackToSend,
                  TCP_FLAG_ACK,
                  s->advWindow,
                  NULL,
                  0
               );
            }
            
            break;
         }
            
         default:
            // Ignore segments in other states for now
            break;
      }
   }

   /**
    * Helper function to send a TCP segment
    * @param dstAddr - Destination node address
    * @param srcPort - Source port
    * @param dstPort - Destination port
    * @param seq - Sequence number (first byte in segment)
    * @param ack - Acknowledgment number (next expected byte from peer)
    * @param flags - TCP flags (SYN/ACK/FIN bitfield)
    * @param advWindow - Advertised window size
    * @param data - Pointer to data payload (can be NULL if dataLen is 0)
    * @param dataLen - Length of data payload (0 if no data)
    * @return error_t - SUCCESS if sent, FAIL otherwise
    */
   static error_t sendSegment(uint16_t dstAddr, uint16_t srcPort, uint16_t dstPort, 
                      uint32_t seq, uint32_t ack, uint8_t flags, 
                      uint16_t advWindow, uint8_t *data, uint8_t dataLen) {
      // Declare all variables at the top
      tcp_segment_t tcpSeg;
      uint8_t len;
      uint16_t nextHop;
      pack sendPack;

      
      dbg("Project 3 - TCP", "sendSegment called: dst=%d srcPort=%d dstPort=%d\n", dstAddr, srcPort, dstPort);
      
      // Fill in TCP header
      tcpSeg.header.srcPort = srcPort;
      tcpSeg.header.dstPort = dstPort;
      tcpSeg.header.seq = seq;
      tcpSeg.header.ack = ack;
      tcpSeg.header.flags = flags;
      tcpSeg.header.advWindow = advWindow;
      
      // Copy data payload if provided
      if (dataLen > 0 && data != NULL) {
         if (dataLen > TCP_MAX_DATA) {
            dataLen = TCP_MAX_DATA;  // Truncate if too large
         }
         memcpy(tcpSeg.data, data, dataLen);
      } else {
         dataLen = 0;
      }
      
      // Calculate total segment length
      len = sizeof(tcp_header_t) + dataLen;
      
      // Get next hop for destination
      nextHop = call LinkState.nextHop(dstAddr);   // call routing
      dbg("Project 3 - TCP", "sendSegment: nextHop returned %d for dst %d\n", nextHop, dstAddr);
      if (nextHop == 0xFFFF) {
         dbg("Project 3 - TCP", "sendSegment: no route to %d (routing may not have converged yet)\n", dstAddr);
         return FAIL;
      }
      
      dbg("Project 3 - TCP", "sendSegment: nextHop=%d, sending\n", nextHop);
      
      // Create pack struct to send via SimpleSend
      // NOTE: The TCP segment is placed in the payload field of the pack struct
      sendPack.src = TOS_NODE_ID;
      sendPack.dest = dstAddr;
      sendPack.TTL = MAX_TTL;
      sendPack.seq = 0;  // Transport layer seq is in TCP header, not pack.seq
      sendPack.protocol = PROTOCOL_TCP;
      
      // Copy TCP segment into pack payload
      if (len > PACKET_MAX_PAYLOAD_SIZE) {
         dbg("Project 3 - TCP", "sendSegment: segment too large\n");
         return FAIL;
      }
      memcpy(sendPack.payload, (uint8_t *)&tcpSeg, len);
      
      // Send via SimpleSend to next hop
      if (call SimpleSend.send(sendPack, nextHop) == SUCCESS) {
         dbg("Project 3 - TCP", "sendSegment: sent successfully\n");
         return SUCCESS;
      }
      
      dbg("Project 3 - TCP", "sendSegment: SimpleSend.send failed\n");
      return FAIL;
   }

   
   command socket_t Transport.socket() {
      // Allocate a new socket
      return 0;
   }

   command error_t Transport.bind(socket_t fd, socket_addr_t *addr) {
      // Bind socket to address
      return FAIL;
   }

   command error_t Transport.connect(socket_t fd, socket_addr_t *addr) {
      // Initiate connection
      return FAIL;
   }

   command error_t Transport.listen(socket_t fd) {
      // Set socket to listen state
      return FAIL;
   }

   command socket_t Transport.accept(socket_t fd) {
      // Accept incoming connection
      return 0;
   }

   command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t bufflen) {
      // Send data (stop-and-wait)
      return 0;
   }

   command uint16_t Transport.read(socket_t fd, uint8_t *buff, uint16_t bufflen) {
      // Read received data
      return 0;
   }

   command error_t Transport.receive(pack* package) {
      // Declare all variables at the top
      tcp_segment_t *seg;
      uint8_t totalLen;
      uint8_t dataLen;
      uint16_t srcAddr;
      uint16_t dstAddr;
      uint16_t srcPort;
      uint16_t dstPort;
      uint32_t seq;
      uint32_t ack;
      uint8_t flags;
      uint16_t advWindow;
      socket_t fd;
      
      dbg("Project 3 - TCP", "Transport.receive called, protocol=%d\n", package->protocol);
      
      // Only process TCP protocol packets
      if (package->protocol != PROTOCOL_TCP) {
         return FAIL;
      }
      
      // Cast payload to TCP segment
      seg = (tcp_segment_t *)package->payload;
      
      // Derive addresses and ports
      srcAddr = package->src;   // Remote address (sender)
      dstAddr = package->dest;  // Local address (this node)
      srcPort = seg->header.srcPort;  // Remote port
      dstPort = seg->header.dstPort;  // Local port
      
      // Calculate data length: totalLen - header size
      // NOTE: The pack struct doesn't store the actual received payload length.
      // We assume the payload is fully used up to PACKET_MAX_PAYLOAD_SIZE.
      // In a real implementation, we might want to:
      // 1. Pass the actual length to Transport.receive() as a parameter, or
      // 2. Track the length separately, or
      // 3. Use a sentinel value in the data
      // For now, we derive dataLen conservatively:
      totalLen = PACKET_MAX_PAYLOAD_SIZE;  // Maximum possible payload size
      dataLen = 0;
      
      if (totalLen >= sizeof(tcp_header_t)) {
         dataLen = totalLen - sizeof(tcp_header_t);
         // Clamp to TCP_MAX_DATA (the maximum data we can send in one segment)
         if (dataLen > TCP_MAX_DATA) {
            dataLen = TCP_MAX_DATA;
         }
      }
      
      // Extract remaining TCP header fields
      seq = seg->header.seq;
      ack = seg->header.ack;
      flags = seg->header.flags;
      advWindow = seg->header.advWindow;
      
      // Look up socket by 4-tuple (localAddr, localPort, remoteAddr, remotePort)
      fd = findSocketBy4Tuple(dstAddr, dstPort, srcAddr, srcPort);
      
      if (fd != NULL_SOCKET) {
         // Socket found - log and handle segment
         dbg("Project 3 - TCP", "RX TCP for socket %hhu state=%hhu (local %hu:%hu, remote %hu:%hu)\n", 
             fd, sockets[fd].state, dstAddr, dstPort, srcAddr, srcPort);
         handleSegmentForSocket(fd, seg, dataLen);
      } else {
         // No matching socket found - check if this is a SYN for a new connection
         if (flags & TCP_FLAG_SYN) {
            // Look for a listening socket on the destination port
            socket_t listenFd = findListeningSocketByPort(dstPort);
            
            if (listenFd != NULL_SOCKET) {
               // Allocate new socket for this connection
               socket_t newFd = allocSocket();
               
               if (newFd != NULL_SOCKET) {
                  socket_cb_t *newS = &sockets[newFd];
                  
                  // Initialize 4-tuple
                  newS->localAddr = dstAddr;
                  newS->localPort = dstPort;
                  newS->remoteAddr = srcAddr;
                  newS->remotePort = srcPort;
                  
                  // Initialize handshake fields
                  newS->iss = 100;  // Server's initial sequence number
                  newS->sndNext = newS->iss + 1;  // SYN consumes one sequence number
                  newS->irs = seq;  // Record client's initial sequence number
                  newS->rcvNext = seq + 1;  // Expecting next byte after SYN
                  newS->advWindow = RECV_BUF_SIZE;
                  
                  // Set state to SYN_RCVD
                  newS->state = TCP_STATE_SYN_RCVD;
                  
                  // Send SYN+ACK
                  if (sendSegment(srcAddr, dstPort, srcPort,
                                  newS->iss, newS->rcvNext, 
                                  TCP_FLAG_SYN | TCP_FLAG_ACK, newS->advWindow, NULL, 0) == SUCCESS) {
                     dbg("Project3TCP", "SYN received, SYN+ACK sent, newFd=%hhu\n", newFd);
                  } else {
                     // Failed to send SYN+ACK, free the socket
                     freeSocket(newFd);
                     dbg("Project3TCP", "Failed to send SYN+ACK, freeing socket %hhu\n", newFd);
                  }
               } else {
                  dbg("Project3TCP", "No free socket available for new connection\n");
               }
            } else {
               // No listening socket on this port
               dbg("Project3TCP", "SYN received but no listening socket on port %hu\n", dstPort);
            }
         } else {
            // Not a SYN and no matching socket - drop it
            dbg("Project 3 - TCP", "RX TCP with no matching socket (local %hu:%hu, remote %hu:%hu)\n", 
                dstAddr, dstPort, srcAddr, srcPort);
         }
      }
      
      return SUCCESS;
   }

   command error_t Transport.close(socket_t fd) {
      // Close connection
      return FAIL;
   }

   command error_t Transport.release(socket_t fd) {
      // Hard close connection
      return FAIL;
   }
   

   // Testing TCP infra
   event void Boot.booted() {
      dbg("Project 3 - TCP", "Transport booted\n");
      initRetransQueue();
      call TestTimer.startOneShot(10000);  // 10 seconds to let routing converge
   }

   event void RetransTimer.fired() {
      uint8_t i;
      bool found;
      uint8_t earliestIdx;
      uint32_t now;
      retrans_entry_t *entry;
      socket_cb_t *s;
      uint32_t seqEnd;

      now = call RetransTimer.getNow();
      found = FALSE;
      earliestIdx = 0;

      for (i = 0; i < MAX_RETRANS_QUEUE; i++) {
         if (retransQueue[i].inUse) {
            if (!found || retransQueue[i].timeoutAt < retransQueue[earliestIdx].timeoutAt) {
               earliestIdx = i;
               found = TRUE;
            }
         }
      }

      if (!found) {
         retransTimerRunning = FALSE;
         return;
      }

      entry = &retransQueue[earliestIdx];

      if (entry->timeoutAt > now) {
          scheduleRetransTimer();
          return;
      }

      if (entry->fd >= MAX_SOCKETS) {
         entry->inUse = FALSE;
         scheduleRetransTimer();
         return;
      }

      s = &sockets[entry->fd];

      if (!s->inUse || s->state != TCP_STATE_ESTABLISHED) {
         entry->inUse = FALSE;
         scheduleRetransTimer();
         return;
      }

      seqEnd = entry->seqStart + entry->len - 1;
      if (seqEnd <= s->lastByteAcked) {
         entry->inUse = FALSE;
         scheduleRetransTimer();
         return;
      }

      dbg("Project3TCP", "Timeout on fd=%hhu seqStart=%lu, retransmitting unACKed data\n",
          entry->fd, (unsigned long)entry->seqStart);

      // Go-Back-N: reset send pointer to last ACKed byte
      s->lastByteSent = s->lastByteAcked;
      s->sndNext = s->lastByteSent + 1;

      // Clear all outstanding retrans entries for this socket
      clearRetransEntriesForSocket(entry->fd);

      // Resend all unACKed data
      trySendData(entry->fd);

      scheduleRetransTimer();
   }
   
   event void TestTimer.fired() {
      dbg("Project 3 - TCP", "Timer fired, calling sendSegment\n");
      // Send to node 2 (direct neighbor) for routing to work immediately
      sendSegment(2, 1234, 5678, 0, 0, TCP_FLAG_SYN, 100, NULL, 0);
   }
}


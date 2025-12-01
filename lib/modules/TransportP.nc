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
   TCP_STATE_ESTABLISHED,
   TCP_STATE_FIN_WAIT_1,
   TCP_STATE_FIN_WAIT_2,
   TCP_STATE_CLOSE_WAIT,
   TCP_STATE_LAST_ACK,
   TCP_STATE_TIME_WAIT
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

#ifndef TCP_TIME_WAIT
#define TCP_TIME_WAIT 5000  // ms
#endif

#define MAX_SOCKETS 8

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

   // Server / accept tracking
   bool isServer;           // TRUE if this is the server side of a connection
   bool pendingAccept;      // TRUE until this connection is returned by accept()

   // Handshake sequence numbers
   uint32_t iss;            // Initial send sequence number
   uint32_t irs;            // Initial receive sequence number from peer
   uint32_t sndNext;        // Next send sequence number
   uint32_t rcvNext;        // Next expected receive sequence number (legacy, prefer nextByteExpected)

   // FIN / teardown tracking
   bool     finInFlight;    // TRUE if we have sent a FIN not yet ACKed
   uint32_t finSeq;         // Sequence number of our FIN byte
   bool     finReceived;    // TRUE if we have received a FIN from peer
   uint32_t timeWaitStart;  // Timestamp when we entered TIME_WAIT (ms)
   
   // Send-side state (for reliability / sliding window)
   uint8_t  sendBuf[SEND_BUF_SIZE];   // app data waiting to be (or already) sent
   uint32_t lastByteWritten;          // highest byte index written by app into sendBuf
   uint32_t lastByteSent;             // highest byte index actually sent in segments
   uint32_t lastByteAcked;            // highest byte index cumulatively acknowledged by peer
   uint16_t remoteAdvWindow;          // last advertised window from peer
   uint16_t cwnd;                     // congestion window (bytes)
   uint16_t ssthresh;                 // slow start threshold (bytes)
   
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
   // Compute number of bytes currently in flight (sent but not yet cumulatively ACKed)
   static uint32_t bytesInFlight(socket_cb_t *s) {
      if (s->lastByteSent >= s->lastByteAcked) {
         return s->lastByteSent - s->lastByteAcked;
      } else {
         // Safety clamp: ACK should never be ahead of what we've sent.
         dbg(TRANSPORT_CHANNEL,
             "CC WARNING: lastByteAcked(%u) > lastByteSent(%u), clamping\n",
             (unsigned int)s->lastByteAcked,
             (unsigned int)s->lastByteSent);
         return 0;
      }
   }

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
   static error_t sendFin(socket_t fd);
   
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
            sockets[i].isServer = FALSE;
            sockets[i].pendingAccept = FALSE;
            sockets[i].iss = 0;
            sockets[i].irs = 0;
            sockets[i].sndNext = 0;
            sockets[i].rcvNext = 0;
            sockets[i].finInFlight = FALSE;
            sockets[i].finSeq = 0;
            sockets[i].finReceived = FALSE;
            sockets[i].timeWaitStart = 0;
            
            // Initialize send-side state
            sockets[i].lastByteWritten = 0;
            sockets[i].lastByteSent = 0;
            sockets[i].lastByteAcked = 0;
            sockets[i].remoteAdvWindow = SEND_BUF_SIZE;
            sockets[i].cwnd = TCP_MSS;           // start congestion window at 1 MSS
            sockets[i].ssthresh = 4 * TCP_MSS;   // simple initial slow-start threshold
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
      
      // Choose initial sequence number (start at 0, SYN is seq=0, first data is seq=1)
      s->iss = 0;
      s->sndNext = s->iss + 1;  // Next seq after SYN
      
      // Initialize receive sequence numbers and advertised window
      s->irs = 0;
      s->rcvNext = 0;
      s->advWindow = RECV_BUF_SIZE;
      
      // Send SYN segment
      if (sendSegment(remoteAddr, localPort, remotePort, 
                      s->iss, 0, TCP_FLAG_SYN, s->advWindow, NULL, 0) == SUCCESS) {
         dbg(TRANSPORT_CHANNEL, "Client: SYN sent (fd=%hhu, iss=%lu)\n", fd, s->iss);
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
      bool timeWaitFound;
      uint32_t timeWaitDeadline;

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

      now = call RetransTimer.getNow();

      if (!found) {
         timeWaitFound = FALSE;
         timeWaitDeadline = 0;
         for (i = 0; i < MAX_SOCKETS; i++) {
            socket_cb_t *s = &sockets[i];
            if (!s->inUse) {
               continue;
            }
            if (s->state == TCP_STATE_TIME_WAIT && s->timeWaitStart > 0) {
               uint32_t expiry = s->timeWaitStart + TCP_TIME_WAIT;
               if (!timeWaitFound || expiry < timeWaitDeadline) {
                  timeWaitDeadline = expiry;
                  timeWaitFound = TRUE;
               }
            }
         }

         if (!timeWaitFound) {
            if (retransTimerRunning) {
               call RetransTimer.stop();
               retransTimerRunning = FALSE;
            }
            return;
         }

         if (timeWaitDeadline <= now) {
            delta = 1;
         } else {
            delta = timeWaitDeadline - now;
            if (delta == 0) {
               delta = 1;
            }
         }

         call RetransTimer.startOneShot(delta);
         retransTimerRunning = TRUE;
         return;
      }

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

      dbg(TRANSPORT_CHANNEL, "Retrans queue full, dropping seqStart=%lu len=%hu\n",
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
      uint16_t spaceToEnd;
      uint32_t ackToSend;
      
      if (fd >= MAX_SOCKETS || !sockets[fd].inUse) {
         return;
      }
      
      s = &sockets[fd];
      
      if (s->state != TCP_STATE_ESTABLISHED) {
         return;
      }
      
      dbg(TRANSPORT_CHANNEL, "trySendData: entered (fd=%hhu, lastByteWritten=%lu, lastByteSent=%lu, lastByteAcked=%lu)\n",
          fd, s->lastByteWritten, s->lastByteSent, s->lastByteAcked);
      
      // Compute in-flight bytes safely
      inFlight = bytesInFlight(s);

      // Effective window is min(congestion window, peer's advertised window, and our send buffer)
      {
         uint16_t congWindow = s->cwnd;
         uint16_t flowWindow = s->remoteAdvWindow;
         uint16_t bufWindow  = SEND_BUF_SIZE;

         effectiveWindow = congWindow;
         if (flowWindow < effectiveWindow) {
            effectiveWindow = flowWindow;
         }
         if (bufWindow < effectiveWindow) {
            effectiveWindow = bufWindow;
         }
      }

      dbg(TRANSPORT_CHANNEL, "CC: trySendData fd=%hhu cwnd=%hu effWin=%hu inFlight=%lu\n",
          fd, s->cwnd, effectiveWindow, (unsigned long)inFlight);
      
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
         
         // Map seqNum (1-based) to buffer index (0-based, circular)
         bufIndex = (uint16_t)((seqNum - 1) % SEND_BUF_SIZE);

         // Ensure we never run past the end of the circular buffer in this segment
         spaceToEnd = (uint16_t)(SEND_BUF_SIZE - bufIndex);
         if (dataLen > spaceToEnd) {
            dataLen = spaceToEnd;
         }
         
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
            inFlight = bytesInFlight(s);
            s->sndNext = s->lastByteSent + 1;

            // Track segment for possible retransmission
            {
               uint32_t now = call RetransTimer.getNow();
               enqueueRetrans(fd, seqNum, dataLen, now);
            }
            
            dbg(TRANSPORT_CHANNEL, "trySendData: sent segment seq=%lu dataLen=%hu inFlight=%lu effectiveWindow=%hu\n",
                seqNum, dataLen, inFlight, effectiveWindow);
         } else {
            dbg(TRANSPORT_CHANNEL, "trySendData: sendSegment failed, breaking\n");
            break;
         }
      }
      
      dbg(TRANSPORT_CHANNEL, "trySendData: exited (fd=%hhu, lastByteSent=%lu, inFlight=%lu)\n",
          fd, s->lastByteSent, inFlight);
   }

   /**
    * Send FIN segment for socket
    */
   static error_t sendFin(socket_t fd) {
      socket_cb_t *s;
      uint32_t seqNum;
      uint16_t advWin;
      error_t err;
      uint32_t now;

      if (fd >= MAX_SOCKETS || !sockets[fd].inUse) {
         return FAIL;
      }

      s = &sockets[fd];

      seqNum = s->lastByteSent + 1;  // FIN consumes one sequence number
      advWin = s->advWindow;
      if (advWin == 0) {
         advWin = computeRecvFreeSpace(fd);
         s->advWindow = advWin;
      }

      dbg(TRANSPORT_CHANNEL, "sendFin(): fd=%hhu seq=%lu\n", fd, (unsigned long)seqNum);

      err = sendSegment(
         s->remoteAddr,
         s->localPort,
         s->remotePort,
         seqNum,
         s->nextByteExpected,
         (TCP_FLAG_FIN | TCP_FLAG_ACK),
         advWin,
         NULL,
         0
      );

      if (err != SUCCESS) {
         dbg(TRANSPORT_CHANNEL, "sendFin(): sendSegment failed fd=%hhu\n", fd);
         return err;
      }

      // Update send state
      s->lastByteSent = seqNum;
      s->sndNext = s->lastByteSent + 1;
      s->finInFlight = TRUE;
      s->finSeq = seqNum;

      now = call RetransTimer.getNow();
      enqueueRetrans(fd, seqNum, 1, now);

      return SUCCESS;
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
               dbg(TRANSPORT_CHANNEL, "SYN_SENT: received SYN+ACK ack=%lu expected=%lu (fd=%hhu)\n",
                   seg->header.ack, s->sndNext, fd);
               if (seg->header.ack == s->sndNext) {
                  // Record peer's initial sequence number
                  s->irs = seg->header.seq;
                  s->rcvNext = seg->header.seq + 1;  // SYN consumes one sequence number

                  // Initialize receive state for data from server
                  s->nextByteExpected = s->rcvNext;
                  s->lastByteRead = 0;

                  // Learn server's advertised window
                  s->remoteAdvWindow = seg->header.advWindow;
                  
                  // Send final ACK
                  if (sendSegment(s->remoteAddr, s->localPort, s->remotePort,
                                  s->sndNext, s->rcvNext, TCP_FLAG_ACK, 0, NULL, 0) == SUCCESS) {
                     s->state = TCP_STATE_ESTABLISHED;
                     // Initialize congestion control on successful handshake
                     s->cwnd = TCP_MSS;
                     if (s->ssthresh < 2 * TCP_MSS) {
                        s->ssthresh = 4 * TCP_MSS;
                     }
                     dbg(TRANSPORT_CHANNEL, "Client: connection ESTABLISHED (fd=%hhu)\n", fd);
                     // If any application data was queued before connect completed, send it now
                     trySendData(fd);
                  }
               } else {
                  dbg(TRANSPORT_CHANNEL, "Client: invalid ACK in SYN+ACK (expected %lu, got %lu, fd=%hhu)\n", 
                      s->sndNext, seg->header.ack, fd);
               }
            }
            // Ignore other segments in SYN_SENT state
            break;
            
         case TCP_STATE_SYN_RCVD:
            // Server waiting for final ACK
            dbg(TRANSPORT_CHANNEL, "SYN_RCVD: received segment flags=%hhu ack=%lu expected_ack=%lu seq=%lu expected_seq=%lu (fd=%hhu)\n",
                flags, seg->header.ack, s->sndNext, seg->header.seq, s->rcvNext, fd);
            if ((flags & TCP_FLAG_ACK) && !(flags & TCP_FLAG_SYN)) {
               // Validate ACK acknowledges our SYN and sequence matches
               if (seg->header.ack == s->sndNext && seg->header.seq == s->rcvNext) {
                  // Initialize receive state for data from client
                  s->nextByteExpected = s->rcvNext;
                  s->lastByteRead = 0;

                  // Learn client's advertised window from its ACK
                  s->remoteAdvWindow = seg->header.advWindow;

                  s->state = TCP_STATE_ESTABLISHED;
                  // Initialize congestion control on successful handshake
                  s->cwnd = TCP_MSS;
                  if (s->ssthresh < 2 * TCP_MSS) {
                     s->ssthresh = 4 * TCP_MSS;
                  }
                  dbg(TRANSPORT_CHANNEL, "Server: connection ESTABLISHED (fd=%hhu, pendingAccept=%u, remote=%hu:%hu)\n", 
                      fd, s->pendingAccept, s->remoteAddr, s->remotePort);
                  // If any application data was queued before connect completed, send it now
                  trySendData(fd);
               } else {
                  dbg(TRANSPORT_CHANNEL, "Server: invalid ACK (ack=%lu expected %lu, seq=%lu expected %lu, fd=%hhu)\n",
                      seg->header.ack, s->sndNext, seg->header.seq, s->rcvNext, fd);
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
            uint16_t firstChunk;
            uint16_t secondChunk;
            uint16_t spaceToEnd;
            uint32_t oldLastByteAcked;
            uint32_t newLastByteAcked;
            uint32_t ackedBytes;

            ackNum = seg->header.ack;
            seqNum = seg->header.seq;
            
            // 1) Handle ACKs (even if data is also present)
            if (flags & TCP_FLAG_ACK) {
               // Save old ACKed range for congestion control
               oldLastByteAcked = s->lastByteAcked;

               // Update lastByteAcked if this ACK moves us forward, but never beyond lastByteSent
               if (ackNum > 0) {
                  uint32_t proposed = ackNum - 1;
                  if (proposed > s->lastByteAcked) {
                     if (proposed > s->lastByteSent) {
                        dbg(TRANSPORT_CHANNEL,
                            "CC WARNING: proposed lastByteAcked(%u) > lastByteSent(%u), clamping\n",
                            (unsigned int)proposed,
                            (unsigned int)s->lastByteSent);
                        proposed = s->lastByteSent;
                     }
                     s->lastByteAcked = proposed;
                  }
               }

               // Compute how many new bytes were acknowledged (after clamping)
               newLastByteAcked = s->lastByteAcked;
               ackedBytes = 0;
               if (newLastByteAcked > oldLastByteAcked) {
                  ackedBytes = newLastByteAcked - oldLastByteAcked;
               }

               // Tahoe-style congestion control: only adjust cwnd when we make forward progress
               if (ackedBytes > 0) {
                  if (s->cwnd < s->ssthresh) {
                     // Slow start: cwnd grows by 1 MSS per ACK
                     if ((uint32_t)s->cwnd + TCP_MSS > 65535U) {
                        s->cwnd = 65535;
                     } else {
                        s->cwnd += TCP_MSS;
                     }
                     dbg(TRANSPORT_CHANNEL,
                         "CC: fd=%hhu slow-start ackedBytes=%u cwnd=%u ssthresh=%u\n",
                         fd, (unsigned int)ackedBytes, s->cwnd, s->ssthresh);
                  } else {
                     // Congestion avoidance: linear increase (1 byte per ACK is fine for project)
                     if (s->cwnd < 65535) {
                        s->cwnd += 1;
                     }
                     dbg(TRANSPORT_CHANNEL,
                         "CC: fd=%hhu cong-avoid ackedBytes=%u cwnd=%u ssthresh=%u\n",
                         fd, (unsigned int)ackedBytes, s->cwnd, s->ssthresh);
                  }
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
                  // In-order segment: accept and place in recvBuf (circular)
                  // Map seqNum (1-based) to buffer index (0-based, circular)
                  bufIndex = (uint16_t)((seqNum - 1) % RECV_BUF_SIZE);
                  spaceToEnd = (uint16_t)(RECV_BUF_SIZE - bufIndex);

                  // Copy may wrap; split into at most two chunks
                  firstChunk = dataLen;
                  if (firstChunk > spaceToEnd) {
                     firstChunk = spaceToEnd;
                  }

                  if (firstChunk > 0) {
                     memcpy(&s->recvBuf[bufIndex], seg->data, firstChunk);
                  }

                  secondChunk = dataLen - firstChunk;
                  if (secondChunk > 0) {
                     memcpy(&s->recvBuf[0], seg->data + firstChunk, secondChunk);
                  }

                  // Advance expected sequence by full dataLen accepted
                  s->nextByteExpected += dataLen;
               } else if (seqNum < expected) {
                  // Duplicate or already received; ignore payload
                  dbg(TRANSPORT_CHANNEL, "EST: duplicate data seq=%lu expected=%lu (fd=%hhu)\n",
                      (unsigned long)seqNum, (unsigned long)expected, fd);
               } else { // seqNum > expected
                  // Out-of-order ahead; Go-Back-N receiver drops payload
                  dbg(TRANSPORT_CHANNEL, "EST: out-of-order seq=%lu expected=%lu (drop, fd=%hhu)\n",
                      (unsigned long)seqNum, (unsigned long)expected, fd);
               }
               
               // After any data, we always send a cumulative ACK
               // (even if payload was dropped/duplicate).
               ackToSend = s->nextByteExpected;
               freeSpace = computeRecvFreeSpace(fd);
               s->advWindow = freeSpace;
               
               dbg(TRANSPORT_CHANNEL,
                   "EST: sending ACK ack=%lu advWindow=%u (fd=%hhu)\n",
                   (unsigned long)ackToSend, freeSpace, fd);
               
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

            // 3) Handle FIN from peer (passive close)
            if (flags & TCP_FLAG_FIN) {
               uint32_t finSeq;
               uint32_t ackFin;
               uint16_t advWin;

               finSeq = seg->header.seq;
               ackFin = finSeq + 1;  // FIN consumes one sequence number

               dbg(TRANSPORT_CHANNEL, "ESTABLISHED: fd=%hhu received FIN seq=%lu\n",
                   fd, (unsigned long)finSeq);

               if (s->nextByteExpected < ackFin) {
                  s->nextByteExpected = ackFin;
               }

               advWin = computeRecvFreeSpace(fd);
               s->advWindow = advWin;

               sendSegment(
                  s->remoteAddr,
                  s->localPort,
                  s->remotePort,
                  s->sndNext,
                  s->nextByteExpected,
                  TCP_FLAG_ACK,
                  advWin,
                  NULL,
                  0
               );

               s->finReceived = TRUE;
               s->state = TCP_STATE_CLOSE_WAIT;
               dbg(TRANSPORT_CHANNEL, "ESTABLISHED: fd=%hhu -> CLOSE_WAIT\n", fd);
               return;
            }
            
            break;
         }

         case TCP_STATE_FIN_WAIT_1: {
            uint32_t ackNum;

            dbg(TRANSPORT_CHANNEL, "FIN_WAIT_1: fd=%hhu segment flags=%u\n", fd, flags);

            if (flags & TCP_FLAG_ACK) {
               ackNum = seg->header.ack;
               if (ackNum > 0 && ackNum - 1 > s->lastByteAcked) {
                  s->lastByteAcked = ackNum - 1;
                  cleanupAckedRetrans(fd, s->lastByteAcked);
               }
               s->remoteAdvWindow = seg->header.advWindow;

               if (s->finInFlight && s->lastByteAcked >= s->finSeq) {
                  s->finInFlight = FALSE;
                  s->state = TCP_STATE_FIN_WAIT_2;
                  dbg(TRANSPORT_CHANNEL, "FIN_WAIT_1: fd=%hhu -> FIN_WAIT_2\n", fd);
               }
            }

            if (flags & TCP_FLAG_FIN) {
               uint32_t finSeq = seg->header.seq;
               uint32_t ackFin = finSeq + 1;
               uint16_t advWin = computeRecvFreeSpace(fd);

               dbg(TRANSPORT_CHANNEL, "FIN_WAIT_1: fd=%hhu received FIN seq=%lu\n",
                   fd, (unsigned long)finSeq);

               if (s->nextByteExpected < ackFin) {
                  s->nextByteExpected = ackFin;
               }

               s->advWindow = advWin;
               sendSegment(
                  s->remoteAddr,
                  s->localPort,
                  s->remotePort,
                  s->sndNext,
                  s->nextByteExpected,
                  TCP_FLAG_ACK,
                  advWin,
                  NULL,
                  0
               );

               s->state = TCP_STATE_TIME_WAIT;
               s->timeWaitStart = call RetransTimer.getNow();
               dbg(TRANSPORT_CHANNEL, "FIN_WAIT_1: fd=%hhu -> TIME_WAIT\n", fd);
            }

            break;
         }

         case TCP_STATE_FIN_WAIT_2: {
            dbg(TRANSPORT_CHANNEL, "FIN_WAIT_2: fd=%hhu segment flags=%u\n", fd, flags);

            if (flags & TCP_FLAG_ACK) {
               uint32_t ackNum = seg->header.ack;
               if (ackNum > 0 && ackNum - 1 > s->lastByteAcked) {
                  s->lastByteAcked = ackNum - 1;
                  cleanupAckedRetrans(fd, s->lastByteAcked);
               }
               s->remoteAdvWindow = seg->header.advWindow;
            }

            if (flags & TCP_FLAG_FIN) {
               uint32_t finSeq = seg->header.seq;
               uint32_t ackFin = finSeq + 1;
               uint16_t advWin = computeRecvFreeSpace(fd);

               dbg(TRANSPORT_CHANNEL, "FIN_WAIT_2: fd=%hhu received FIN seq=%lu\n",
                   fd, (unsigned long)finSeq);

               if (s->nextByteExpected < ackFin) {
                  s->nextByteExpected = ackFin;
               }

               s->advWindow = advWin;
               sendSegment(
                  s->remoteAddr,
                  s->localPort,
                  s->remotePort,
                  s->sndNext,
                  s->nextByteExpected,
                  TCP_FLAG_ACK,
                  advWin,
                  NULL,
                  0
               );

               s->state = TCP_STATE_TIME_WAIT;
               s->timeWaitStart = call RetransTimer.getNow();
               dbg(TRANSPORT_CHANNEL, "FIN_WAIT_2: fd=%hhu -> TIME_WAIT\n", fd);
            }

            break;
         }

         case TCP_STATE_CLOSE_WAIT:
            dbg(TRANSPORT_CHANNEL, "CLOSE_WAIT: fd=%hhu received segment (flags=%u)\n", fd, flags);
            // Ignore data; ACK duplicate FINs if they arrive
            if (flags & TCP_FLAG_FIN) {
               uint32_t finSeq = seg->header.seq;
               uint32_t ackFin = finSeq + 1;
               uint16_t advWin = computeRecvFreeSpace(fd);
               if (s->nextByteExpected < ackFin) {
                  s->nextByteExpected = ackFin;
               }
               s->advWindow = advWin;
               sendSegment(
                  s->remoteAddr,
                  s->localPort,
                  s->remotePort,
                  s->sndNext,
                  s->nextByteExpected,
                  TCP_FLAG_ACK,
                  advWin,
                  NULL,
                  0
               );
            }
            break;

         case TCP_STATE_LAST_ACK:
            dbg(TRANSPORT_CHANNEL, "LAST_ACK: fd=%hhu segment flags=%u\n", fd, flags);
            if (flags & TCP_FLAG_ACK) {
               uint32_t ackNum = seg->header.ack;
               if (ackNum > 0 && ackNum - 1 > s->lastByteAcked) {
                  s->lastByteAcked = ackNum - 1;
                  cleanupAckedRetrans(fd, s->lastByteAcked);
               }
               s->remoteAdvWindow = seg->header.advWindow;
               if (s->finInFlight && s->lastByteAcked >= s->finSeq) {
                  s->finInFlight = FALSE;
                  dbg(TRANSPORT_CHANNEL, "LAST_ACK: fd=%hhu FIN ACKed, closing\n", fd);
                  freeSocket(fd);
                  return;
               }
            }
            if (flags & TCP_FLAG_FIN) {
               uint32_t finSeq = seg->header.seq;
               uint32_t ackFin = finSeq + 1;
               uint16_t advWin = computeRecvFreeSpace(fd);
               if (s->nextByteExpected < ackFin) {
                  s->nextByteExpected = ackFin;
               }
               s->advWindow = advWin;
               sendSegment(
                  s->remoteAddr,
                  s->localPort,
                  s->remotePort,
                  s->sndNext,
                  s->nextByteExpected,
                  TCP_FLAG_ACK,
                  advWin,
                  NULL,
                  0
               );
            }
            break;

         case TCP_STATE_TIME_WAIT:
            dbg(TRANSPORT_CHANNEL, "TIME_WAIT: fd=%hhu segment flags=%u (ignored)\n", fd, flags);
            if (flags & TCP_FLAG_FIN) {
               uint32_t finSeq = seg->header.seq;
               uint32_t ackFin = finSeq + 1;
               uint16_t advWin = computeRecvFreeSpace(fd);
               if (s->nextByteExpected < ackFin) {
                  s->nextByteExpected = ackFin;
               }
               s->advWindow = advWin;
               sendSegment(
                  s->remoteAddr,
                  s->localPort,
                  s->remotePort,
                  s->sndNext,
                  s->nextByteExpected,
                  TCP_FLAG_ACK,
                  advWin,
                  NULL,
                  0
               );
            }
            break;
            
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

      
      dbg(TRANSPORT_CHANNEL, "sendSegment called: dst=%d srcPort=%d dstPort=%d\n", dstAddr, srcPort, dstPort);
      
      // Fill in TCP header
      tcpSeg.header.srcPort = srcPort;
      tcpSeg.header.dstPort = dstPort;
      tcpSeg.header.seq = seq;
      tcpSeg.header.ack = ack;
      tcpSeg.header.flags = flags;
      tcpSeg.header.advWindow = advWindow;

      // Copy data payload if provided
      if (dataLen > 0 && data != NULL) {
         // Enforce both TCP_MAX_DATA and TCP_MSS limits
         if (dataLen > TCP_MAX_DATA) {
            dataLen = TCP_MAX_DATA;
         }
         if (dataLen > TCP_MSS) {
            dataLen = TCP_MSS;
         }
         memcpy(tcpSeg.data, data, dataLen);
      } else {
         dataLen = 0;
      }

      // Set dataLen in header to tell receiver exact payload size
      tcpSeg.header.dataLen = dataLen;
      
      // Calculate total segment length
      len = sizeof(tcp_header_t) + dataLen;
      
      // Get next hop for destination
      nextHop = call LinkState.nextHop(dstAddr);   // call routing
      dbg(TRANSPORT_CHANNEL, "sendSegment: nextHop returned %d for dst %d\n", nextHop, dstAddr);
      if (nextHop == 0xFFFF) {
         dbg(TRANSPORT_CHANNEL, "sendSegment: no route to %d (routing may not have converged yet)\n", dstAddr);
         return FAIL;
      }
      
      dbg(TRANSPORT_CHANNEL, "sendSegment: nextHop=%d, sending\n", nextHop);
      
      // Create pack struct to send via SimpleSend
      // NOTE: The TCP segment is placed in the payload field of the pack struct
      sendPack.src = TOS_NODE_ID;
      sendPack.dest = dstAddr;
      sendPack.TTL = MAX_TTL;
      sendPack.seq = 0;  // Transport layer seq is in TCP header, not pack.seq
      sendPack.protocol = PROTOCOL_TCP;
      
      // Copy TCP segment into pack payload
      if (len > PACKET_MAX_PAYLOAD_SIZE) {
         dbg(TRANSPORT_CHANNEL, "sendSegment: segment too large\n");
         return FAIL;
      }
      memcpy(sendPack.payload, (uint8_t *)&tcpSeg, len);
      
      // Send via SimpleSend to next hop
      if (call SimpleSend.send(sendPack, nextHop) == SUCCESS) {
         dbg(TRANSPORT_CHANNEL, "sendSegment: sent successfully\n");
         return SUCCESS;
      }
      
      dbg(TRANSPORT_CHANNEL, "sendSegment: SimpleSend.send failed\n");
      return FAIL;
   }

   
   command socket_t Transport.socket() {
      socket_t fd;
      socket_cb_t *s;

      fd = allocSocket();
      if (fd == NULL_SOCKET) {
         return NULL_SOCKET;
      }

      s = &sockets[fd];
      s->state = TCP_STATE_CLOSED;
      s->localAddr = TOS_NODE_ID;
      s->localPort = 0;
      s->remoteAddr = 0;
      s->remotePort = 0;
      s->isServer = FALSE;
      s->pendingAccept = FALSE;

      dbg(TRANSPORT_CHANNEL, "socket(): allocated fd=%hhu\n", fd);
      return fd;
   }

   command error_t Transport.bind(socket_t fd, socket_addr_t *addr) {
      socket_cb_t *s;
      uint8_t i;

      if (fd >= MAX_SOCKETS || !sockets[fd].inUse) {
         return FAIL;
      }

      s = &sockets[fd];
      if (s->state != TCP_STATE_CLOSED) {
         return FAIL;
      }

      s->localAddr = addr->addr;
      s->localPort = addr->port;

      // Ensure no other socket uses the same (localAddr, localPort)
      for (i = 0; i < MAX_SOCKETS; i++) {
         if (i == fd) {
            continue;
         }
         if (sockets[i].inUse &&
             sockets[i].localAddr == s->localAddr &&
             sockets[i].localPort == s->localPort) {
            return FAIL;
         }
      }

      dbg(TRANSPORT_CHANNEL, "bind(): fd=%hhu addr=%hu port=%hu\n",
          fd, s->localAddr, s->localPort);
      return SUCCESS;
   }

   command error_t Transport.connect(socket_t fd, socket_addr_t *addr) {
      socket_cb_t *s;

      if (fd >= MAX_SOCKETS || !sockets[fd].inUse) {
         return FAIL;
      }

      s = &sockets[fd];
      if (s->state != TCP_STATE_CLOSED) {
         return FAIL;
      }
      if (s->localPort == 0) {
         // Must be bound before connect
         return FAIL;
      }

      s->remoteAddr = addr->addr;
      s->remotePort = addr->port;

      if (startClientHandshake(fd, s->remoteAddr, s->remotePort, s->localPort) != SUCCESS) {
         return FAIL;
      }

      dbg(TRANSPORT_CHANNEL, "connect(): fd=%hhu to %hu:%hu\n",
          fd, s->remoteAddr, s->remotePort);
      return SUCCESS;
   }

   command error_t Transport.listen(socket_t fd) {
      socket_cb_t *s;

      if (fd >= MAX_SOCKETS || !sockets[fd].inUse) {
         return FAIL;
      }

      s = &sockets[fd];
      if (s->state != TCP_STATE_CLOSED) {
         return FAIL;
      }
      if (s->localPort == 0) {
         // Must be bound to a port
         return FAIL;
      }

      s->state = TCP_STATE_LISTEN;
      dbg(TRANSPORT_CHANNEL, "listen(): fd=%hhu on port=%hu\n", fd, s->localPort);
      return SUCCESS;
   }

   command socket_t Transport.accept(socket_t fd) {
      socket_cb_t *ls;
      uint16_t listenPort;
      uint8_t i;
      socket_cb_t *s;

      if (fd >= MAX_SOCKETS || !sockets[fd].inUse) {
         return NULL_SOCKET;
      }

      ls = &sockets[fd];
      if (ls->state != TCP_STATE_LISTEN) {
         return NULL_SOCKET;
      }

      listenPort = ls->localPort;

      for (i = 0; i < MAX_SOCKETS; i++) {
         s = &sockets[i];
         if (!s->inUse) {
            continue;
         }
         if (!s->isServer) {
            continue;
         }
         if (!s->pendingAccept) {
            continue;
         }
         if (s->state != TCP_STATE_ESTABLISHED) {
            continue;
         }
         if (s->localPort != listenPort) {
            continue;
         }

         s->pendingAccept = FALSE;
         dbg(TRANSPORT_CHANNEL, "accept(): listenFd=%hhu returning newFd=%hhu\n", fd, i);
         return (socket_t)i;
      }

      return NULL_SOCKET;
   }

   command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t bufflen) {
      socket_cb_t *s;
      uint32_t used;
      uint16_t freeSpace;
      uint16_t toCopy;
      uint32_t startIndex;
      uint16_t firstChunk;
      uint16_t spaceToEnd;
      uint16_t secondChunk;

      // Validate socket
      if (fd >= MAX_SOCKETS || !sockets[fd].inUse) {
         return 0;
      }

      s = &sockets[fd];

      // Only allow writes on connected or closing connections
      if (s->state != TCP_STATE_ESTABLISHED &&
          s->state != TCP_STATE_SYN_SENT &&
          s->state != TCP_STATE_CLOSE_WAIT) {
         return 0;
      }

      // Bytes currently buffered but not yet ACKed
      used = s->lastByteWritten - s->lastByteAcked;
      if (used >= SEND_BUF_SIZE) {
         // No space in send buffer
         dbg(TRANSPORT_CHANNEL, "write: fd=%hhu no space (used=%lu)\n", fd, (unsigned long)used);
         return 0;
      }

      freeSpace = (uint16_t)(SEND_BUF_SIZE - used);

      toCopy = bufflen;
      if (toCopy > freeSpace) {
         toCopy = freeSpace;
      }
      // For this project, application data are 16-bit values; enforce even-length writes
      if (toCopy > 1 && (toCopy & 1)) {
         toCopy -= 1;
      }
      if (toCopy == 0) {
         return 0;
      }

      // Starting index into sendBuf for new data (0-based, circular)
      startIndex = (uint32_t)(s->lastByteWritten % SEND_BUF_SIZE);

      // Copy may wrap; split into at most two chunks
      spaceToEnd = (uint16_t)(SEND_BUF_SIZE - startIndex);
      firstChunk = toCopy;
      if (firstChunk > spaceToEnd) {
         firstChunk = spaceToEnd;
      }

      if (firstChunk > 0) {
         memcpy(&s->sendBuf[startIndex], buff, firstChunk);
      }

      secondChunk = toCopy - firstChunk;
      if (secondChunk > 0) {
         memcpy(&s->sendBuf[0], buff + firstChunk, secondChunk);
      }

      s->lastByteWritten += toCopy;

      dbg(TRANSPORT_CHANNEL,
          "write: fd=%hhu wrote=%hu used=%lu free=%hu lastWritten=%lu state=%hhu\n",
          fd, toCopy, (unsigned long)used, freeSpace, (unsigned long)s->lastByteWritten, s->state);

      // Try to send as much as window allows (will be a no-op until ESTABLISHED)
      trySendData(fd);

      return toCopy;
   }

   command uint16_t Transport.read(socket_t fd, uint8_t *buff, uint16_t bufflen) {
      socket_cb_t *s;
      uint32_t available;
      uint16_t toCopy;
      uint32_t startIndex;
      uint16_t firstChunk;
      uint16_t spaceToEnd;
      uint16_t secondChunk;
      uint16_t freeSpace;
      uint32_t nextSeqToRead;

      // Validate socket
      if (fd >= MAX_SOCKETS || !sockets[fd].inUse || sockets[fd].state != TCP_STATE_ESTABLISHED) {
         return 0;
      }

      s = &sockets[fd];

      // In-order bytes available between lastByteRead+1 and nextByteExpected-1
      // Since we use a circular buffer, available can never exceed RECV_BUF_SIZE
      available = 0;
      if (s->nextByteExpected > s->lastByteRead) {
         available = s->nextByteExpected - s->lastByteRead - 1;
      }
      
      // Clamp available to buffer size (circular buffer can only hold RECV_BUF_SIZE bytes)
      // When buffer wraps, we can only read the most recent RECV_BUF_SIZE bytes
      if (available > RECV_BUF_SIZE) {
         // Reset lastByteRead to start of current valid window
         // This ensures we only read the most recent data that's actually in the buffer
         if (s->nextByteExpected > RECV_BUF_SIZE) {
            s->lastByteRead = s->nextByteExpected - RECV_BUF_SIZE - 1;
         } else {
            s->lastByteRead = 0;
         }
         // Recompute available (now limited to what's actually in buffer)
         available = s->nextByteExpected - s->lastByteRead - 1;
         // Final clamp
         if (available > RECV_BUF_SIZE) {
            available = RECV_BUF_SIZE;
         }
      }
      
      if (available == 0) {
         return 0;
      }

      toCopy = bufflen;
      if (toCopy > available) {
         toCopy = (uint16_t)available;
      }
      // For this project, application data are 16-bit values; enforce even-length reads
      if (toCopy > 1 && (toCopy & 1)) {
         toCopy -= 1;
      }
      if (toCopy == 0) {
         return 0;
      }

      // Starting index into recvBuf (0-based, circular)
      // The next byte to read is at sequence number (lastByteRead + 1)
      // We store sequence number N at buffer index (N - 1) % RECV_BUF_SIZE
      // Compute the buffer index for the next sequence to read
      nextSeqToRead = s->lastByteRead + 1;
      // Use modulo to get the correct buffer position (handles wrap-around)
      startIndex = (nextSeqToRead - 1) % RECV_BUF_SIZE;

      // Copy may wrap; split into at most two chunks
      spaceToEnd = (uint16_t)(RECV_BUF_SIZE - startIndex);
      firstChunk = toCopy;
      if (firstChunk > spaceToEnd) {
         firstChunk = spaceToEnd;
      }

      if (firstChunk > 0) {
         memcpy(buff, &s->recvBuf[startIndex], firstChunk);
      }

      secondChunk = toCopy - firstChunk;
      if (secondChunk > 0) {
         memcpy(buff + firstChunk, &s->recvBuf[0], secondChunk);
      }

      s->lastByteRead += toCopy;

      dbg(TRANSPORT_CHANNEL,
          "read: fd=%hhu read=%hu available=%lu lastByteRead=%lu\n",
          fd, toCopy, (unsigned long)available, (unsigned long)s->lastByteRead);

      // After the application consumes data, our receive buffer has more free space.
      // Recompute advertised window and, if it changed, send a pure ACK so the peer
      // learns about the larger window and can resume sending.
      freeSpace = computeRecvFreeSpace(fd);
      if (freeSpace != s->advWindow) {
         s->advWindow = freeSpace;
         dbg(TRANSPORT_CHANNEL,
             "read: fd=%hhu sending window update ACK ack=%lu advWindow=%u\n",
             fd, (unsigned long)s->nextByteExpected, s->advWindow);
         sendSegment(
            s->remoteAddr,
            s->localPort,
            s->remotePort,
            s->sndNext,             // no new data, just ACK with current seq
            s->nextByteExpected,    // cumulative ACK
            TCP_FLAG_ACK,
            s->advWindow,
            NULL,
            0
         );
      }

      return toCopy;
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
      
      dbg(TRANSPORT_CHANNEL, "Transport.receive called, protocol=%d\n", package->protocol);
      
      // Only process TCP protocol packets
      if (package->protocol != PROTOCOL_TCP) {
         return FAIL;
      }
      
      // Cast payload to TCP segment
      seg = (tcp_segment_t *)package->payload;

      // Use sender-specified dataLen from TCP header
      dataLen = seg->header.dataLen;
      
      // Derive addresses and ports
      srcAddr = package->src;   // Remote address (sender)
      dstAddr = package->dest;  // Local address (this node)
      srcPort = seg->header.srcPort;  // Remote port
      dstPort = seg->header.dstPort;  // Local port
      
      // Extract remaining TCP header fields
      seq = seg->header.seq;
      ack = seg->header.ack;
      flags = seg->header.flags;
      advWindow = seg->header.advWindow;
      
      // Look up socket by 4-tuple (localAddr, localPort, remoteAddr, remotePort)
      fd = findSocketBy4Tuple(dstAddr, dstPort, srcAddr, srcPort);
      
      if (fd != NULL_SOCKET) {
         // Socket found - log and handle segment
         dbg(TRANSPORT_CHANNEL, "RX TCP for socket %hhu state=%hhu (local %hu:%hu, remote %hu:%hu) seq=%lu dataLen=%hhu\n", 
             fd, sockets[fd].state, dstAddr, dstPort, srcAddr, srcPort, (unsigned long)seq, dataLen);
         handleSegmentForSocket(fd, seg, dataLen);
      } else {
         // No matching socket found - check if this is a SYN for a new connection
         dbg(TRANSPORT_CHANNEL, "RX TCP with no matching socket (local %hu:%hu, remote %hu:%hu) flags=%hhu\n",
             dstAddr, dstPort, srcAddr, srcPort, flags);
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
                  // Start server sequence space at 0 as well (SYN seq=0, first data seq=1)
                  newS->iss = 0;  // Server's initial sequence number
                  newS->sndNext = newS->iss + 1;  // Next seq after SYN
                  newS->irs = seq;  // Record client's initial sequence number
                  newS->rcvNext = seq + 1;  // Expecting next byte after SYN
                  newS->advWindow = RECV_BUF_SIZE;
                  newS->isServer = TRUE;
                  newS->pendingAccept = TRUE;
                  
                  // Set state to SYN_RCVD
                  newS->state = TCP_STATE_SYN_RCVD;
                  
                  // Send SYN+ACK
                  if (sendSegment(srcAddr, dstPort, srcPort,
                                  newS->iss, newS->rcvNext, 
                                  TCP_FLAG_SYN | TCP_FLAG_ACK, newS->advWindow, NULL, 0) == SUCCESS) {
                     dbg(TRANSPORT_CHANNEL, "SYN received from %hu:%hu, SYN+ACK sent, newFd=%hhu (pendingAccept=TRUE)\n", 
                         srcAddr, srcPort, newFd);
                  } else {
                     // Failed to send SYN+ACK, free the socket
                     freeSocket(newFd);
                     dbg(TRANSPORT_CHANNEL, "Failed to send SYN+ACK, freeing socket %hhu\n", newFd);
                  }
               } else {
                  dbg(TRANSPORT_CHANNEL, "No free socket available for new connection\n");
               }
            } else {
               // No listening socket on this port
               dbg(TRANSPORT_CHANNEL, "SYN received but no listening socket on port %hu\n", dstPort);
            }
         } else {
            // Not a SYN and no matching socket - drop it
            dbg(TRANSPORT_CHANNEL, "RX TCP with no matching socket (local %hu:%hu, remote %hu:%hu)\n", 
                dstAddr, dstPort, srcAddr, srcPort);
         }
      }
      
      return SUCCESS;
   }

   command error_t Transport.close(socket_t fd) {
      socket_cb_t *s;
      if (fd >= MAX_SOCKETS || !sockets[fd].inUse) {
         return FAIL;
      }

      s = &sockets[fd];

      dbg(TRANSPORT_CHANNEL, "close(): fd=%hhu state=%hhu local=%hu:%hu remote=%hu:%hu\n",
          fd, s->state, s->localAddr, s->localPort, s->remoteAddr, s->remotePort);

      switch (s->state) {
         case TCP_STATE_ESTABLISHED:
            dbg(TRANSPORT_CHANNEL, "close(): active close fd=%hhu\n", fd);
            trySendData(fd);
            if (sendFin(fd) == SUCCESS) {
               s->state = TCP_STATE_FIN_WAIT_1;
               return SUCCESS;
            }
            freeSocket(fd);
            return FAIL;

         case TCP_STATE_CLOSE_WAIT:
            dbg(TRANSPORT_CHANNEL, "close(): passive close fd=%hhu\n", fd);
            if (sendFin(fd) == SUCCESS) {
               s->state = TCP_STATE_LAST_ACK;
               return SUCCESS;
            }
            freeSocket(fd);
            return FAIL;

         default:
            dbg(TRANSPORT_CHANNEL, "close(): hard close fd=%hhu state=%hhu\n", fd, s->state);
            freeSocket(fd);
            return SUCCESS;
      }
   }

   command error_t Transport.release(socket_t fd) {
      // Hard close connection
      return FAIL;
   }
   

   // Testing TCP infra
   event void Boot.booted() {
      dbg(TRANSPORT_CHANNEL, "Transport booted\n");
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

      // Clean up TIME_WAIT sockets
      for (i = 0; i < MAX_SOCKETS; i++) {
         socket_cb_t *ts = &sockets[i];
         if (!ts->inUse) {
            continue;
         }
         if (ts->state == TCP_STATE_TIME_WAIT &&
             ts->timeWaitStart > 0 &&
             (now - ts->timeWaitStart) >= TCP_TIME_WAIT) {
            dbg(TRANSPORT_CHANNEL, "TIME_WAIT expired: fd=%hhu closing\n", i);
            freeSocket(i);
         }
      }

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
         scheduleRetransTimer();
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

      if (!s->inUse) {
         entry->inUse = FALSE;
         scheduleRetransTimer();
         return;
      }

      switch (s->state) {
         case TCP_STATE_ESTABLISHED:
         case TCP_STATE_FIN_WAIT_1:
         case TCP_STATE_FIN_WAIT_2:
         case TCP_STATE_CLOSE_WAIT:
         case TCP_STATE_LAST_ACK:
            break;
         default:
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

      dbg(TRANSPORT_CHANNEL, "Timeout on fd=%hhu seqStart=%lu, retransmitting unACKed data\n",
          entry->fd, (unsigned long)entry->seqStart);

      // Tahoe-style multiplicative decrease on congestion window for this timeout
      if (s->cwnd > TCP_MSS) {
         uint16_t newSsthresh = s->cwnd / 2;
         if (newSsthresh < TCP_MSS) {
            newSsthresh = TCP_MSS;
         }
         s->ssthresh = newSsthresh;
      }
      s->cwnd = TCP_MSS;
      dbg(TRANSPORT_CHANNEL, "CC: timeout fd=%hhu, ssthresh=%hu, cwnd reset to %hu\n",
          entry->fd, s->ssthresh, s->cwnd);

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
      dbg(TRANSPORT_CHANNEL, "Timer fired, calling sendSegment\n");
      // Send to node 2 (direct neighbor) for routing to work immediately
      sendSegment(2, 1234, 5678, 0, 0, TCP_FLAG_SYN, 100, NULL, 0);
   }
}


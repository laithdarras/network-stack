#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/socket.h"
#include "../../includes/protocol.h"
#include "../interfaces/Transport.nc"

module TransportP {
   provides interface Transport;
   uses interface LinkState;
   uses interface SimpleSend;
}
// TCP HEADER STRUCTURE
typedef nx_struct tcp_header_t {
   nx_uint16_t srcPort;
   nx_uint16_t destPort;
   nx_uint32_t seq;
   nx_uint32_t ack;
   nx_uint8_t  flags;
   nx_uint16_t window;
   nx_uint8_t  length;
   nx_uint8_t  data[0];
}
implementation {

   // Socket storage array - one per connection
   socket_store_t sockets[MAX_NUM_OF_SOCKETS];
   uint8_t socketCount = 0;

   
   command socket_t Transport.socket() {
    uint8_t i;
    // Find a free socket entry
    for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
        if ((sockets[i].flag & SOCKET_FLAG_INUSE) == 0) {
            // Mark this slot as used
            sockets[i].flag  |= SOCKET_FLAG_INUSE;
            sockets[i].state  = CLOSED;

            // Initialize addressing info
            sockets[i].src        = 0;            // local port will be set in bind()
            sockets[i].dest.port  = 0;
            sockets[i].dest.addr  = 0;

            // Initialize sender side pointers
            sockets[i].lastWritten = 0;
            sockets[i].lastAck     = 0;
            sockets[i].lastSent    = 0;

            // Initialize receiver side pointers
            sockets[i].lastRead     = 0;
            sockets[i].lastRcvd     = 0;
            sockets[i].nextExpected = 0;

            // Default RTT (can tune this later)
            sockets[i].RTT = 1000;               // e.g., some conservative default in ticks
            sockets[i].effectiveWindow = SOCKET_BUFFER_SIZE;

            // (Optional but nice) clear buffers
            {
                uint8_t j;
                for (j = 0; j < SOCKET_BUFFER_SIZE; j++) {
                    sockets[i].sendBuff[j] = 0;
                    sockets[i].rcvdBuff[j] = 0;
                }
            }

            // fd is just the index into sockets[]
            return (socket_t)i;
        }
    }

    // No free sockets available
    // Pick an invalid fd (bigger than any valid index)
    return (socket_t)255;  // or define a NULL_SOCKET enum = 255   }

   command error_t Transport.bind(socket_t fd, socket_addr_t *addr) {
      // Basic fd safety
      if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;
      if ((sockets[fd].flag & SOCKET_FLAG_INUSE) == 0) return FAIL;

      // Port already in use?
      for (uint8_t i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
         if (i != fd &&
               (sockets[i].flag & SOCKET_FLAG_INUSE) &&
               sockets[i].src == addr->port)
         {
               return FAIL;  // port collision
         }
      }

      // Bind the socket  
      sockets[fd].src       = addr->port;    // local port
      sockets[fd].dest.addr = ROOT_SOCKET_ADDR; // no remote yet
      sockets[fd].dest.port = ROOT_SOCKET_PORT;

      // Bound sockets remain CLOSED until connect() or listen()
      sockets[fd].state = CLOSED;

      return SUCCESS;
   }

   command error_t Transport.connect(socket_t fd, socket_addr_t *addr) {
      if (fd >= MAX_NUM_OF_SOCKETS) {
         return FAIL;
      }

      socket_store_t *s = &sockets[fd];

      // Must be allocated
      if ((s->flag & SOCKET_FLAG_INUSE) == 0) {
         return FAIL;
      }

      // Must be bound to a local port before connect()
      if (s->src == 0) {          // not bound
         return FAIL;
      }

      // Only connect from CLOSED
      if (s->state != CLOSED) {
         return FAIL;
      }

      // Save remote address/port
      s->dest.addr = addr->addr;
      s->dest.port = addr->port;

      // Initialize sender/receiver state for new connection
      s->lastWritten   = 0;
      s->lastSent      = 0;
      s->lastAck       = 0;
      s->lastRead      = 0;
      s->lastRcvd      = 0;
      s->nextExpected  = 0;

      // Initial advertised window: full receive buffer
      s->effectiveWindow = SOCKET_BUFFER_SIZE;
      if (s->RTT == 0) {
         s->RTT = 1000;   // some conservative default if not set yet
      }

      // --- Build SYN packet ---
      pack synPkt;
      tcp_header_t *hdr = (tcp_header_t*)synPkt.payload;

      // Fill outer packet header
      synPkt.protocol = PROTOCOL_TCP;
      synPkt.src      = TOS_NODE_ID;      // our node id
      synPkt.dest     = addr->addr;       // remote node id
      synPkt.TTL      = 10;               // or whatever your project uses

      // Fill transport header (SYN)
      hdr->srcPort = s->src;             // local port
      hdr->destPort = addr->port;        // remote port

      // For this project, seq is a byte offset in the stream.
      // Starting at 0 is fine.
      hdr->seq    = s->lastWritten;      // initial seq, typically 0
      hdr->ack    = 0;                   // no data received yet
      hdr->flags  = TCP_FLAG_SYN;
      hdr->window = s->effectiveWindow;
      hdr->length = 0;                   // SYN carries no data

      // Send SYN
      if (call SimpleSend.send(&synPkt, addr->addr) != SUCCESS) {
         return FAIL;
      }

      // Remember that we "sent" this seq; we may need it when SYN-ACK comes back
      s->lastSent = s->lastWritten;  // both 0 here, but keeps logic consistent

      // Update state to reflect that we're waiting for SYN+ACK
      s->state = SYN_SENT;

      // (Optional) start a connection timeout timer here if you have one

      return SUCCESS;
   }

   command error_t Transport.listen(socket_t fd) {
      if (fd >= MAX_NUM_OF_SOCKETS) {
         return FAIL;
      }

      socket_store_t *s = &sockets[fd];

      // Must be allocated
      if ((s->flag & SOCKET_FLAG_INUSE) == 0) {
         return FAIL;
      }

      // Must be bound to a local port before listen()
      if (s->src == 0) {          // 0 = "no port" convention
         return FAIL;
      }

      // Only allowed from CLOSED (simplified)
      if (s->state != CLOSED) {
         return FAIL;
      }

      // This socket now represents a listening server
      s->state      = LISTEN;
      s->dest.addr  = ROOT_SOCKET_ADDR;   // no specific peer yet
      s->dest.port  = ROOT_SOCKET_PORT;

      // For a listener, no RTT or window magic needed yet
      return SUCCESS;
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
      // Only process TCP protocol packets
      if (package->protocol != PROTOCOL_TCP) {
         return FAIL;
      }
      // Handle incoming TCP packets (SYN, ACK, DATA, FIN)
      return FAIL;
   }

   command error_t Transport.close(socket_t fd) {
      if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;
      if ((sockets[fd].flag & SOCKET_FLAG_INUSE) == 0) return FAIL;

      socket_store_t *s = &sockets[fd];

      switch (s->state) {

         case ESTABLISHED:
               // Build and send FIN packet here
               // hdr.flags = FLAG_FIN;
               // hdr.seq   = s->lastWritten;  // or next seq
               // SimpleSend.send( ... );

               s->state = SYN_SENT; // placeholder, replace with FIN_WAIT_1 later
               return SUCCESS;

         case CLOSE_WAIT:
               // App closed after receiving FIN from peer
               // Send FIN here too
               // Move to LAST_ACK state (if you define it)
               return SUCCESS;

         default:
               return FAIL;  // can't close in LISTEN, CLOSED, SYN_SENT, etc.
      }
   }

   command error_t Transport.release(socket_t fd) {
      if (fd >= MAX_NUM_OF_SOCKETS) return FAIL;

      socket_store_t *s = &sockets[fd];

      // If it's not in use, nothing to release
      if ((s->flag & SOCKET_FLAG_INUSE) == 0) return FAIL;

      // Clear all fields
      s->flag       = 0;
      s->state      = CLOSED;
      s->src        = 0;
      s->dest.port  = 0;
      s->dest.addr  = 0;

      s->lastWritten = 0;
      s->lastAck     = 0;
      s->lastSent    = 0;

      s->lastRead     = 0;
      s->lastRcvd     = 0;
      s->nextExpected = 0;

      s->RTT = 0;
      s->effectiveWindow = 0;

      // Clear buffers
      for (uint8_t i = 0; i < SOCKET_BUFFER_SIZE; i++) {
         s->sendBuff[i] = 0;
         s->rcvdBuff[i] = 0;
      }

      return SUCCESS;
   }
}


#include <Timer.h>
#include "../../includes/packet.h"
#include "../../includes/socket.h"
#include "../../includes/protocol.h"
#include "../../includes/Transport.h"
#include "../../includes/channels.h"

// enum STATE {
//    CLOSED,
//    LISTEN,
//    SYN_SENT,
//    SYN,RCVD
//    ESTABLISHED
// }

// // Write internal socket struct representing a TCP connection
// struct socketConnection {
//    break;
// };

module TransportP {
   provides interface Transport;
   uses interface LinkState;
   uses interface SimpleSend;
   uses interface Packet;
   uses interface Timer<TMilli> as TestTimer;
   uses interface Boot;
}

implementation {
   // Socket storage array - one per connection
   socket_store_t sockets[MAX_NUM_OF_SOCKETS];
   uint8_t socketCount = 0;

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

   error_t sendSegment(uint16_t dstAddr, uint16_t srcPort, uint16_t dstPort, 
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
      tcp_segment_t *seg;
      uint8_t totalLen;
      uint8_t dataLen;
      uint16_t srcPort;
      uint16_t dstPort;
      uint32_t seq;
      uint32_t ack;
      uint8_t flags;
      uint16_t advWindow;
      
      dbg("Project 3 - TCP", "Transport.receive called, protocol=%d\n", package->protocol);
      
      // Only process TCP protocol packets
      if (package->protocol != PROTOCOL_TCP) {
         return FAIL;
      }
      
      // Cast payload to TCP segment
      seg = (tcp_segment_t *)package->payload;
      
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
      
      // Extract TCP header fields
      srcPort = seg->header.srcPort;
      dstPort = seg->header.dstPort;
      seq = seg->header.seq;
      ack = seg->header.ack;
      flags = seg->header.flags;
      advWindow = seg->header.advWindow;
      
      // Log received TCP segment
      dbg("Project 3 - TCP", "RX TCP: srcPort=%hu dstPort=%hu seq=%lu ack=%lu flags=%hhu advWindow=%hu dataLen=%hhu\n", 
          srcPort, dstPort, seq, ack, flags, advWindow, dataLen);
      
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
      call TestTimer.startOneShot(10000);  // 10 seconds to let routing converge
   }
   
   event void TestTimer.fired() {
      dbg("Project 3 - TCP", "Timer fired, calling sendSegment\n");
      // Send to node 2 (direct neighbor) for routing to work immediately
      sendSegment(2, 1234, 5678, 0, 0, TCP_FLAG_SYN, 100, NULL, 0);
   }
}


//Transport layer header definitions for TCP-like protocol

#ifndef TRANSPORT_H
#define TRANSPORT_H

#include "packet.h"

// TCP flag constants
enum {
   TCP_FLAG_SYN = 1,
   TCP_FLAG_ACK = 2,
   TCP_FLAG_FIN = 4
};

// Maximum data payload in a TCP segment
enum {
   TCP_MAX_DATA = 40
};

// TCP header structure
typedef nx_struct tcp_header_t {
   nx_uint16_t srcPort;      // Source port
   nx_uint16_t dstPort;      // Destination port
   nx_uint32_t seq;          // First byte sequence number in this segment
   nx_uint32_t ack;          // Next expected byte from peer
   nx_uint8_t  flags;        // SYN / ACK / FIN TCP flags
   nx_uint16_t advWindow;    // Advertised window for flow control
   nx_uint8_t  dataLen;      // Number of payload bytes in this segment
} tcp_header_t;

// TCP segment structure (header + data)
typedef nx_struct tcp_segment_t {
   tcp_header_t header;
   nx_uint8_t   data[TCP_MAX_DATA];
} tcp_segment_t;

// TCP maximum segment size (MSS) based on packet payload and header size
#ifndef TCP_MSS
#define TCP_MSS (PACKET_MAX_PAYLOAD_SIZE - sizeof(tcp_header_t))
#endif
#endif
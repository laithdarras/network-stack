#include "../../includes/packet.h"
#include "../../includes/socket.h"

/**
 The Transport interface handles sockets and is a layer of abstraction
 above TCP. This will be used by the application layer to set up TCP
 packets. Internally the system will be handling syn/ack/data/fin
 Transport packets.
 */

interface Transport{
   
   // Get a socket if there is one available.
   command socket_t socket();

   // Bind a socket with an address.
   command error_t bind(socket_t fd, socket_addr_t *addr);

   // Check and connect to a socket
   command socket_t accept(socket_t fd);

   // Write to the socket from a buffer
   command uint16_t write(socket_t fd, uint8_t *buff, uint16_t bufflen);

   // This will pass the packet to handle it internally
   command error_t receive(pack* package);

   // Read from the socket and write this data to the buffer
   command uint16_t read(socket_t fd, uint8_t *buff, uint16_t bufflen);

   // Attempts a connection to an address
   command error_t connect(socket_t fd, socket_addr_t * addr);

   // Closes the socket
   command error_t close(socket_t fd);

   // Hard close (not graceful)
   command error_t release(socket_t fd);

   // Listen to the socket and wait for a connection
   command error_t listen(socket_t fd);
}

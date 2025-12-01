/**
 * @author UCM ANDES Lab
 * $Author: abeltran2 $
 * $LastChangedDate: 2014-08-31 16:06:26 -0700 (Sun, 31 Aug 2014) $
 *
 */


#include "../../includes/CommandMsg.h"
#include "../../includes/command.h"
#include "../../includes/channels.h"

module CommandHandlerP{
   provides interface CommandHandler;
   uses interface Receive;
   uses interface Pool<message_t>;
   uses interface Queue<message_t*>;
   uses interface Packet;
}

implementation{
    uint16_t testServerAddress = 0;
    uint16_t testServerPort = 0;

    uint16_t testClientAddress = 0;
    uint16_t testClientDest = 0;
    uint16_t testClientSrcPort = 0;
    uint16_t testClientDestPort = 0;
    uint16_t testClientTransfer = 0;

    uint16_t testCloseClientAddr = 0;
    uint16_t testCloseDest = 0;
    uint16_t testCloseSrcPort = 0;
    uint16_t testCloseDestPort = 0;

    static uint16_t readUint16(uint8_t *buff) {
        return ((uint16_t)buff[0] << 8) | buff[1];
    }

    task void processCommand(){
        if(! call Queue.empty()){
            CommandMsg *msg;
            uint8_t commandID;
            uint8_t* buff;
            message_t *raw_msg;
            void *payload;

            // Pop message out of queue.
            raw_msg = call Queue.dequeue();
            payload = call Packet.getPayload(raw_msg, sizeof(CommandMsg));

            // Check to see if the packet is valid.
            if(!payload){
                call Pool.put(raw_msg);
                post processCommand();
                return;
            }
            // Change it to our type.
            msg = (CommandMsg*) payload;

            // dbg(COMMAND_CHANNEL, "A Command has been Issued.\n");
            buff = (uint8_t*) msg->payload;
            commandID = msg->id;

            //Find out which command was called and call related command
            switch(commandID){
            // A ping will have the destination of the packet as the first
            // value and the string in the remainder of the payload
            case CMD_PING:
                // dbg(COMMAND_CHANNEL, "Command Type: Ping\n");
                signal CommandHandler.ping(buff[0], &buff[1]);
                break;

            case CMD_NEIGHBOR_DUMP:
                // dbg(COMMAND_CHANNEL, "Command Type: Neighbor Dump\n");
                signal CommandHandler.printNeighbors();
                break;

            case CMD_LINKSTATE_DUMP:
                // dbg(COMMAND_CHANNEL, "Command Type: Link State Dump\n");
                signal CommandHandler.printLinkState();
                break;

            case CMD_ROUTETABLE_DUMP:
                // dbg(COMMAND_CHANNEL, "Command Type: Route Table Dump\n");
                signal CommandHandler.printRouteTable();
                break;

            case CMD_TEST_CLIENT:
                dbg(COMMAND_CHANNEL, "Command Type: Test_Client\n");
                testClientAddress = readUint16(&buff[0]);
                testClientDest = readUint16(&buff[2]);
                testClientSrcPort = readUint16(&buff[4]);
                testClientDestPort = readUint16(&buff[6]);
                testClientTransfer = readUint16(&buff[8]);
                signal CommandHandler.setTestClient();
                break;

            case CMD_TEST_SERVER:
                dbg(COMMAND_CHANNEL, "Command Type: Test_Server\n");
                testServerAddress = readUint16(&buff[0]);
                testServerPort = readUint16(&buff[2]);
                signal CommandHandler.setTestServer();
                break;

            case CMD_CLOSE:
                dbg(COMMAND_CHANNEL, "Command Type: Test_Close\n");
                testCloseClientAddr = readUint16(&buff[0]);
                testCloseDest = readUint16(&buff[2]);
                testCloseSrcPort = readUint16(&buff[4]);
                testCloseDestPort = readUint16(&buff[6]);
                signal CommandHandler.setTestClose();
                break;

            default:
                dbg(COMMAND_CHANNEL, "CMD_ERROR: \"%d\" does not match any known commands.\n", msg->id);
                break;
            }
            call Pool.put(raw_msg);
        }

        if(! call Queue.empty()){
            post processCommand();
        }
    }
    event message_t* Receive.receive(message_t* raw_msg, void* payload, uint8_t len){
        if (! call Pool.empty()){
            call Queue.enqueue(raw_msg);
            post processCommand();
            return call Pool.get();
        }
        return raw_msg;
    }

    command uint16_t CommandHandler.getTestServerAddress() { return testServerAddress; }
    command uint16_t CommandHandler.getTestServerPort() { return testServerPort; }

    command uint16_t CommandHandler.getTestClientAddress() { return testClientAddress; }
    command uint16_t CommandHandler.getTestClientDest() { return testClientDest; }
    command uint16_t CommandHandler.getTestClientSrcPort() { return testClientSrcPort; }
    command uint16_t CommandHandler.getTestClientDestPort() { return testClientDestPort; }
    command uint16_t CommandHandler.getTestClientTransfer() { return testClientTransfer; }

    command uint16_t CommandHandler.getTestCloseClientAddr() { return testCloseClientAddr; }
    command uint16_t CommandHandler.getTestCloseDest() { return testCloseDest; }
    command uint16_t CommandHandler.getTestCloseSrcPort() { return testCloseSrcPort; }
    command uint16_t CommandHandler.getTestCloseDestPort() { return testCloseDestPort; }
}

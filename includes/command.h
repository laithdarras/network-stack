#ifndef COMMAND_H
#define COMMAND_H

#include "CommandMsg.h"
 
//Command ID Number
enum{
	CMD_PING = 0,
	CMD_NEIGHBOR_DUMP=1,
	CMD_LINKSTATE_DUMP=2,
	CMD_ROUTETABLE_DUMP=3,
	CMD_TEST_CLIENT=4,
	CMD_TEST_SERVER=5,
	CMD_CLOSE=7,
	CMD_KILL=6,
	CMD_ERROR=9,
	CMD_CHAT_HELLO=10,
	CMD_CHAT_MSG=11,
	CMD_CHAT_WHISPER=12,
	CMD_CHAT_LISTUSR=13
};

enum{
	CMD_LENGTH = 1,
};

// chat command payload structures
// max payload size is 25 since max packet size is 28 and subtracting 3 (header)
enum {
	CMD_CHAT_USERNAME_MAX = 12, // 12 bytes max for username
	CMD_CHAT_MSG_MAX = 25, // 28 - 3 = 25
	CMD_CHAT_WHISPER_MSG_MAX = 13  // 25 - 12 = 13 bytes maximum for whisper msg
};

typedef nx_struct {
	nx_uint8_t username[CMD_CHAT_USERNAME_MAX];
	nx_uint16_t clientPort;
} cmd_chat_hello_t;

typedef nx_struct {
	nx_uint8_t msg[CMD_CHAT_MSG_MAX];
} cmd_chat_msg_t;

typedef nx_struct {
	nx_uint8_t username[CMD_CHAT_USERNAME_MAX];
	nx_uint8_t msg[CMD_CHAT_WHISPER_MSG_MAX];
} cmd_chat_whisper_t;

#endif

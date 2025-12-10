#ifndef __CHANNELS_H__
#define __CHANNELS_H__

// These should really be const value, but the dbg command will spit out a ton
// of warnings.
char COMMAND_CHANNEL[]="command";
char GENERAL_CHANNEL[]="general";

// P1
char NEIGHBOR_CHANNEL[]="neighbor";
char FLOODING_CHANNEL[]="flooding";

// P2
char ROUTING_CHANNEL[]="routing";

// P3
char TRANSPORT_CHANNEL[]="transport";
char PROJECT3_TGEN_CHANNEL[]="Project3TGen";

// P4
char PROJECT4_CHAT_CHANNEL[]="Project4Chat";

// Personal Debugging Channels for some of the additional models implemented.
char HASHMAP_CHANNEL[]="hashmap";
#endif
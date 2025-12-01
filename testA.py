from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("tuna-melt.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("no_noise.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.TRANSPORT_CHANNEL);
    s.addChannel(s.PROJECT3_TGEN_CHANNEL);

    # After sending a ping, simulate a little to prevent collision.

    s.runTime(300);
    s.testServer(1);
    s.runTime(60);

    # Single client sending 1000 values to server at node 1, port 123
    s.testClient(4);

    # Run long enough for the server to receive and print up to ~1000 values
    s.runTime(2000);

    # Cleanly close the connection for this client (client_addr=4, dest=1, src_port=204, dest_port=123)
    s.cmdClose(4, 1, 204, 123);
    s.runTime(200);



if __name__ == '__main__':
    main()

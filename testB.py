from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("pizza.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("meyer-heavy.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.TRANSPORT_CHANNEL);
    s.addChannel(s.TRANSPORT_TEST_CHANNEL);

    # After sending a ping, simulate a little to prevent collision.

    # Give routing extra time to converge under heavy noise before starting server
    s.runTime(600);
    s.testServer(1);
    s.runTime(300);

    # Start a single client at node 13 talking to server at node 1:123
    s.testClient(13);
    s.runTime(2000);



if __name__ == '__main__':
    main()

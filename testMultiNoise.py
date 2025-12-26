from TestSim import TestSim

def main():
    s = TestSim()

    s.runTime(1)
    # Use multi-hop topology (pizza.topo has more nodes and longer paths)
    s.loadTopo("pizza.topo")
    # Use heavy noise to test FIN/close reliability under packet loss
    s.loadNoise("meyer-heavy.txt")
    s.bootAll()

    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.TRANSPORT_CHANNEL)
    s.addChannel(s.TRANSPORT_TEST_CHANNEL)

    # Give routing extra time to converge under heavy noise
    s.runTime(1200)  # Increased for heavy noise + multi-hop
    s.testServer(1)
    s.runTime(600)  # Ensure server is fully ready

    # Start two concurrent clients from different nodes
    # Client 1: node 4 -> 1:123, src_port=204 (multi-hop path)
    s.testClient(4)
    s.runTime(500)  # Delay to let first client establish connection
    
    # Client 2: node 13 -> 1:123, src_port=213 (different multi-hop path)
    s.testClient(13)

    # Run long enough for both clients to transfer data through noisy network
    s.runTime(4000)  # Increased for heavy noise

    # Close both connections cleanly (tests FIN handshake under noise)
    # Client 1: node 4 -> 1:123, src_port=204
    s.cmdClose(4, 1, 204, 123)
    s.runTime(500)  # Give time for FIN/ACK/FIN/ACK handshake under noise
    
    # Client 2: node 13 -> 1:123, src_port=213
    s.cmdClose(13, 1, 213, 123)
    s.runTime(500)  # Give time for FIN/ACK/FIN/ACK handshake under noise
    
    # Final wait to ensure all sockets are cleaned up
    s.runTime(200)

if __name__ == "__main__":
    main()


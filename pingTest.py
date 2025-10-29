from TestSim import TestSim

def main():
    s = TestSim()

    # Load network layout and noise model
    s.loadTopo("long_line.topo")
    s.loadNoise("no_noise.txt")
    s.bootAll()

    # Add logging channels
    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.ROUTING_CHANNEL)
    s.addChannel(s.FLOODING_CHANNEL)

    # Let neighbor discovery + link state run for a bit
    s.runTime(10)

    # Dump routing table for node 1
    print("\n=== ROUTING TABLE DUMP (B4 LSAs) ===")
    s.routeDMP(1)
    s.runTime(10)

    # Let LSAs propagte and recompute routes
    print("\n=== ROUTING TABLE DUMP (AFTER LSAs) ===")
    s.routeDMP(1)
    s.runTime(5)

if __name__ == '__main__':
    main()
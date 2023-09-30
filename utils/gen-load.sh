#!/bin/bash
# Generate load with Moongen
# $1: wheather to use real trace
# $2: If $1=true, the trace acceleration factor, otherwise the rate of synthetic load in mbps
# $3: NF
# $4: trace replay duration
# $5: NF framework <vpp|nfos>
# $6: benchmark type <throughput|latency>

# This script is lengthy, but moongen has an issue with Mellanox NICs and the
# stats reported is in-accurate. So we used a workaround and read stats directly
# from the kernel (for Mellanox NICs the kernel driver is still on when using DPDK)
#
# TODO: Considering drop moongen and use pktgen instead, we don't actually get
# any of its benefits here... hardware rate limiting/timestamping does not work,
# on Mellanox NICs
#
# TODO: Weird issue w/ Maglev, the generator only reaches full speed after running for
# 10 times after the NICs are first used post-reboot.

# Dirty shit...
# Hardcode most of these params for now...
if [[ $3 == "maglev" ]]; then
    # Setup for dslab4 (dedicated to maglev)
    TX_DEV1=enp129s0f0
    TX_DEV2=enp196s0f0
    RX_DEV1=enp129s0f1
    RX_DEV2=enp196s0f1
    RX_DEV=2
else
    # Setup for all other machines and other NFs
    TX_DEV1=enp129s0
    TX_DEV2=enp196s0
    RX_DEV1=enp129s0
    RX_DEV2=enp196s0
    RX_DEV=1
fi

# packet layers in synthetic traces
if [[ $3 == "bridge" ]]; then
    SYNTHETIC_LAYER=2
else
    SYNTHETIC_LAYER=3
fi

# Hardcode most of these params for now...
DURATION=$4
HEATUP_TIME=5
TRACE=$(python3 -c "print(','.join(['/home/lei/traces/caida/equinix-chicago.dirA.20160121-130000.UTC/${3}/trace' + str(x) + '.pcap' for x in range(10)]))")

# Extra args to benchmark.lua in case of nfos-maglev
MAGLEV_ARGS=""
if [[ $3 == "maglev" ]]; then
    if [[ $5 == "nfos" ]]; then
        MAGLEV_ARGS="-b 1,3 -x true"
    elif [[ $5 == "vpp" ]]; then
        # TODO: kill this ugly code: VPP maglev does not need heartbeat, set
        # heartbeat interval to 1 sec to effectively disable it.
        MAGLEV_ARGS="-b 1,3 -x true -i 1000000"
    fi
fi

# heat up
# TODO: set the right device for latency measurement
echo "Heat Up" >load-generator.log 2>&1
sudo "/opt/moon-gen/build/MoonGen" benchmark.lua $6 $SYNTHETIC_LAYER 0 $RX_DEV $MAGLEV_ARGS 11 4 1 -p 60 -d 5 -n Mellanox >>load-generator.log 2>&1

for DEV in $TX_DEV1 $TX_DEV2 $RX_DEV1 $RX_DEV2; do
    ethtool -S $DEV >/dev/null
done
INIT_TX_PKTS1=$(cat "/sys/class/net/$TX_DEV1/phy_stats/tx_packets")
INIT_TX_PKTS2=$(cat "/sys/class/net/$TX_DEV2/phy_stats/tx_packets")
INIT_RX_PKTS1=$(cat "/sys/class/net/$RX_DEV1/phy_stats/rx_packets")
INIT_RX_PKTS2=$(cat "/sys/class/net/$RX_DEV2/phy_stats/rx_packets")

INIT_TX_BYTES1=$(cat "/sys/class/net/$TX_DEV1/phy_stats/tx_bytes")
INIT_TX_BYTES2=$(cat "/sys/class/net/$TX_DEV2/phy_stats/tx_bytes")
INIT_RX_BYTES1=$(cat "/sys/class/net/$RX_DEV1/phy_stats/rx_bytes")
INIT_RX_BYTES2=$(cat "/sys/class/net/$RX_DEV2/phy_stats/rx_bytes")

# Gen load
# TODO: set rx dev to 1 for maglev
echo "Benchmark" >>load-generator.log 2>&1
if [[ $1 == "true" ]]; then
    echo "Replay $TRACE, speed: $2" >benchmark.result
    sudo "/opt/moon-gen/build/MoonGen" benchmark.lua $6 $SYNTHETIC_LAYER 0 $RX_DEV $MAGLEV_ARGS 11 4 0 -p 60 -d $DURATION -n Mellanox -c $TRACE -l $2 >>load-generator.log 2>&1
# Only bridge uses synthetic trace
else
    if [[ $3 == "bridge" ]]; then
        # default to layer 2 for bridge
        echo "Generate synthetic load at layer 2, rate: $2" >benchmark.result
        # default to 10000 flow size for bridge benchmarking
        # Use 20 cores to generate enough load (140000 mbps)

        # currently #threads affect the load generated, use 21 here
        # weird issue with 11 threads: goodput drops a lot if targeting 0.1% packet loss
        sudo "/opt/moon-gen/build/MoonGen" benchmark.lua $6 2 0 $RX_DEV 21 10000 0 -p 60 -d $DURATION -r $2 -n Mellanox >>load-generator.log 2>&1
    else
        # Synthetic traffic for antiddos
        echo "Generate synthetic for antiddos, rate: $2" >benchmark.result
        sudo "/opt/moon-gen/build/MoonGen" benchmark.lua $6 3 0 $RX_DEV 21 10000 0 -p 60 -d $DURATION -r $2 -n Mellanox -t $3 >>load-generator.log 2>&1
    fi
fi


for DEV in $TX_DEV1 $TX_DEV2 $RX_DEV1 $RX_DEV2; do
    ethtool -S $DEV >/dev/null
done
FINI_TX_PKTS1=$(cat "/sys/class/net/$TX_DEV1/phy_stats/tx_packets")
FINI_TX_PKTS2=$(cat "/sys/class/net/$TX_DEV2/phy_stats/tx_packets")
FINI_RX_PKTS1=$(cat "/sys/class/net/$RX_DEV1/phy_stats/rx_packets")
FINI_RX_PKTS2=$(cat "/sys/class/net/$RX_DEV2/phy_stats/rx_packets")

FINI_TX_BYTES1=$(cat "/sys/class/net/$TX_DEV1/phy_stats/tx_bytes")
FINI_TX_BYTES2=$(cat "/sys/class/net/$TX_DEV2/phy_stats/tx_bytes")
FINI_RX_BYTES1=$(cat "/sys/class/net/$RX_DEV1/phy_stats/rx_bytes")
FINI_RX_BYTES2=$(cat "/sys/class/net/$RX_DEV2/phy_stats/rx_bytes")


TX_PKTS1=$(python3 -c "print($FINI_TX_PKTS1 - $INIT_TX_PKTS1)")
TX_PKTS2=$(python3 -c "print($FINI_TX_PKTS2 - $INIT_TX_PKTS2)")
TX_PKTS=$(python3 -c "print($TX_PKTS1 + $TX_PKTS2)")
RX_PKTS1=$(python3 -c "print($FINI_RX_PKTS1 - $INIT_RX_PKTS1)")
RX_PKTS2=$(python3 -c "print($FINI_RX_PKTS2 - $INIT_RX_PKTS2)")
RX_PKTS=$(python3 -c "print($RX_PKTS1 + $RX_PKTS2)")

TX_BYTES1=$(python3 -c "print($FINI_TX_BYTES1 - $INIT_TX_BYTES1)")
TX_BYTES2=$(python3 -c "print($FINI_TX_BYTES2 - $INIT_TX_BYTES2)")
TX_BYTES=$(python3 -c "print($TX_BYTES1 + $TX_BYTES2)")
RX_BYTES1=$(python3 -c "print($FINI_RX_BYTES1 - $INIT_RX_BYTES1)")
RX_BYTES2=$(python3 -c "print($FINI_RX_BYTES2 - $INIT_RX_BYTES2)")
RX_BYTES=$(python3 -c "print($RX_BYTES1 + $RX_BYTES2)")

LOSS_RATE=$(python3 -c "print(($TX_PKTS - $RX_PKTS) / $TX_PKTS)")

echo "$TX_PKTS pkts sent, $RX_PKTS pkts received, loss = $LOSS_RATE" >>benchmark.result
echo "$TX_BYTES bytes sent, $RX_BYTES bytes received" >>benchmark.result


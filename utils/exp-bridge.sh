#!/bin/bash

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source $SELF_DIR/config.sh

EXP_DATE=$(date | tr ' ' '-')

sudo ~/dpdk/usertools/dpdk-devbind.py --unbind 3b:00.1 5e:00.1

rm bridge.res.$EXP_DATE.nfos
rm bridge.res.$EXP_DATE.vpp
for TARGET_LOSS in 0.001; do
    for SYS in nfos vpp; do
        for NUM_CORES in 1 2 4 8 12 16 20 23; do
            bash $NFOS_EXP_PATH/utils/measure_goodput.sh bridge $NUM_CORES $TARGET_LOSS $SYS 4194304 120 150 140000 >> bridge.res.$EXP_DATE.$SYS 2>&1
        done

        input=bridge.res.$EXP_DATE.$SYS
        output=$OUTPUT_DIR/throughput/bridge.$SYS
        grep Result $input | cut -d' ' -f3 | paste -d' ' $SELF_DIR/cores - > temp
        mv temp $input
        install -D $input $output
        chmod a-x $output 
    done
done

#!/bin/bash

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source $SELF_DIR/config.sh

EXP_DATE=$(date | tr ' ' '-')
sudo ~/dpdk/usertools/dpdk-devbind.py --unbind 3b:00.1 5e:00.1

for TARGET_LOSS in 0.001; do
    for SS in 0 3000000000; do
	    sed -i "8s/REFRESH_INTERVAL 180000000000/REFRESH_INTERVAL $SS/g" $NFOS_PATH/nf/bridge/bridge_config.h
        for NUM_CORES in 1 2 4 8 12 16 20 23; do
            bash $NFOS_EXP_PATH/utils/measure_goodput.sh bridge $NUM_CORES $TARGET_LOSS nfos 4194304 120 150 140000 >> bridge.res.$EXP_DATE.nfos.$SS 2>&1
        done
	    sed -i "8s/REFRESH_INTERVAL $SS/REFRESH_INTERVAL 180000000000/g" $NFOS_PATH/nf/bridge/bridge_config.h

        input=bridge.res.$EXP_DATE.nfos.$SS
        if [[ $SS == 0 ]]; then
            output=$OUTPUT_DIR/improve-scalability/bridge.0s
        else
            output=$OUTPUT_DIR/improve-scalability/bridge.1s
        fi
        grep Result $input | cut -d' ' -f3 | paste -d' ' $SELF_DIR/cores - > temp
        mv temp $input
        install -D $input $output
        chmod a-x $output 

    done
done



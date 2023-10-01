#!/bin/bash

set -e

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source $SELF_DIR/config.sh

EXP_DATE=$(date | tr ' ' '-')

sudo ${HOME}/dpdk/usertools/dpdk-devbind.py --bind=uio_pci_generic 3b:00.0 3b:00.1 5e:00.1 5e:00.0

for TARGET_LOSS in 0.001; do
    for SYS in nfos; do
        for NUM_CORES in 1 2 4 8 12 16 20 23; do
            bash $NFOS_EXP_PATH/utils/measure_goodput.sh maglev $NUM_CORES $TARGET_LOSS $SYS 5800000 72 120 72 >> maglev.res.$EXP_DATE.$SYS 2>&1
        done
    done
    for SYS in vpp; do
        for NUM_CORES in 1 2 4 8 12 16 20 23; do
            bash $NFOS_EXP_PATH/utils/measure_goodput.sh maglev $NUM_CORES $TARGET_LOSS $SYS 1450000 72 120 72 >> maglev.res.$EXP_DATE.$SYS 2>&1
        done
    done

    for SYS in nfos vpp; do
        input=maglev.res.$EXP_DATE.$SYS
        output=$OUTPUT_DIR/throughput/maglev.$SYS
        grep Result $input | cut -d' ' -f3 | paste -d' ' $SELF_DIR/cores - > temp
        mv temp $input
        install -D $input $output
        chmod a-x $output 
    done
done

#!/bin/bash

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source $SELF_DIR/config.sh

EXP_DATE=$(date | tr ' ' '-')

sudo ~/dpdk/usertools/dpdk-devbind.py --unbind 3b:00.1 5e:00.1
NF=fw
rm $NF.res.$EXP_DATE.nfos
for TARGET_LOSS in 0.001; do
    for SYS in nfos; do
    	for NUM_CORES in 1 2 4 8 12 16 20 23; do
            bash $NFOS_EXP_PATH/utils/measure_goodput.sh $NF $NUM_CORES $TARGET_LOSS $SYS 8388608 48 120 48 >> $NF.res.$EXP_DATE.$SYS 2>&1
    	done

        input=$NF.res.$EXP_DATE.$SYS
        output=$OUTPUT_DIR/throughput/$NF.$SYS
        grep Result $input | cut -d' ' -f3 | paste -d' ' $SELF_DIR/cores - > temp
        mv temp $input
        install -D $input $output
        chmod a-x $output 
    done
done

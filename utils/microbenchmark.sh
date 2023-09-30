#!/bin/bash

SELF_DIR=$(dirname "${BASH_SOURCE[0]}")
source $SELF_DIR/config.sh

EXP_DATE=$(date | tr ' ' '-')
NF="dummy"
SYS="nfos"

sudo ~/dpdk/usertools/dpdk-devbind.py --unbind 3b:00.1 5e:00.1

for FREQ in READ_ONLY WRITE_PER_PACKET; do
    for ZIPF in 0 0.99; do
        sed -i "13s/#define READ_ONLY/#define $FREQ/g" $NFOS_PATH/nf/dummy/dummy_config.h
        sed -i "11s/#define DATA_ZIPF_FACTOR 0/#define DATA_ZIPF_FACTOR $ZIPF/g" $NFOS_PATH/nf/dummy/dummy_config.h
        for TARGET_LOSS in 0.001; do
        	for NUM_CORES in 1 2 4 8 12 16 20 23; do
                bash $NFOS_EXP_PATH/utils/measure_goodput.sh $NF $NUM_CORES $TARGET_LOSS $SYS 8388608 48 120 48 >> $NF.res.$EXP_DATE.$SYS.$FREQ.$ZIPF 2>&1
        	done
        done
        pushd $NFOS_PATH
            git reset --hard
        popd

        input=$NF.res.$EXP_DATE.$SYS.$FREQ.$ZIPF
        output=$OUTPUT_DIR/microbenchmark/$FREQ-zipf${ZIPF}
        grep Result $input | cut -d' ' -f3 | paste -d' ' $SELF_DIR/cores - > temp
        mv temp $input
        install -D $input $output
        chmod a-x $output 
    done
done

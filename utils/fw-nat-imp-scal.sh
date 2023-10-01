#!/bin/bash

set -e

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source $SELF_DIR/config.sh
trap 'pushd $NFOS_PATH; git reset --hard; popd' EXIT

EXP_DATE=$(date | tr ' ' '-')
sudo ~/dpdk/usertools/dpdk-devbind.py --unbind 3b:00.1 5e:00.1

for TARGET_LOSS in 0.001; do
	for IP in 53 55 57; do
		sed -i "5s/NUM_EXTERNAL_ADDRS 57/NUM_EXTERNAL_ADDRS $IP/g" $NFOS_PATH/nf/fw-nat/nat_config.h
        for NUM_CORES in 1 2 4 8 12 16 20 23; do
            bash $NFOS_EXP_PATH/utils/measure_goodput.sh fw-nat $NUM_CORES $TARGET_LOSS nfos 8388608 900 45 45 >> fw-nat.res.$EXP_DATE.nfos.$IP 2>&1
        done
		sed -i "5s/NUM_EXTERNAL_ADDRS $IP/NUM_EXTERNAL_ADDRS 57/g" $NFOS_PATH/nf/fw-nat/nat_config.h

        input=fw-nat.res.$EXP_DATE.nfos.$IP
        output=$OUTPUT_DIR/improve-scalability/fw-nat.${IP}ip
        grep Result $input | cut -d' ' -f3 | paste -d' ' $SELF_DIR/cores - > temp
        mv temp $input
        install -D $input $output
        chmod a-x $output 
    done
done

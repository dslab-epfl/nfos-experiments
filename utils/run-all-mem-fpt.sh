#!/bin/bash

SELF_DIR=$(dirname "${BASH_SOURCE[0]}")
source $SELF_DIR/config.sh

if [[ $(hostname) == icdslab8 ]]; then
    for NF in maglev; do
        python3 $SELF_DIR/mem_nf.py -s nfos -f $NF
        input=$NF.mem.nfos
        output=$OUTPUT_DIR/mem-footprint/$NF.mem
        install -D $input $output
        chmod a-x $output 
    done
else
    for NF in ei-nat bridge fw; do
        python3 $SELF_DIR/mem_nf.py -s nfos -f $NF
        input=$NF.mem.nfos
        output=$OUTPUT_DIR/mem-footprint/$NF.mem
        install -D $input $output
        chmod a-x $output 
    done
fi

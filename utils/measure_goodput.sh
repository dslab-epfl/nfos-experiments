#!/bin/bash
# Measure the goodput (maximum offered load with less than 0.1% packet loss).
# $1: number of cores to use
# $2: the NF to benchmark, use the NF directory names under nfos/nf/
# $3: target loss
# $4: Framework (vpp|nfos)

SELF_DIR=$(dirname "${BASH_SOURCE[0]}")
source $SELF_DIR/config.sh

function search_goodput {
    # upper_bound trace acceleration factor, change it for different traces
    local upper_bound=$8
    local lower_bound=0
    local rate=$upper_bound
    local best_rate=$lower_bound
    local best_sent=0
    local best_loss="NaN"

    local NF=$1
    local NUM_CORES=$2
    local target_loss=$3
    local FRAMEWORK=$4
    local MAX_NUM_SESSIONS=$5
    local SESSION_TIMEOUT=$6
    local TRACE_DURATION=$7

    # Perform a binary search to find the goodput
    for iter in {1..10}; do
        local exp_res
        while true; do
            bash $NFOS_EXP_PATH/utils/bench-${FRAMEWORK}-nf.sh $NF $NUM_CORES $MAX_NUM_SESSIONS $SESSION_TIMEOUT $rate $TRACE_DURATION throughput
            exp_res=$(grep failed benchmark.result)
            if [[ $exp_res == "" ]]; then
                break
            fi
            echo "failed!!!"
        done

        local loss=$(grep loss benchmark.result | cut -d ' ' -f9)

        local sent=$(grep pkts benchmark.result | cut -d ' ' -f1)
        local recv=$(grep pkts benchmark.result | cut -d ' ' -f4)

        echo "Trace aceleration factor: $rate #Pkts sent: $sent #Pkts received: $recv Loss rate: $loss"

        if [[ $(python3 -c "print($loss <= $target_loss)") == "True" ]]; then
            best_rate=$rate
            best_sent=$sent
            best_loss=$loss
            lower_bound=$rate
        else
            upper_bound=$rate
        fi
        rate=$(python3 -c "print(($upper_bound + $lower_bound)/2)")

        if [[ $(python3 -c "print($loss < $target_loss)") == "True" ]]; then
            if [[ $best_rate == $upper_bound ]]; then
                break
            fi
        fi

    done

    local goodput_mpps
    if [[ $NF == "bridge" || $NF == "antiddos" ]]; then
        goodput_mpps=$(python3 -c "print($best_sent / $TRACE_DURATION / 1000 / 1000)")
    else
        goodput_mpps=$(python3 -c "print($best_sent * $best_rate / $TRACE_DURATION / 1000 / 1000)")
    fi

    echo "Result: Goodput: ${goodput_mpps} mpps. Loss: ${best_loss}. Trace acceleration factor: $best_rate"
}

NF=$1
NUM_CORES=$2
TARGET_LOSS=$3
FRAMEWORK=$4
MAX_NUM_SESSIONS=$5
SESSION_TIMEOUT=$6
TRACE_DURATION=$7
MAX_TRACE_SPEED=$8

echo "#cores: $NUM_CORES"
echo "this script takes a couple of minutes to run..."
search_goodput $NF $NUM_CORES $TARGET_LOSS $FRAMEWORK $MAX_NUM_SESSIONS $SESSION_TIMEOUT $TRACE_DURATION $MAX_TRACE_SPEED

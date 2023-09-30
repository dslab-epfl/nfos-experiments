#!/bin/bash
# Script for a single benchmark run
# Make sure you put nfos under $HOME
#
# benchmark result saved in benchmark.result
# logs of NF and load generator saved in middlebox.log & load-generator.log, respectively.
# All these files saved in the respective NF directory
#

SELF_DIR=$(dirname "${BASH_SOURCE[0]}")
source $SELF_DIR/config.sh
NF=$1
NUM_CORES=$2

## configs
if [[ $NF == "bridge" || $NF == "antiddos" ]]; then
    REAL_TRACE=false
else
    REAL_TRACE=true
fi
MAX_NUM_SESSIONS=$3
# In trace time scale if using real trace
SESSION_REAL_TIMEOUT=$4
TRACE_SPEED=$5
if [[ $REAL_TRACE == "true" ]]; then
    if [[ $NF == "ei-nat" || $NF == "fw-nat" ]]; then
        SESSION_TIMEOUT=$(python3 -c "print($SESSION_REAL_TIMEOUT / $TRACE_SPEED)")
    else
        SESSION_TIMEOUT=$(python3 -c "print(int($SESSION_REAL_TIMEOUT / $TRACE_SPEED))")
    fi
else
    SESSION_TIMEOUT=$SESSION_REAL_TIMEOUT
fi
# In trace time scale if using real trace
REAL_DURATION=$6
if [[ $REAL_TRACE == "true" ]]; then
    DURATION=$(python3 -c "print($REAL_DURATION / $TRACE_SPEED)")
else
    DURATION=$REAL_DURATION
fi

if [[ $7 == "profile" ]]; then
    BENCH_PROFILE="yes"   
    BENCH_TYPE="throughput"
else
    BENCH_PROFILE="no"
    BENCH_TYPE=$7
fi

scp "$NFOS_EXP_PATH/utils/gen-load.sh" "$TESTER_HOST:~/" >/dev/null 2>&1
scp "$NFOS_EXP_PATH/utils/benchmark.lua" "$TESTER_HOST:~/" >/dev/null 2>&1

# debug
# echo $TRACE_SPEED
# echo $SESSION_TIMEOUT
# echo $DURATION
# echo $MAX_NUM_SESSIONS
if [[ $BENCH_PROFILE == "yes" ]]; then
    NF_EXE_CMD="run-scal-profile"
else
    NF_EXE_CMD="run"
fi
pushd "$NFOS_PATH/nf/$NF"
    make $NF_EXE_CMD EXP_TIME=$(python3 -c "print(1000000 * $SESSION_TIMEOUT)") MAX_NUM_PKT_SETS=$MAX_NUM_SESSIONS LCORES=$(python3 -c "print(','.join([str(0 + x * 2) for x in range($NUM_CORES + 1)]))") >middlebox.log 2>&1 &
popd
# wait for nf to start
sleep 7
# additional 3 secs waiting for maglev
if [[ $NF == "maglev" ]]; then
    sleep 3
fi
# additional 5 secs waiting for ei-nat or fw-nat
if [[ $NF == "ei-nat" || $NF == "fw-nat" ]]; then
    sleep 5
fi
###
##TODO: disbale tx batching for ei-nat by default!!!
###

# create pt snapshots, only in profiling mode
#sleep 3
#perf_pid=$(pgrep perf)
#sudo $NFOS_PATH/utils/intel-pt-snapshot-creator/snapshot-creator $perf_pid 0.1 &

# traffic gen
if [[ $NF == "ei-nat" || $NF == "fw-nat" || $NF == "fw" || $NF == "dummy" || $NF == "policer" ]]; then
    ssh $TESTER_HOST bash ~/gen-load.sh $REAL_TRACE $TRACE_SPEED nat $DURATION nfos $BENCH_TYPE >/dev/null 2>&1
else
    ssh $TESTER_HOST bash ~/gen-load.sh $REAL_TRACE $TRACE_SPEED $NF $DURATION nfos $BENCH_TYPE >/dev/null 2>&1
fi
# Collect rx_missed_errors from vpp
sudo killall -SIGTERM nf
# TODO: adapt this for the case with more than two ports
# Assume only the first two device receives traffic
if [[ $BENCH_PROFILE == "yes" ]]; then
    sleep 1
fi
MISSED_DEV0=$(grep imissed $NFOS_PATH/nf/$NF/middlebox.log | head -n1 | awk '{print $2}')
if [[ $NF == "maglev" ]]; then
    MISSED_DEV1=$(grep imissed $NFOS_PATH/nf/$NF/middlebox.log | head -n3 | tail -n1 | awk '{print $2}')
else
    MISSED_DEV1=$(grep imissed $NFOS_PATH/nf/$NF/middlebox.log | head -n2 | tail -n1 | awk '{print $2}')
fi
MISSED=$(( $MISSED_DEV0 + $MISSED_DEV1 ))

# Number of pkts sent
scp "$TESTER_HOST:~/load-generator.log" . >/dev/null 2>&1
scp "$TESTER_HOST:~/benchmark.result" . >/dev/null 2>&1
SENT=$(grep pkts benchmark.result | cut -d' ' -f1)

GOOD=$(python3 -c "print(${SENT} - ${MISSED})")
if [[ $NF == "bridge" || $NF == "antiddos" || $NF == "policer" ]]; then
    GOOD=$(grep pkts benchmark.result | cut -d' ' -f4)
    MISSED=$(python3 -c "print(${SENT} - ${GOOD})")
fi
LOSS_RATE=$(python3 -c "print(${MISSED} / ${SENT})")

echo "NF: $NF #cores: $NUM_CORES real trace: $REAL_TRACE speed: $TRACE_SPEED timeout: $SESSION_TIMEOUT duration: $DURATION" >benchmark.result
if [[ $LOSS_RATE == "" ]]; then
    echo "failed" >>benchmark.result
else
    echo "$SENT pkts sent, $GOOD pkts received, loss = $LOSS_RATE" >>benchmark.result
fi

# Get the latency profile
if [[ $BENCH_TYPE == "latency" ]]; then
    scp "$TESTER_HOST:~/latency-profile" . >/dev/null 2>&1
fi

# Get the scalability profile
if [[ $BENCH_PROFILE == "yes" ]]; then
    grep Profile $NFOS_PATH/nf/$NF/middlebox.log > $NF.profile
fi

#!/bin/bash
# Run vpp NF

# Clean up upon Ctrl-C
trap 'sudo pkill -SIGTERM -x vpp_main; echo KILLED; exit 1' INT

# LOCK
exec {lock_fd}>/var/nfos-lock
flock -x "$lock_fd"

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source $SELF_DIR/config.sh

NF=$1
NUM_CORES=$2
VPP_PATH="$HOME/vpp"

## NF configs
if [[ $NF == "bridge" ]]; then
    REAL_TRACE=false
else
    REAL_TRACE=true
fi
MAX_NUM_SESSIONS=$3
# In trace time scale
SESSION_REAL_TIMEOUT=$4
TRACE_SPEED=$5

# Ignored for bridge for now
if [[ $REAL_TRACE == "true" ]]; then
    SESSION_TIMEOUT=$(python3 -c "print(int($SESSION_REAL_TIMEOUT / $TRACE_SPEED))")
else
    SESSION_TIMEOUT=$SESSION_REAL_TIMEOUT
fi

# Ignored for bridge for now
SESSION_TABLE_SIZE=$(( $MAX_NUM_SESSIONS / $NUM_CORES ))
# Round session table size to next power of two for vpp maglev, otherwise it stops working
if [[ $NF == "maglev" ]]; then
    SESSION_TABLE_SIZE=$(python3 -c "print(2**($SESSION_TABLE_SIZE - 1).bit_length())")
fi

# In trace time scale if using real trace
REAL_DURATION=$6
if [[ $REAL_TRACE == "true" ]]; then
    DURATION=$(python3 -c "print($REAL_DURATION / $TRACE_SPEED)")
else
    DURATION=$REAL_DURATION
fi

BENCH_TYPE=$7

# update VPP cmd script
#TODO: update exp time and session table size for bridge
SCRIPT=$NFOS_EXP_PATH/utils/vpp/$NF/script
CONF=$NFOS_EXP_PATH/utils/vpp/$NF/startup.conf
cp $SCRIPT ${SCRIPT}.bak
if [[ $NF == "nat" ]]; then
    sed "s/1048576/${SESSION_TABLE_SIZE}/g" $SCRIPT > vpp.tmp; cp vpp.tmp $SCRIPT
    sed "s/set nat timeout udp 24/set nat timeout udp ${SESSION_TIMEOUT}/g" $SCRIPT > vpp.tmp; cp vpp.tmp $SCRIPT
    sed "s/set nat timeout tcp-established 24/set nat timeout tcp-established ${SESSION_TIMEOUT}/g" $SCRIPT > vpp.tmp; cp vpp.tmp $SCRIPT
    sed "s/set nat timeout tcp-transitory 24/set nat timeout tcp-transitory ${SESSION_TIMEOUT}/g" $SCRIPT > vpp.tmp; cp vpp.tmp $SCRIPT
    rm vpp.tmp
elif [[ $NF == "maglev" ]]; then
    sed "s/1048576/${SESSION_TABLE_SIZE}/g" $SCRIPT > vpp.tmp; cp vpp.tmp $SCRIPT
    sed "s/lb conf timeout 36/lb conf timeout ${SESSION_TIMEOUT}/g" $SCRIPT > vpp.tmp; cp vpp.tmp $SCRIPT
    rm vpp.tmp
elif [[ $NF == "fw" ]]; then
    sed "s/set acl-plugin session timeout udp idle 24/set acl-plugin session timeout udp idle ${SESSION_TIMEOUT}/g" $SCRIPT > vpp.tmp; cp vpp.tmp $SCRIPT
    sed "s/set acl-plugin session timeout tcp idle 24/set acl-plugin session timeout tcp idle ${SESSION_TIMEOUT}/g" $SCRIPT > vpp.tmp; cp vpp.tmp $SCRIPT
    sed "s/set acl-plugin session timeout tcp transient 24/set acl-plugin session timeout tcp transient ${SESSION_TIMEOUT}/g" $SCRIPT > vpp.tmp; cp vpp.tmp $SCRIPT
    rm vpp.tmp

fi
cp $SCRIPT $HOME/vpp.script
cp ${SCRIPT}.bak $SCRIPT

# update VPP startup conf
GID=$(id -g $USER)
CORES=$(python3 -c "print(','.join([str(2 + x * 2) for x in range($NUM_CORES)]))")
cp $CONF ${CONF}.bak
sed "s/corelist-workers 10,12,14,16/corelist-workers $CORES/g" $CONF > vpp.tmp; cp vpp.tmp $CONF
sed "s/num-rx-queues 4/num-rx-queues $NUM_CORES/g" $CONF > vpp.tmp; cp vpp.tmp $CONF
sed "s/num-tx-queues 4/num-tx-queues $NUM_CORES/g" $CONF > vpp.tmp; cp vpp.tmp $CONF
sed "s/lei/$USER/g" $CONF > vpp.tmp; cp vpp.tmp $CONF
sed "s/gid 1000/gid $GID/g" $CONF > vpp.tmp; cp vpp.tmp $CONF
rm vpp.tmp
cp $CONF $HOME/vpp.startup.conf
cp ${CONF}.bak $CONF

scp "$NFOS_EXP_PATH/utils/gen-load.sh" "$TESTER_HOST:~/" >/dev/null 2>&1
scp "$NFOS_EXP_PATH/utils/benchmark.lua" "$TESTER_HOST:~/" >/dev/null 2>&1

# No profiling by default
PERF_STAT=""
# PERF_STAT="perf record -S0x80000 -e intel_pt/cyc=1/u"
#Remember to set vpp to use nodaemon when doing profiling
#PERF_STAT="perf stat --cpu=8,10 -D 12000 -A -e L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses,L1-dcache-stores,L1-dcache-store-misses,LLC-stores,LLC-store-misses,instructions,cycles"
sudo $PERF_STAT $VPP_PATH/build-root/install-vpp-native/vpp/bin/vpp -c $HOME/vpp.startup.conf >middlebox.vpp.log 2>&1 &
# wait for vpp to start
sleep 5
# additional 3 secs waiting for maglev
if [[ $NF == "maglev" ]]; then
    sleep 3
fi

# create snapshots, only in profiling mode
# sleep 3
# perf_pid=$(pgrep perf)
# echo $perf_pid
# sudo ~/nfos-exp-utils/intel-pt-snapshot-creator/snapshot-creator $perf_pid 0.1 &

# traffic gen
if [[ $NF == "fw" ]]; then
    ssh -t $TESTER_HOST bash ~/gen-load.sh $REAL_TRACE $TRACE_SPEED nat $DURATION vpp $BENCH_TYPE >/dev/null 2>&1
else
    ssh -t $TESTER_HOST bash ~/gen-load.sh $REAL_TRACE $TRACE_SPEED $NF $DURATION vpp $BENCH_TYPE >/dev/null 2>&1
fi

# Collect rx_missed_errors from vpp
if [[ $NF == "bridge" ]]; then
    MISSED_DEV0=$(echo "show hardware wan" | socat - UNIX-CONNECT:/run/vpp/cli.sock | grep rx_missed_errors | awk '{print $2}')
    MISSED_DEV1=$(echo "show hardware lan" | socat - UNIX-CONNECT:/run/vpp/cli.sock | grep rx_missed_errors | awk '{print $2}')
    if [[ $MISSED_DEV0 == "" ]]; then
        MISSED_DEV0="0"
    fi
    if [[ $MISSED_DEV1 == "" ]]; then
        MISSED_DEV1="0"
    fi
    MISSED=$(python3 -c "print($MISSED_DEV0 + $MISSED_DEV1)")
elif [[ $NF == "maglev" ]]; then
    MISSED_DEV0=$(echo "show hardware wan_one" | socat - UNIX-CONNECT:/run/vpp/cli.sock | grep rx_missed_errors | awk '{print $2}')
    MISSED_DEV1=$(echo "show hardware wan_two" | socat - UNIX-CONNECT:/run/vpp/cli.sock | grep rx_missed_errors | awk '{print $2}')
    if [[ $MISSED_DEV0 == "" ]]; then
        MISSED_DEV0="0"
    fi
    if [[ $MISSED_DEV1 == "" ]]; then
        MISSED_DEV1="0"
    fi
    MISSED=$(python3 -c "print($MISSED_DEV0 + $MISSED_DEV1)")
elif [[ $NF == "nat" ]]; then
    MISSED0=$(echo "show hardware lan" | socat - UNIX-CONNECT:/run/vpp/cli.sock | grep rx_missed_errors | awk '{print $2}')
    MISSED1=$(echo "show err"| socat - UNIX-CONNECT:/run/vpp/cli.sock| grep congestion | awk '{sum+=$1} END {print sum}')
    if [[ $MISSED0 == "" ]]; then
        MISSED0="0"
    fi
    if [[ $MISSED1 == "" ]]; then
        MISSED1="0"
    fi
    MISSED=$(python3 -c "print($MISSED0 + $MISSED1)")
elif [[ $NF == "fw" ]]; then
    MISSED0=$(echo "show hardware lan" | socat - UNIX-CONNECT:/run/vpp/cli.sock | grep rx_missed_errors | awk '{print $2}')
    MISSED1=$(echo "show err"| socat - UNIX-CONNECT:/run/vpp/cli.sock| grep "too many sessions" | awk '{sum+=$1} END {print sum}')
    if [[ $MISSED0 == "" ]]; then
        MISSED0="0"
    fi
    if [[ $MISSED1 == "" ]]; then
        MISSED1="0"
    fi
    echo "Sess Drop: $MISSED1"
    MISSED=$(python3 -c "print($MISSED0 + $MISSED1)")
else
    MISSED=$(echo "show hardware lan" | socat - UNIX-CONNECT:/run/vpp/cli.sock | grep rx_missed_errors | awk '{print $2}')
    # vpp does not report rx_missed_errors when it is 0
    if [[ $MISSED == "" ]]; then
        MISSED="0"
    fi
fi
sudo pkill -SIGTERM -x vpp_main

# Number of pkts sent
scp "$TESTER_HOST:~/load-generator.log" . >/dev/null 2>&1
scp "$TESTER_HOST:~/benchmark.result" . >/dev/null 2>&1
SENT=$(grep pkts benchmark.result | cut -d' ' -f1)

GOOD=$(python3 -c "print(${SENT} - ${MISSED})")

if [[ $NF == "bridge" ]]; then
    GOOD=$(grep pkts benchmark.result | cut -d' ' -f4)
    MISSED=$(python3 -c "print(${SENT} - ${GOOD})")
fi

LOSS_RATE=$(python3 -c "print(${MISSED} / ${SENT})")

echo "NF: $NF #cores: $NUM_CORES speed: $TRACE_SPEED timeout: $SESSION_TIMEOUT duration: $DURATION" >benchmark.result
echo "$SENT pkts sent, $GOOD pkts received, loss = $LOSS_RATE" >>benchmark.result

# Get the latency profile
if [[ $BENCH_TYPE == "latency" ]]; then
    scp "$TESTER_HOST:~/latency-profile" . >/dev/null 2>&1
fi

# UNLOCK
exec {lock_fd}>&-

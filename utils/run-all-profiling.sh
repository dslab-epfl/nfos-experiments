#!/bin/bash

SELF_DIR=$(dirname "${BASH_SOURCE[0]}")
source $SELF_DIR/config.sh

echo "Profile FW-NAT 53 IP:"
echo ""
sed -i "5s/NUM_EXTERNAL_ADDRS 57/NUM_EXTERNAL_ADDRS 53/g" $NFOS_PATH/nf/fw-nat/nat_config.h
bash $NFOS_EXP_PATH/utils/bench-nfos-nf.sh fw-nat 23 8388608 900 22.67578125 45 profile
sed -i "5s/NUM_EXTERNAL_ADDRS 53/NUM_EXTERNAL_ADDRS 57/g" $NFOS_PATH/nf/fw-nat/nat_config.h
NF=fw-nat
input=$NF.profile
output=$OUTPUT_DIR/profile/$NF.profile.53ip
install -D $input $output
chmod a-x $output 

echo ""
echo "Profile Bridge 0s refresh interval:"
echo ""
sed -i "8s/REFRESH_INTERVAL 180000000000/REFRESH_INTERVAL 0/g" $NFOS_PATH/nf/bridge/bridge_config.h
bash $NFOS_EXP_PATH/utils/bench-nfos-nf.sh bridge 23 4194304 120 11484.375 10 profile;
sed -i "8s/REFRESH_INTERVAL 0/REFRESH_INTERVAL 180000000000/g" $NFOS_PATH/nf/bridge/bridge_config.h
NF=bridge
input=$NF.profile
output=$OUTPUT_DIR/profile/$NF.profile.0s
install -D $input $output
chmod a-x $output 

echo ""
echo "Profile Bridge 1s refresh interval:"
echo ""
sed -i "8s/REFRESH_INTERVAL 180000000000/REFRESH_INTERVAL 3000000000/g" $NFOS_PATH/nf/bridge/bridge_config.h
bash $NFOS_EXP_PATH/utils/bench-nfos-nf.sh bridge 23 4194304 120 11484.375 10 profile;
sed -i "8s/REFRESH_INTERVAL 3000000000/REFRESH_INTERVAL 180000000000/g" $NFOS_PATH/nf/bridge/bridge_config.h
NF=bridge
input=$NF.profile
output=$OUTPUT_DIR/profile/$NF.profile.1s
install -D $input $output
chmod a-x $output 

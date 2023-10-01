#!/bin/bash

set -e

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source $SELF_DIR/config.sh

if [[ $(hostname) == icdslab8 ]]; then
    bash $NFOS_EXP_PATH/utils/exp-maglev.sh

    bash $NFOS_EXP_PATH/utils/run-all-mem-fpt.sh
else
    bash $NFOS_EXP_PATH/utils/exp-bridge.sh
    bash $NFOS_EXP_PATH/utils/exp-ei-nat.sh
    bash $NFOS_EXP_PATH/utils/exp-fw.sh

    bash $NFOS_EXP_PATH/utils/microbenchmark.sh

    bash $NFOS_EXP_PATH/utils/fw-nat-imp-scal.sh
    bash $NFOS_EXP_PATH/utils/bridge-imp-scal.sh

    bash $NFOS_EXP_PATH/utils/run-all-profiling.sh

    bash $NFOS_EXP_PATH/utils/run-all-mem-fpt.sh
fi

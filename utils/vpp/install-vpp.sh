#!/bin/bash
SELF_DIR=$(dirname "${BASH_SOURCE[0]}")
source $SELF_DIR/../config.sh

# Install vpp under HOME to be compatible with benchmark scripts
pushd ${HOME}
    git clone https://github.com/FDio/vpp.git --branch=stable/2101
    pushd vpp
        git apply ${NFOS_EXP_PATH}/utils/vpp/vpp-ice-16B-desc.patch
        make install-dep
        make build-release
    popd
popd


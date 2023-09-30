#!/bin/bash

# Install NFOS under HOME to be compatible with benchmark scripts
pushd ${HOME}
    git clone https://github.com/dslab-epfl/nfos.git --recurse-submodules
    pushd nfos
        bash deps/setup-deps.sh
    popd
popd

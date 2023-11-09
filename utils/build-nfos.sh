#!/bin/bash

# Install NFOS under HOME to be compatible with benchmark scripts
pushd ${HOME}
    pushd nfos
        bash deps/setup-deps.sh
    popd
popd

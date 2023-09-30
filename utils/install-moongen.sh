#!/bin/bash

# Bash "strict mode"
set -euo pipefail

SERVER=$(hostname)

if [[ ! -f moon-gen/.built ]]; then
  sudo rm -rf moon-gen

  sudo apt-get install -y build-essential cmake linux-headers-`uname -r` pciutils libnuma-dev libtbb-dev libmnl-dev

  git clone git@github.com:maximilian1064/MoonGen.git --branch=nfos-experiments --recurse-submodules moon-gen
  pushd moon-gen
    pushd libmoon/deps/dpdk
      # Temp hack for the 4-port generator server
      if [[ $SERVER == "icdslab4" ]]; then
        git apply ../../libmoon-dpdk-fix-dslab4.patch       
      else
        git apply ../../libmoon-dpdk-fix.patch
      fi
    popd
    ./build.sh --mlx5

    # Temp hack for the 4-port generator server
    if [[ $SERVER == "icdslab4" ]]; then   
      pushd libmoon
        git apply libmoon-dslab4.patch
      popd
    fi
    touch .built
  popd
fi

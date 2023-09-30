# Build dependencies

**NFOS:**

```
bash utils/build-nfos.sh

# Make sure pkg config paths are populated
. ${HOME}/.profile
```

**VPP:**

```
bash utils/vpp/install-vpp.sh
```


# Get all results

Note: in the scripts, NFOS NAT is called "ei-nat", NFOS load balancer is
called "maglev".

Run on both NF servers:
```
bash utils/run-all.sh
```

Results will be saved in $HOME/nfos-exp-results
```
$ ls -R nfos-exp-results
nfos-exp-results:
improve-scalability  mem-footprint  microbenchmark  profile  throughput

# Results for Sec 5.4, Figure 5
# First column is the number of (worker) cores, second column is the throughput in mpps
nfos-exp-results/throughput:
bridge.nfos  bridge.vpp  ei-nat.nfos  ei-nat.vpp  fw.nfos  maglev.nfos  maglev.vpp

# Results for Sec 5.3, Figure 4
# First column is the number of (worker) cores, second column is the throughput in mpps
nfos-exp-results/microbenchmark:
READ_ONLY-zipf0  READ_ONLY-zipf0.99  WRITE_PER_PACKET-zipf0  WRITE_PER_PACKET-zipf0.99

# Results for Sec 3.6 & 5.5, Figure 2 & 6 in the submission.
# First column is the number of (worker) cores, second column is the throughput in mpps
nfos-exp-results/improve-scalability:
bridge.0s  bridge.1s  fw-nat.53ip  fw-nat.55ip  fw-nat.57ip

# Results for Sec 3.6 & 5.5, Listing 3 & 4
nfos-exp-results/profile:
bridge.profile.0s  bridge.profile.1s  fw-nat.profile.53ip

# Results for Sec 5.6
# First column is the number of (worker) cores, second column is the memory footprint in MB
nfos-exp-results/mem-footprint:
bridge.mem  ei-nat.mem  fw.mem  maglev.mem
```

# Get individual results

## Throughput Scalability (Sec 5.4, Figure 5 in the submission)

Run on icdslab5.epfl.ch only:
```
bash utils/exp-bridge.sh
bash utils/exp-ei-nat.sh
bash utils/exp-fw.sh
```

Run on icdslab8.epfl.ch only:
```
bash utils/exp-maglev.sh
```

## Microbenchmark (Sec 5.3, Figure 4)

Run on icdslab5.epfl.ch only:
```
bash utils/microbenchmark.sh
```

## Improve NF scalability (Sec 3.6 & 5.5)

### NF throughput with default vs. relaxed semantics (Figure 2 & 6)

Run on icdslab5.epfl.ch only:
```
# FW-NAT (Figure 2)
bash utils/fw-nat-imp-scal.sh

# Bridge (Figure 6)
bash utils/bridge-imp-scal.sh

```

### Profiles (Listing 3 & 4)

Run on icdslab5.epfl.ch only:
```
bash utils/run-all-profiling.sh
```

## Memory footprint (Sec 5.6)

Run on both NF servers:
```
bash utils/run-all-mem-fpt.sh
```

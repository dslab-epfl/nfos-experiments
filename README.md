# Remarks

The instructions below are for the artifact version used in the artifact
evaluation process. This version corresponds to the submission of the paper and
does not include new experiments added during the camera-ready process. Check
the [NFOS GitHub repository](https://github.com/dslab-epfl/nfos) for the latest
artifact version and instructions on using it.

The experiments require specific hardware and outdated versions of device
drivers/firmware due to the MoonGen traffic generator we use. MoonGen requires a
specific type of 100Gbps NICs (ConnectX-5) and depends on a very old version of
DPDK (19.05) that requires outdated versions of NIC driver/firmware.

We expect it would be very difficult to get these specific
hardware/driver/firmware. Thus, for the purpose of artifact evaluation, we
provide servers that fulfill these requirements:

- icdslab5.epfl.ch: This server is for running NFs that
require 2 NIC ports or less. In our experiments, these
are all NFs except the load balancer.

- icdslab1.epfl.ch: This server connects with icdslab5.epfl
.ch and runs the traffic generator to send traffic to NFs
running on icdslab5.epfl.ch.

- icdslab8.epfl.ch: This server is for running NFs that
require more than 2 NIC ports. In our experiments, the
load balancer is the only NF running on it.

- icdslab4.epfl.ch: This server runs the traffic generator
that sends traffic to NFs running on icdslab8.epfl.ch.

In the rest of this instruction, we refer to servers for running NFs as “NF
servers”, and servers for running traffic generators as “tester servers”.

We are working towards porting the experiments to use a better-maintained
traffic generator such as Pktgen to avoid the hardware dependencies mentioned
above.

# Build dependencies

Do the following on the NF servers (icdslab5.epfl.ch and icdslab8.epfl.ch):

**NFOS:**

```
# Ignore this step if you already build NFOS
bash utils/build-nfos.sh

# Make sure pkg config paths are populated
. ${HOME}/.profile
```

**VPP:**

```
bash utils/vpp/install-vpp.sh
```

The tester servers (icdslab1.epfl.ch and icdslab4.epfl.ch) are already set up.

# Get all results

Note: in the scripts, NAT is called "ei-nat", load balancer is called "maglev".

Note: sometimes you need to press ctrl-C a few times to kill a running script...

Run on both NF servers:
```
bash utils/run-all.sh
```

Results will be saved in $HOME/nfos-exp-results
```
$ ls -R nfos-exp-results
nfos-exp-results:
improve-scalability  mem-footprint  microbenchmark  profile  throughput

# Results for Sec 5.3, Figure 5
# First column is the number of (worker) cores, second column is the throughput in mpps
nfos-exp-results/throughput:
bridge.nfos  bridge.vpp  ei-nat.nfos  ei-nat.vpp  fw.nfos  maglev.nfos  maglev.vpp

# Results for Sec 5.3, Figure 6(a)
# First column is the number of (worker) cores, second column is the throughput in mpps
nfos-exp-results/microbenchmark:
READ_ONLY-zipf0  READ_ONLY-zipf0.99  WRITE_PER_PACKET-zipf0  WRITE_PER_PACKET-zipf0.99

# Results for Sec 4.8 & 5.4, Figure 4 & 8 in the submission.
# First column is the number of (worker) cores, second column is the throughput in mpps
nfos-exp-results/improve-scalability:
bridge.0s  bridge.1s  fw-nat.53ip  fw-nat.55ip  fw-nat.57ip

# NF scalability profiles mentioned in Sec 4.8 & 5.4
nfos-exp-results/profile:
bridge.profile.0s  bridge.profile.1s  fw-nat.profile.53ip

# NF memory footprint results mentioned in Sec 5.3
# First column is the number of (worker) cores, second column is the memory footprint in MB
nfos-exp-results/mem-footprint:
bridge.mem  ei-nat.mem  fw.mem  maglev.mem
```

# Get individual results

## Throughput Scalability (Sec 5.3, Figure 5 in the paper)

During the camera-ready process, we added the traffic policer NF to this
experiment and changed a configuation of the NFOS NAT that increases its
throughput by 10%. Please note that the results which you get with the artifact version
here do not include these changes from the camera-ready process.

Run on icdslab5.epfl.ch only:
```
bash utils/exp-bridge.sh # This is the slowest script that takes 8-10 hours to run.
bash utils/exp-ei-nat.sh
bash utils/exp-fw.sh # This is the script to go if you want to test if the dependencies are properly set up, this takes less than 30 mins to run. 
```

Run on icdslab8.epfl.ch only:
```
bash utils/exp-maglev.sh
```

## Microbenchmark (Sec 5.3, Figure 6(a))

Run on icdslab5.epfl.ch only:
```
bash utils/microbenchmark.sh
```

## Improve NF scalability (Sec 4.8 & 5.4)

During the camera-ready process, we added the Anti-DDoS NF to this experiment.
We also replaced the FW-NAT NF with the NAT. They implement the same NAT
functionality and have the same scalability bottleneck, the only difference is
that FW-NAT also includes a synthetic firewall. Please note that the results
which you get with the artifact version here do not include these changes from
the camera-ready process.

### NF throughput with default vs. relaxed semantics (Figure 4 & 8)

Run on icdslab5.epfl.ch only:
```
# FW-NAT (Figure 8)
bash utils/fw-nat-imp-scal.sh

# Bridge (Figure 8)
bash utils/bridge-imp-scal.sh

```

### Profiles

Run on icdslab5.epfl.ch only:
```
bash utils/run-all-profiling.sh
```

## Memory footprint (Sec 5.3)

Run on both NF servers:
```
bash utils/run-all-mem-fpt.sh
```

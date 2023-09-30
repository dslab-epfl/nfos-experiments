#!/usr/bin/python3
import argparse
import subprocess
import os
import time
import multiprocessing as mp

# CORE_LIST = [1, 2, 4, 8, 12, 16, 20, 23]
CORE_LIST = [1, 23]
MAX_TRP = {
    "nfos": {
        "ei-nat": {
            1:  1.23046875,
            2:  2.548828125,
            4:  5.361328125,
            8:  10.986328125,
            12: 16.259765625,
            16: 21.884765625,
            20: 26.89453125,
            23: 30.322265625,
        },
        "bridge": {
            1:  8203.125,
            2:  16132.8125,
            4:  31718.75,
            8:  62343.75,
            12: 88593.75,
            16: 115664.0625,
            20: 126328.125,
            23: 125507.8125,
        },
        "maglev": {
            1:  2.390625,
            2:  4.640625,
            4:  9.5625,
            8:  19.125,
            12: 28.828125,
            16: 35.4375,
            20: 45.5625,
            23: 51.046875,
        },
        "fw": {
            1:  2.53125,
            2:  5.0625,
            4:  10.3125,
            8:  20.4375,
            12: 31.78125,
            16: 48,
            20: 48,
            23: 48,
        },
    },
}
# $MAX_NUM_SESSIONS $SESSION_TIMEOUT $TRACE_DURATION $MAX_TRACE_SPEED
PARAMS = {
    "ei-nat": [8388608, 900, 45, 45],
    "bridge": [4194304, 120, 150, 140000],
    "maglev": [8388608, 72, 120, 72],
    "fw": [8388608, 48, 120, 48],
}

# bash nfos-experiments/utils/bench-${FRAMEWORK}-nf.sh $NF $NUM_CORES $MAX_NUM_SESSIONS $SESSION_TIMEOUT $rate $TRACE_DURATION throughput
def run_bench(framework, nf, core_num):
    script_dir = os.path.dirname(os.path.realpath(__file__))
    bench_path = os.path.join(
        script_dir, f"bench-{framework}-nf.sh"
    )
    cmd = f"bash {bench_path} {nf} {core_num} {PARAMS[nf][0]} {PARAMS[nf][1]} {MAX_TRP[framework][nf][core_num]} {PARAMS[nf][2]} throughput"
    print(cmd)
    while True:
        subprocess.run(cmd, shell=True)
        lines = []
        with open("benchmark.result", "r") as f:
            lines = f.readlines()
        if "failed" not in ''.join(lines) and lines != []:
            loss_rate = float(lines[1].strip().split(" ")[-1])
            print(f"Loss Rate is: {loss_rate}")
            break
        else:
            print("Retry...")


def get_mem_footprint(framework, nf, core_num, pid):
    cmd = f"sudo smem"
    arg = "-t"
    if framework == "vpp":
        search_str = "vpp/build"
    else:
        search_str = "build/app/nf"
    max_pss = 0
    interval = 0.1
    while True:
        try:
            os.kill(pid, 0)
            output = subprocess.check_output([cmd, arg], shell=True)
            lines = [
                str(line, encoding="utf-8")
                for line in output.splitlines()
                if search_str in str(line, encoding="utf-8")
            ]
            pss_total = sum([int(line.split()[-2]) for line in lines])
            if pss_total > max_pss:
                max_pss = pss_total
            time.sleep(interval)
        except:
            break
    with open(f"{nf}.mem.{framework}", "a+") as f:
        f.write(f"{core_num} {max_pss / 1000}\n")


def main(args):
    for framework in args.sys:
        for nf in args.nf:
            subprocess.run(f"rm -f {nf}.mem.{framework}", shell=True)
            for core_num in CORE_LIST:
                print(f"Current task: framework: {framework} nf: {nf} #cores: {core_num}")
                bench = mp.Process(
                    target=run_bench,
                    args=(
                        framework,
                        nf,
                        core_num,
                    ),
                )
                bench.start()
                mem = mp.Process(
                    target=get_mem_footprint,
                    args=(
                        framework,
                        nf,
                        core_num,
                        bench.pid,
                    ),
                )
                mem.start()
                bench.join()
                mem.join()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-s",
        "--sys",
        help="The system to use, only support nfos fow now",
        choices=["nfos"],
        required=True,
        nargs="+",
    )
    parser.add_argument(
        "-f",
        "--nf",
        help="The nfs to measure, ei-nat, bridge, maglev or fw",
        choices=["ei-nat", "bridge", "maglev", "fw"],
        required=True,
        nargs="+",
    )
    args = parser.parse_args()
    main(args)

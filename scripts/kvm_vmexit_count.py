#!/usr/bin/env python
from __future__ import print_function
from collections import defaultdict
from time import sleep

from bcc import BPF

from exit_reason import EXIT_REASON

text = """
BPF_HASH(counts, unsigned int, u64);
BPF_HASH(counts_isa, unsigned int, u64);


TRACEPOINT_PROBE(kvm, kvm_exit) {
    u64 zero = 0, *val;
    unsigned int key = args->exit_reason;
    if (args->isa == 1){
        val = counts_isa.lookup_or_init(&key, &zero);
        (*val)++;
    }
    else {
        val = counts.lookup_or_init(&key, &zero);
        (*val)++;
    }
    return 0;
}

"""


d_isa = {} 
d = {96: "interrupt", 100: "vintr",114: "cpuid", 120: "hlt",123: "io",124: "msr", 1024: "npf"} 


def try_lookup(value, isa):
    if value in d_isa and isa:
        return d_isa[value]
    elif value in d and not isa:
        return d[value]
    return str(value)


def main():
    # load BPF program
    b = BPF(text=text)

    print("Tracing... Hit Ctrl-C to end.")
    try:
        sleep(99999999)
    except KeyboardInterrupt:
        pass
    print()

    counts = defaultdict(int)
    result = {}

    print("{:15s} {:10s} {:10s}".format("exit reason","count","ISA=1"))

    cs = b.get_table("counts_isa")
    result["counts"] = defaultdict(int)
    for k, v in cs.items():
        k, v = k.value, v.value
        print("{:10s} {:10d}".format(try_lookup(k, True),v))


    print("{:15s} {:10s} {:10s}".format("exit reason","count","ISA=0"))
    cs = b.get_table("counts")
    result["counts"] = defaultdict(int)
    for k, v in cs.items():
        k, v = k.value, v.value
        print("{:10s} {:10d}".format(try_lookup(k, False),v))


if __name__ == "__main__":
    main()


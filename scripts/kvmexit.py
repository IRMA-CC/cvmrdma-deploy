#!/usr/bin/env python3
#
# kvmexit.py
#
# Display the exit_reason and its statistics of each vm exit
# for all vcpus of all virtual machines. For example:
# $./kvmexit.py
#  PID      TID      KVM_EXIT_REASON                     COUNT
#  1273551  1273568  EXIT_REASON_MSR_WRITE               6
#  1274253  1274261  EXIT_REASON_EXTERNAL_INTERRUPT      1
#  1274253  1274261  EXIT_REASON_HLT                     12
#  ...
#
# Besides, we also allow users to specify one pid, tid(s), or one
# pid and its vcpu. See kvmexit_example.txt for more examples.
#
# @PID: each vitual machine's pid in the user space.
# @TID: the user space's thread of each vcpu of that virtual machine.
# @KVM_EXIT_REASON: the reason why the vm exits.
# @COUNT: the counts of the @KVM_EXIT_REASONS.
#
# REQUIRES: Linux 4.7+ (BPF_PROG_TYPE_TRACEPOINT support)
#
# Copyright (c) 2021 ByteDance Inc. All rights reserved.
#
# Author(s):
#   Fei Li <lifei.shirley@bytedance.com>


from __future__ import print_function
from time import sleep
from bcc import BPF
import argparse
import multiprocessing
import os
import subprocess

#
# Process Arguments
#
def valid_args_list(args):
    args_list = args.split(",")
    for arg in args_list:
        try:
            int(arg)
        except:
            raise argparse.ArgumentTypeError("must be valid integer")
    return args_list

# arguments
examples = """examples:
    ./kvmexit                              # Display kvm_exit_reason and its statistics in real-time until Ctrl-C
    ./kvmexit 5                            # Display in real-time after sleeping 5s
    ./kvmexit -p 3195281                   # Collpase all tids for pid 3195281 with exit reasons sorted in descending order
    ./kvmexit -p 3195281 20                # Collpase all tids for pid 3195281 with exit reasons sorted in descending order, and display after sleeping 20s
    ./kvmexit -p 3195281 -v 0              # Display only vcpu0 for pid 3195281, descending sort by default
    ./kvmexit -p 3195281 -a                # Display all tids for pid 3195281
    ./kvmexit -t 395490                    # Display only for tid 395490 with exit reasons sorted in descending order
    ./kvmexit -t 395490 20                 # Display only for tid 395490 with exit reasons sorted in descending order after sleeping 20s
    ./kvmexit -T '395490,395491'           # Display for a union like {395490, 395491}
"""
parser = argparse.ArgumentParser(
    description="Display kvm_exit_reason and its statistics at a timed interval",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog=examples)
parser.add_argument("duration", nargs="?", default=99999999, type=int, help="show delta for next several seconds")
parser.add_argument("-p", "--pid", type=int, help="trace this PID only")
exgroup = parser.add_mutually_exclusive_group()
exgroup.add_argument("-t", "--tid", type=int, help="trace this TID only")
exgroup.add_argument("-T", "--tids", type=valid_args_list, help="trace a comma separated series of tids with no space in between")
exgroup.add_argument("-v", "--vcpu", type=int, help="trace this vcpu only")
exgroup.add_argument("-a", "--alltids", action="store_true", help="trace all tids for this pid")
args = parser.parse_args()
duration = int(args.duration)

#
# Setup BPF
#

# load BPF program
bpf_text = """
#include <linux/delay.h>

#define REASON_NUM 76
#define REASON_ISA_NUM 0x814
#define TGID_NUM 1024

struct exit_count {
    u64 exit_ct[REASON_NUM];
    u64 exit_isa_ct[REASON_ISA_NUM];
};
BPF_PERCPU_ARRAY(init_value, struct exit_count, 1);
BPF_TABLE("percpu_hash", u64, struct exit_count, pcpu_kvm_stat, TGID_NUM);

struct cache_info {
    u64 cache_pid_tgid;
    struct exit_count cache_exit_ct;
};
BPF_PERCPU_ARRAY(pcpu_cache, struct cache_info, 1);

TRACEPOINT_PROBE(kvm, kvm_exit) {
    int cache_miss = 0;
    int zero = 0;
    u32 er = args->exit_reason;
    if (args->isa == 1) {
        er = er & 0xffff;
        if (er >= REASON_NUM) {
            return 0;
        }
    }
    if (args->isa == 0) {
        if (er & 0x80000000) {
            er = (er & 0xff) | 0x800;
        }     
        if (er >= REASON_ISA_NUM) {
            return 0;
        }
    }

    u64 cur_pid_tgid = bpf_get_current_pid_tgid();
    u32 tgid = cur_pid_tgid >> 32;
    u32 pid = cur_pid_tgid;

    if (THREAD_FILTER)
        return 0;

    struct exit_count *tmp_info = NULL, *initial = NULL;
    struct cache_info *cache_p;
    cache_p = pcpu_cache.lookup(&zero);
    if (cache_p == NULL) {
        return 0;
    }

    if (cache_p->cache_pid_tgid == cur_pid_tgid) {
        //a. If the cur_pid_tgid hit this physical cpu consecutively, save it to pcpu_cache
        tmp_info = &cache_p->cache_exit_ct;
    } else {
        //b. If another pid_tgid matches this pcpu for the last hit, OR it is the first time to hit this physical cpu.
        cache_miss = 1;

        // b.a Try to load the last cache struct if exists.
        tmp_info = pcpu_kvm_stat.lookup(&cur_pid_tgid);

        // b.b If it is the first time for the cur_pid_tgid to hit this pcpu, employ a
        // per_cpu array to initialize pcpu_kvm_stat's exit_count with each exit reason's count is zero
        if (tmp_info == NULL) {
            initial = init_value.lookup(&zero);
            if (initial == NULL) {
                return 0;
            }

            pcpu_kvm_stat.update(&cur_pid_tgid, initial);
            tmp_info = pcpu_kvm_stat.lookup(&cur_pid_tgid);
            // To pass the verifier
            if (tmp_info == NULL) {
                return 0;
            }
        }
    }

    if (args->isa == 1) {
        if (er < REASON_NUM) {
            tmp_info->exit_ct[er]++;
            if (cache_miss == 1) {
                if (cache_p->cache_pid_tgid != 0) {
                    // b.*.a Let's save the last hit cache_info into kvm_stat.
                    pcpu_kvm_stat.update(&cache_p->cache_pid_tgid, &cache_p->cache_exit_ct);
                }
                // b.* As the cur_pid_tgid meets current pcpu_cache_array for the first time, save it.
                cache_p->cache_pid_tgid = cur_pid_tgid;
                bpf_probe_read(&cache_p->cache_exit_ct, sizeof(*tmp_info), tmp_info);
            }
            return 0;
        }
        return 0;
    } 
    if (args->isa == 0) {
        if (er < REASON_ISA_NUM) {
            tmp_info->exit_isa_ct[er]++;
            if (cache_miss == 1) {
                if (cache_p->cache_pid_tgid != 0) {
                    // b.*.a Let's save the last hit cache_info into kvm_stat.
                    pcpu_kvm_stat.update(&cache_p->cache_pid_tgid, &cache_p->cache_exit_ct);
                }
                // b.* As the cur_pid_tgid meets current pcpu_cache_array for the first time, save it.
                cache_p->cache_pid_tgid = cur_pid_tgid;
                bpf_probe_read(&cache_p->cache_exit_ct, sizeof(*tmp_info), tmp_info);
            }
            return 0;
        }
        return 0;
    }

    return 0;
}
"""

# format output
exit_reasons = {
0:"EXCEPTION_NMI",
1:"EXTERNAL_INTERRUPT",
2:"TRIPLE_FAULT",
3:"INIT_SIGNAL",
4:"SIPI_SIGNAL",
7:"INTERRUPT_WINDOW",
8:"NMI_WINDOW",
9:"TASK_SWITCH",
10: "CPUID",
12: "HLT",
13: "INVD",
14: "INVLPG",
15: "RDPMC",
16: "RDTSC",
18: "VMCALL",
19: "VMCLEAR",
20: "VMLAUNCH",
21: "VMPTRLD",
22: "VMPTRST",
23: "VMREAD",
24: "VMRESUME",
25: "VMWRITE",
26: "VMOFF",
27: "VMON",
28: "CR_ACCESS",
29: "DR_ACCESS",
30: "IO_INSTRUCTION",
31: "MSR_READ",
32: "MSR_WRITE",
33: "INVALID_STATE",
34: "MSR_LOAD_FAIL",
36: "MWAIT_INSTRUCTION",
37: "MONITOR_TRAP_FLAG",
39: "MONITOR_INSTRUCTION",
40: "PAUSE_INSTRUCTION",
41: "MCE_DURING_VMENTRY",
43: "TPR_BELOW_THRESHOLD",
44: "APIC_ACCESS",
45: "EOI_INDUCED",
46: "GDTR_IDTR",
47: "LDTR_TR",
48: "EPT_VIOLATION",
49: "EPT_MISCONFIG",
50: "INVEPT",
51: "RDTSCP",
52: "PREEMPTION_TIMER",
53: "INVVPID",
54: "WBINVD",
55: "XSETBV",
56: "APIC_WRITE",
57: "RDRAND",
58: "INVPCID",
59: "VMFUNC",
60: "ENCLS",
61: "RDSEED",
62: "PML_FULL",
63: "XSAVES",
64: "XRSTORS",
67: "UMWAIT",
68: "TPAUSE",
74: "BUS_LOCK",
75: "NOTIFY"}


exit_reasons_isa = {
0x000:"read_cr0" ,
0x002:"read_cr2" ,
0x003:"read_cr3" ,
0x004:"read_cr4" ,
0x008:"read_cr8" ,
0x010:"write_cr0" ,
0x012:"write_cr2" ,
0x013:"write_cr3" ,
0x014:"write_cr4" ,
0x018:"write_cr8" ,
0x020:"read_dr0" ,
0x021:"read_dr1" ,
0x022:"read_dr2" ,
0x023:"read_dr3" ,
0x024:"read_dr4" ,
0x025:"read_dr5" ,
0x026:"read_dr6" ,
0x027:"read_dr7" ,
0x030:"write_dr0" ,
0x031:"write_dr1" ,
0x032:"write_dr2" ,
0x033:"write_dr3" ,
0x034:"write_dr4" ,
0x035:"write_dr5" ,
0x036:"write_dr6" ,
0x037:"write_dr7" ,
0x040 + 0:"DE excp" ,
0x040 + 1:"DB excp" ,
0x040 + 3:"BP excp" ,
0x040 + 4:"OF excp" ,
0x040 + 5:"BR excp" ,
0x040 + 6:"UD excp" ,
0x040 + 7:"NM excp" ,
0x040 + 8:"DF excp" ,
0x040 + 10:"TS excp" ,
0x040 + 11:"NP excp" ,
0x040 + 12:"SS excp" ,
0x040 + 13:"GP excp" ,
0x040 + 14:"PF excp" ,
0x040 + 16:"MF excp" ,
0x040 + 17:"AC excp" ,
0x040 + 18:"MC excp" ,
0x040 + 19:"XF excp" ,
0x060:"interrupt" ,
0x061:"nmi" ,
0x062:"smi" ,
0x063:"init" ,
0x064:"vintr" ,
0x065:"cr0_sel_write" ,
0x066:"read_idtr" ,
0x067:"read_gdtr" ,
0x068:"read_ldtr" ,
0x069:"read_rt" ,
0x06a:"write_idtr" ,
0x06b:"write_gdtr" ,
0x06c:"write_ldtr" ,
0x06d:"write_rt" ,
0x06e:"rdtsc" ,
0x06f:"rdpmc" ,
0x070:"pushf" ,
0x071:"popf" ,
0x072:"cpuid" ,
0x073:"rsm" ,
0x074:"iret" ,
0x075:"swint" ,
0x076:"invd" ,
0x077:"pause" ,
0x078:"hlt" ,
0x079:"invlpg" ,
0x07a:"invlpga" ,
0x07b:"io" ,
0x07c:"msr" ,
0x07d:"task_switch" ,
0x07e:"ferr_freeze" ,
0x07f:"shutdown" ,
0x080:"vmrun" ,
0x081:"hypercall" ,
0x082:"vmload" ,
0x083:"vmsave" ,
0x084:"stgi" ,
0x085:"clgi" ,
0x086:"skinit" ,
0x087:"rdtscp" ,
0x088:"icebp" ,
0x089:"wbinvd" ,
0x08a:"monitor" ,
0x08b:"mwait" ,
0x08d:"xsetbv" ,
0x08f:"write_efer_trap" ,
0x090:"write_cr0_trap" ,
0x094:"write_cr4_trap" ,
0x098:"write_cr8_trap" ,
0x0a2:"invpcid" ,
0x400:"npf" ,
0x401:"avic_incomplete_ipi" ,
0x402:"avic_unaccelerated_access" ,
0x403:"vmgexit" ,
0x801:"vmgexit_mmio_read", # 0x80000001:"vmgexit_mmio_read" ,
0x802:"vmgexit_mmio_write" ,# 0x80000002:"vmgexit_mmio_write" ,
0x803:"vmgexit_nmi_complete", # 0x80000003:"vmgexit_nmi_complete" ,
0x804:"vmgexit_ap_hlt_loop", # 0x80000004:"vmgexit_ap_hlt_loop" ,
0x805:"vmgexit_ap_jump_table",# 0x80000005:"vmgexit_ap_jump_table" ,
0x810:"vmgexit_page_state_change", # 0x80000010:"vmgexit_page_state_change" ,
0x811:"vmgexit_guest_request" , # 0x80000011:"vmgexit_guest_request" ,
0x812:"vmgexit_ext_guest_request", # 0x80000012:"vmgexit_ext_guest_request" ,
0x813:"vmgexit_ap_creation" ,
#0x8000fffd:"vmgexit_hypervisor_feature" ,
#-1:"invalid_guest_state"
}



#
# Do some checks
#
try:
    # Check if kvm module is loaded
    if os.access("/dev/kvm", os.R_OK | os.W_OK):
        pass
    else:
        raise Exception("Please insmod kvm module to use kvmexit tool.")
except Exception as e:
    raise Exception("Failed to do precondition check, due to: %s." % e)

def find_tid(tgt_dir, tgt_vcpu):
    for tid in os.listdir(tgt_dir):
        path = tgt_dir + "/" + tid + "/comm"
        fp = open(path, "r")
        comm = fp.read()
        if (comm.find(tgt_vcpu) != -1):
            return tid
    return -1

# set process/thread filter
thread_context = ""
header_format = ""
need_collapse = not args.alltids
if args.tid is not None:
    thread_context = "TID %s" % args.tid
    thread_filter = 'pid != %s' % args.tid
elif args.tids is not None:
    thread_context = "TIDS %s" % args.tids
    thread_filter = "pid != " + " && pid != ".join(args.tids)
    header_format = "TIDS     "
elif args.pid is not None:
    thread_context = "PID %s" % args.pid
    thread_filter = 'tgid != %s' % args.pid
    if args.vcpu is not None:
        thread_context = "PID %s VCPU %s" % (args.pid, args.vcpu)
        # transfer vcpu to tid
        tgt_dir = '/proc/' + str(args.pid) + '/task'
        tgt_vcpu = "CPU " + str(args.vcpu)
        args.tid = find_tid(tgt_dir, tgt_vcpu)
        if args.tid == -1:
            raise Exception("There's no v%s for PID %d." % (tgt_vcpu, args.pid))
        thread_filter = 'pid != %s' % args.tid
    elif args.alltids:
        thread_context = "PID %s and its all threads" % args.pid
        header_format = "TID      "
else:
    thread_context = "all threads"
    thread_filter = '0'
    header_format = "PID      TID      "
bpf_text = bpf_text.replace('THREAD_FILTER', thread_filter)
b = BPF(text=bpf_text)


# header
print("Display kvm exit reasons and statistics for %s" % thread_context, end="")
if duration < 99999999:
    print(" after sleeping %d secs." % duration)
else:
    print("... Hit Ctrl-C to end.")

try:
    sleep(duration)
except KeyboardInterrupt:
    print()


# Currently, sort multiple tids in descending order is not supported.
if (args.pid or args.tid):
    ct_reason = []
    if args.pid:
        tgid_exit = [0 for i in range(len(exit_reasons))]

# output
print("%s%-35s %s" % (header_format, "KVM_EXIT_REASON", "COUNT"))

pcpu_kvm_stat = b["pcpu_kvm_stat"]
pcpu_cache = b["pcpu_cache"]
for k, v in pcpu_kvm_stat.items():
    tgid = k.value >> 32
    pid = k.value & 0xffffffff
    for er_key, er_value in exit_reasons.items():
        sum1 = 0
        for inner_cpu in range(0, multiprocessing.cpu_count()):
            cachePIDTGID = pcpu_cache[0][inner_cpu].cache_pid_tgid
            # Take priority to check if it is in cache
            if cachePIDTGID == k.value:
                sum1 += pcpu_cache[0][inner_cpu].cache_exit_ct.exit_ct[er_key]
            # If not in cache, find from kvm_stat
            else:
                sum1 += v[inner_cpu].exit_ct[er_key]
        if sum1 == 0:
            continue

        if (args.pid and args.pid == tgid and need_collapse):
            tgid_exit[er_key] += sum1
        elif (args.tid and args.tid == pid):
            ct_reason.append((sum1, er_key))
        elif not need_collapse or args.tids:
            print("%-8u %-35s %-8u" % (pid, exit_reasons[er_key], sum1))
        else:
            print("%-8u %-8u %-35s %-8u" % (tgid, pid, exit_reasons[er_key], sum1))

    # Display only for the target tid in descending sort
    if (args.tid and args.tid == pid):
        ct_reason.sort(reverse=True)
        for i in range(0, len(ct_reason)):
            if ct_reason[i][0] == 0:
                continue
            print("%-35s %-8u" % (exit_reasons[ct_reason[i][1]], ct_reason[i][0]))
        break

    for er_key, er_value in exit_reasons_isa.items():
        sum1 = 0
        for inner_cpu in range(0, multiprocessing.cpu_count()):
            cachePIDTGID = pcpu_cache[0][inner_cpu].cache_pid_tgid
            # Take priority to check if it is in cache
            if cachePIDTGID == k.value:
                sum1 += pcpu_cache[0][inner_cpu].cache_exit_ct.exit_isa_ct[er_key]
            # If not in cache, find from kvm_stat
            else:
                sum1 += v[inner_cpu].exit_isa_ct[er_key]
        if sum1 == 0:
            continue

        if (args.pid and args.pid == tgid and need_collapse):
            tgid_exit[er_key] += sum1
        elif (args.tid and args.tid == pid):
            ct_reason.append((sum1, er_key))
        elif not need_collapse or args.tids:
            print("%-8u %-35s %-8u" % (pid, exit_reasons_isa[er_key], sum1))
        else:
            print("%-8u %-8u %-35s %-8u" % (tgid, pid, exit_reasons_isa[er_key], sum1))

    # Display only for the target tid in descending sort
    if (args.tid and args.tid == pid):
        ct_reason.sort(reverse=True)
        for i in range(0, len(ct_reason)):
            if ct_reason[i][0] == 0:
                continue
            print("%-35s %-8u" % (exit_reasons_isa[ct_reason[i][1]], ct_reason[i][0]))
        break


# Aggregate all tids' counts for this args.pid in descending sort
if args.pid and need_collapse:
    for i in range(0, len(exit_reasons)):
        ct_reason.append((tgid_exit[i], i))
    ct_reason.sort(reverse=True)
    for i in range(0, len(ct_reason)):
        if ct_reason[i][0] == 0:
            continue
        print("%-35s %-8u" % (exit_reasons[ct_reason[i][1]], ct_reason[i][0]))
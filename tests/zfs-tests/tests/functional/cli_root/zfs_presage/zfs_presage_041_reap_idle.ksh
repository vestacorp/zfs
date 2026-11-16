#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#
# Copyright (c) 2026, Vesta Corporation.
# Copyright (c) 2026, Todd Curry.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/cli_root/zfs_presage/zfs_presage.kshlib

#
# DESCRIPTION:
#	When the presaged state is over its limit only because of headers
#	that are held (the blocks have copies in the dbuf cache), the
#	reaper has nothing it can demote, and the ARC's eviction thread
#	must not be kept running for it.
# STRATEGY:
#	1. ARC fixed at 1 GiB, limit 50 %.  Presage a 64 MiB file and read
#	   it twice, so that the dbuf cache (32 MiB) holds copies of its
#	   blocks and their headers are held.
#	2. Set the limit to 1 % (about 10 MiB).  The reaper demotes what is
#	   listed; the held headers keep the state over the limit.
#	3. Over the next 5 s the arc_evict thread uses less than half a
#	   second of CPU.
#

verify_runnable "global"

if ! is_linux; then
	log_unsupported "reads a kernel thread's CPU time from /proc"
fi

typeset f=$TESTDIR/ri
typeset -i mib=$((1024 * 1024))

function cleanup
{
	zfs presage -t 0 $f >/dev/null 2>&1
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
	rm -f $f
}

# utime + stime, in clock ticks, summed over the kernel threads named
# arc_evict: the eviction zthr and the threads of its taskq
function evict_ticks
{
	typeset -i sum=0
	typeset pid
	for pid in $(pgrep -x arc_evict); do
		sum=$((sum + $(awk '{print $14 + $15}' /proc/$pid/stat)))
	done
	echo $sum
}

log_assert "held presaged headers over the limit do not spin arc_evict"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50

log_must file_write -o create -f $f -b 131072 -c 512 -d R
sync_pool $TESTPOOL
log_must zfs presage -t 600 $f
log_must dd if=$f of=/dev/null bs=1M
log_must dd if=$f of=/dev/null bs=1M

log_must pgrep -x arc_evict
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 1
sleep 2
typeset -i hz=$(getconf CLK_TCK)
typeset -i t0=$(evict_ticks)
sleep 5
typeset -i t1=$(evict_ticks)
typeset -i counted=$(kstat arcstats.presaged_counted)
typeset -i limit=$(($(kstat arcstats.c) / 100))
log_note "arc_evict threads used $((t1 - t0)) ticks of $((5 * hz)) in" \
    "5 s; presaged_counted $counted, limit $limit, file" \
    "$(presaged_bytes $f) presaged"
# the state must really be over its limit for the result to mean anything
log_must test $counted -gt $limit
log_must test $((t1 - t0)) -lt $((hz / 2))

log_pass "held presaged headers over the limit do not spin arc_evict"

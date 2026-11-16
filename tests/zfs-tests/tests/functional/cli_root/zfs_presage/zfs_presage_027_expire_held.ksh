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

. $STF_SUITE/tests/functional/cli_root/zfs_presage/zfs_presage.kshlib

#
# DESCRIPTION:
#	When a reservation reaches its deadline nothing of the file stays
#	counted as presaged, including the blocks the ARC reaper cannot
#	see: the indirect blocks, which cached dbufs hold from the load on.
#	Nothing looks at the file after the request.
#
# STRATEGY:
#	1. Presage a 64 MiB file on recordsize=8k (eight indirect blocks)
#	   for 6 seconds; presaged_size covers the data and more.
#	2. Wait for the deadline without touching the file or asking for
#	   its status.
#	3. Within a few seconds presaged_size is back at its starting
#	   value and the reservation is gone.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prsexpire
typeset f=/$fs/f
typeset -i mib=$((1024 * 1024))

function cleanup
{
	zfs presage -t 0 $f >/dev/null 2>&1
	datasetexists $fs && log_must zfs destroy -r $fs
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
}

log_assert "held blocks leave the presaged state at the deadline"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)

log_must zfs create -o recordsize=8k -o compression=off $fs
log_must file_write -o create -f $f -b 8192 -c 8192 -d R
sync_pool $TESTPOOL
log_must zfs presage -t 6 $f
typeset -i psize1=$(presaged_size)
log_must test $psize1 -gt $((psize0 + 64 * mib))

sleep 6
typeset -i i
for ((i = 0; i < 20; i++)); do
	[[ $(presaged_size) -le $((psize0 + 131072)) ]] && break
	sleep 0.5
done
log_note "presaged_size $psize0 at the start, $psize1 while presaged," \
    "$(presaged_size) after the deadline"
log_must test "$(presaged_size)" -le $((psize0 + 131072))
log_must test "$(kstat presage.reservations)" -eq $base

log_pass "held blocks leave the presaged state at the deadline"

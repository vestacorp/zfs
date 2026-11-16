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
#	A request with a future start that replaces an active reservation
#	ends it: what was presaged is released now and comes back when the
#	new request starts.  It is not left presaged, with no reservation
#	in force, until the old deadline.
#
# STRATEGY:
#	1. Presage a 32 MiB file for ten minutes.
#	2. Ask again for the same file to start in 8 seconds for a minute.
#	   The command reports nothing presaged and one pending; within
#	   seconds the file is not presaged and presaged_size is back at
#	   its starting value; one reservation remains, pending.
#	3. After the start time the file is presaged again.
#

verify_runnable "global"

typeset f=$TESTDIR/prs034
typeset -i mib=$((1024 * 1024))

function cleanup
{
	zfs presage -t 0 $f >/dev/null 2>&1
	rm -f $f
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

log_assert "a later-starting replacement releases the active reservation"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)

# 1. active
log_must file_write -o create -f $f -b 131072 -c 256 -d R
sync_pool $TESTPOOL
log_must zfs presage -t 600 $f
log_must test "$(presaged_bytes $f)" -eq $((32 * mib))

# 2. replaced by a request that starts later
log_must zfs presage -s +8s -t 60 $f
log_must test "$(pending_count $f)" -eq 1
log_must test "$(kstat presage.reservations)" -eq $((base + 1))
log_must test "$(presaged_bytes $f)" -eq 0
presage_wait_settled $((psize0 + 131072)) 5

# 3. it starts
typeset -i i
for ((i = 0; i < 80; i++)); do
	[[ $(presaged_bytes $f) -eq $((32 * mib)) ]] && break
	sleep 0.2
done
log_must test "$(presaged_bytes $f)" -eq $((32 * mib))
log_must test "$(pending_count $f)" -eq 0

log_must zfs presage -t 0 $f
presage_wait_clean $base

log_pass "a later-starting replacement releases the active reservation"

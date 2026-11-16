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
#	A snapshot does not disturb a presaged file.  A rollback releases
#	it: the reservation is cancelled, the blocks the restored file
#	shares with the discarded state are demoted by a walk of that file
#	only, the blocks the rollback orphaned leave when their free lands,
#	and nothing is read.  A request made after the rollback works.
#
# STRATEGY:
#	1. Presage a 32 MiB file; snapshot the filesystem; across a re-sweep
#	   the reservation, its deadline and the file's 1.000 are unchanged.
#	2. Rewrite half the file and append 8 MiB; the re-sweep covers it.
#	3. Roll back.  Within seconds: reservation count at its baseline,
#	   status shows no deadline and 0 presaged, no hold is left and
#	   presaged_size is back at its starting value; the time that took
#	   is logged.
#	4. Presage the file again: resident at its restored size; kill it.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prsroll
typeset f=/$fs/f
typeset -i mib=$((1024 * 1024)) rs=131072

function cleanup
{
	zfs presage -t 0 $f >/dev/null 2>&1
	datasetexists $fs && log_must zfs destroy -r $fs
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

log_assert "a snapshot leaves a presaged file alone; a rollback releases it"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)

# 1. a snapshot is a non-event
log_must zfs create $fs
log_must file_write -o create -f $f -b $rs -c 256 -d R
sync_pool $TESTPOOL
log_must zfs presage -t 300 $f
log_must test "$(presaged_bytes $f)" -eq $((32 * mib))
typeset -i exp0=$(expires_at $f)
log_must zfs snapshot $fs@s1
sleep 7
log_must test "$(kstat presage.reservations)" -eq $((base + 1))
log_must test "$(expires_at $f)" -eq $exp0
log_must test "$(presaged_bytes $f)" -eq $((32 * mib))

# 2. the file moves on under the snapshot
log_must dd if=/dev/urandom of=$f bs=$rs count=128 conv=notrunc
log_must file_write -o append -f $f -b $rs -c 64 -d R
sync_pool $TESTPOOL
typeset -i i
for ((i = 0; i < 50; i++)); do
	[[ $(presaged_bytes $f) -eq $((40 * mib)) ]] && break
	sleep 0.2
done
log_must test "$(presaged_bytes $f)" -eq $((40 * mib))

# 3. rollback releases
typeset t0=$(date +%s%3N)
log_must zfs rollback $fs@s1
presage_wait_clean $base
presage_wait_settled $((psize0 + mib)) 30
log_note "released $(($(date +%s%3N) - t0)) ms after the" \
    "rollback: presaged_size $(presaged_size) (start $psize0)"
log_must test "$(kstat presage.reservations)" -eq $base
log_must test "$(stat_size $f)" -eq $((32 * mib))
log_must test "$(expires_at $f)" -eq 0
log_must test "$(presaged_bytes $f)" -eq 0
log_must test "$(kstat presage.holds)" -eq 0

# 4. asking again after the restore works
log_must zfs presage -t 300 $f
log_must test "$(presaged_bytes $f)" -eq $((32 * mib))
log_must zfs presage -t 0 $f
presage_wait_clean $base
presage_wait_settled $((psize0 + mib))

log_pass "a snapshot leaves a presaged file alone; a rollback releases it"

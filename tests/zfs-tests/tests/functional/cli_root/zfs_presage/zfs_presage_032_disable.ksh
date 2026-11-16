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
#	Setting zfs_arc_presaged_max_percent to 0 switches presage off:
#	within seconds every reservation is gone and nothing is left in
#	the presaged state, including the blocks cached dbufs hold, which
#	the cap reaper cannot see.  Requests are refused while it is off
#	and work again when it is back on.
#
# STRATEGY:
#	1. Presage a file of 8K records (so there are indirect blocks) and
#	   a volume, for ten minutes.
#	2. Set the tunable to 0.  Within 10 s: no reservations, and
#	   presaged_size at its starting value.  A request is refused.
#	3. Set it back: nothing is presaged, no deadline; a request works.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prsoff
typeset vol=$TESTPOOL/prsoffvol
typeset f=/$fs/f
typeset -i mib=$((1024 * 1024))

function cleanup
{
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	zfs presage -t 0 $f >/dev/null 2>&1
	zfs presage -V -t 0 $vol >/dev/null 2>&1
	datasetexists $fs && destroy_dataset $fs -r
	datasetexists $vol && destroy_dataset $vol
	arc_restore
}

log_assert "zfs_arc_presaged_max_percent=0 releases everything presaged"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)

# 1. a file with indirect blocks and a volume, both presaged
log_must zfs create -o recordsize=8k -o compression=off $fs
log_must file_write -o create -f $f -b 8192 -c 8192 -d R
log_must zfs create -V 64m -o volblocksize=16k -o compression=off $vol
block_device_wait
typeset dev=$(presage_zvol_dev $vol)
[[ -n $dev ]] && log_must dd if=/dev/urandom of=$dev bs=1M count=32 \
    conv=fsync
sync_pool $TESTPOOL
log_must zfs presage -t 600 $f
log_must zfs presage -V -t 600 $vol
log_must test "$(kstat presage.reservations)" -eq $((base + 2))
log_must test "$(presaged_size)" -gt $((psize0 + 64 * mib))

# 2. off
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 0
typeset -i i
for ((i = 0; i < 50; i++)); do
	[[ $(kstat presage.reservations) -le $base &&
	    $(presaged_size) -le $((psize0 + 131072)) ]] && break
	sleep 0.2
done
log_note "presaged_size $(presaged_size) (start $psize0)," \
    "reservations $(kstat presage.reservations) (start $base)"
log_must test "$(kstat presage.reservations)" -eq $base
log_must test "$(presaged_size)" -le $((psize0 + 131072))
log_mustnot zfs presage -t 60 $f

# 3. on again
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
log_must test "$(presaged_bytes $f)" -eq 0
log_must test "$(expires_at $f)" -eq 0
log_must zfs presage -t 60 $f
log_must test "$(presaged_bytes $f)" -eq $((64 * mib))
log_must zfs presage -t 0 $f
presage_wait_clean $base

log_pass "zfs_arc_presaged_max_percent=0 releases everything presaged"

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
#	A volume reservation follows the dataset, not its name: it survives
#	rename (status by the new name, ENOENT by the old), snapshot and
#	clone (the clone shares the presaged blocks but has no reservation
#	of its own).  A rollback cancels it: the volume returns to a prior
#	state, so what was asked for on the discarded one is released and
#	the admin asks again afterwards.
#
# STRATEGY:
#	1. Reserve -s +4s; rename; after 7 s the new name reports warmed,
#	   the old name is ENOENT.
#	2. Snapshot and clone: origin unchanged; clone has no reservation
#	   (and, with data, its shared blocks already read as presaged).
#	3. Grow the volume, write into the new region when a device exists,
#	   slow reads with zinject, reserve again inline and roll back to the
#	   snapshot racing the load: each attempt is EBUSY or success and the
#	   EBUSY count is logged.  Afterwards volsize is back, the
#	   reservation count is at its baseline, status reports no
#	   reservation and nothing presaged on the volume, and no hold is
#	   left.  A new request after the rollback warms the volume again.
#	4. Wait for the blocks the rollback orphaned to leave the presaged
#	   state (the async destroy frees them) before the next test.
#

verify_runnable "global"

typeset vol=$TESTPOOL/$TESTVOL
typeset vol2=$TESTPOOL/${TESTVOL}2
typeset clone=$TESTPOOL/prsclone
typeset -i mib=$((1024 * 1024))
DISK=${DISKS%% *}

function cleanup
{
	zinject -c all >/dev/null 2>&1
	zfs presage -t 0 $vol >/dev/null 2>&1
	zfs presage -t 0 $vol2 >/dev/null 2>&1
	datasetexists $clone && log_must zfs destroy $clone
	datasetexists $vol2 && log_must zfs destroy -r $vol2
	datasetexists $vol && log_must zfs destroy -r $vol
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

# Roll $1 back to $2 while a load (job $3) may be in progress: every
# attempt must fail with EBUSY or succeed, within 60 s; log the outcome.
function rollback_racing # volume snapshot pid
{
	typeset out
	typeset -i i busy=0
	for ((i = 0; i < 300; i++)); do
		if out=$(zfs rollback $1@$2 2>&1); then
			typeset alive=no
			kill -0 $3 2>/dev/null && alive=yes
			log_note "RACE rollback $1@$2: $busy attempts returned" \
			    "EBUSY; succeeded with the load still running:" \
			    "$alive"
			return 0
		fi
		[[ "$out" == *busy* ]] || log_fail "rollback: $out"
		busy=$((busy + 1))
		sleep 0.2
	done
	log_fail "zfs rollback $1@$2 still busy after 60 s"
}

function wait_job # pid
{
	typeset -i i
	for ((i = 0; i < 450; i++)); do
		kill -0 $1 2>/dev/null || return 0
		sleep 0.2
	done
	log_fail "presage did not return within 90 s"
}

log_assert "a volume reservation follows rename, snapshot and clone;" \
    "rollback cancels it"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)

log_must zfs create -V 256m $vol
block_device_wait
typeset dev=$(presage_zvol_dev $vol)
typeset have_data=false
if [[ -n $dev ]]; then
	log_must dd if=/dev/urandom of=$dev bs=1M count=64 conv=fsync
	have_data=true
fi
sync_pool $TESTPOOL

# 1. rename
log_must zfs presage -s +4s -t 300 $vol
log_must zfs rename $vol $vol2
log_mustnot zfs presage status $vol
sleep 7
log_must test "$(pending_count $vol2)" -eq 0
log_must test "$(warmed_at $vol2)" -gt 0
$have_data && log_must test "$(presaged_bytes $vol2)" -eq $((64 * mib))

# 2. snapshot and clone
log_must zfs snapshot $vol2@s
log_must zfs clone $vol2@s $clone
log_must test "$(warmed_at $vol2)" -gt 0
log_must test "$(warmed_at $clone)" -eq 0
log_must test "$(pending_count $clone)" -eq 0
$have_data && log_must test "$(presaged_bytes $clone)" -eq $((64 * mib))
log_mustnot zfs presage -t 60 -V $vol2@s

# 3. rollback racing an inline load cancels the reservation
log_must zfs set volsize=512m $vol2
if $have_data; then
	block_device_wait
	dev=$(presage_zvol_dev $vol2)
	[[ -n $dev ]] || log_fail "no device for $vol2 after rename"
	log_must dd if=/dev/urandom of=$dev bs=1M count=64 seek=256 conv=fsync
	sync_pool $TESTPOOL
	log_must zpool export $TESTPOOL
	log_must zpool import $TESTPOOL
	# 50 ms per read on 64 lanes: each cold 64 MiB chunk takes ~3 s.
	log_must zinject -d $DISK -D 50:64 -T read $TESTPOOL
fi
zfs presage -t 300 $vol2 >/dev/null 2>&1 &
typeset pid=$!
rollback_racing $vol2 s $pid
wait_job $pid
log_must zinject -c all
log_must test "$(get_prop volsize $vol2)" -eq $((256 * mib))
# The release walk runs on the presage thread, after any in-flight load.
presage_wait_clean $base
log_must test "$(kstat presage.reservations)" -eq $base
log_must zfs presage status $vol2
log_must test "$(expires_at $vol2)" -eq 0
log_must test "$(warmed_at $vol2)" -eq 0
log_must test "$(pending_count $vol2)" -eq 0
log_must test "$(presaged_bytes $vol2)" -eq 0

# Asking again after the restore works.
log_must zfs presage -t 300 $vol2
log_must test "$(kstat presage.reservations)" -eq $((base + 1))
$have_data && log_must test "$(presaged_bytes $vol2)" -eq $((64 * mib))
log_must zfs presage -t 0 $vol2
presage_wait_clean $base

# 4. the orphaned blocks drain once the async destroy frees them
presage_wait_settled $((psize0 + mib))
log_pass "a volume reservation follows rename, snapshot and clone;" \
    "rollback cancels it"

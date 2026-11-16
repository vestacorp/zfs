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
#	Destroying a reserved volume never hangs and leaves nothing behind:
#	during the pending-start window the destroy succeeds at once and the
#	reservation cancels quietly; during an inline load (and for a
#	recursive destroy of the parent) each attempt returns EBUSY or
#	succeeds within one 64 MiB chunk; afterwards status by the old name
#	is ENOENT, the presage kstat shows the reservation gone and no hold
#	left, and a volume recreated under the name starts clean.
#
# STRATEGY:
#	1. volmode=none volume, reserve -s +4s, destroy: succeeds; status by
#	   name fails; within 15 s the reservation count is back to baseline
#	   (a reservation on a destroyed dataset cancels at its next sweep), a
#	   recreated volume has no reservation and can be reserved and
#	   destroyed again (no stale hold).
#	2. If a device is available: write 512M into a volume, start cold,
#	   slow reads with zinject so the load takes several seconds, begin
#	   an inline load in the background and loop zfs destroy until it
#	   succeeds (bounded); the load returns (bounded); status ENOENT;
#	   kstat reservations at baseline, holds 0.  The attempts that saw
#	   EBUSY are counted and logged: they prove the destroy met the
#	   chunk's hold.
#	3. The same with zfs destroy -r of a parent filesystem.
#

verify_runnable "global"

typeset vol=$TESTPOOL/$TESTVOL
typeset parent=$TESTPOOL/prsparent
typeset -i mib=$((1024 * 1024))
DISK=${DISKS%% *}

function cleanup
{
	zinject -c all >/dev/null 2>&1
	zfs presage -t 0 $vol >/dev/null 2>&1
	datasetexists $vol && log_must zfs destroy $vol
	datasetexists $parent && log_must zfs destroy -r $parent
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

# Destroy $1 (with $2 as extra flags) while a load may be in progress:
# every attempt must fail with EBUSY or succeed, within 60 s.  Logs how
# many attempts met the hold and whether the load was still running when
# the destroy went through.
function destroy_racing # dataset flags pid
{
	typeset ds=$1 flags=$2 pid=$3 out
	typeset -i i busy=0
	for ((i = 0; i < 300; i++)); do
		if out=$(zfs destroy $flags $ds 2>&1); then
			typeset alive=no
			kill -0 $pid 2>/dev/null && alive=yes
			log_note "RACE destroy $flags $ds: $busy attempts" \
			    "returned EBUSY; succeeded with the load" \
			    "still running: $alive"
			return 0
		fi
		[[ "$out" == *busy* ]] || log_fail "destroy: $out"
		busy=$((busy + 1))
		sleep 0.2
	done
	log_fail "zfs destroy $flags $ds still busy after 60 s"
}

# Wait for background job $1 to finish within 90 s.
function wait_job # pid
{
	typeset -i i
	for ((i = 0; i < 450; i++)); do
		kill -0 $1 2>/dev/null || return 0
		sleep 0.2
	done
	log_fail "presage did not return within 90 s"
}

log_assert "destroying a reserved volume never hangs and leaves nothing"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)

# 1. pending window
log_must zfs create -V 64m -o volmode=none $vol
log_must zfs presage -s +4s -t 60 $vol
log_must test "$(pending_count $vol)" -eq 1
log_must test "$(kstat presage.pending)" -ge 1
log_must zfs destroy $vol
log_mustnot zfs presage status $vol
sleep 7
presage_wait_clean $base
log_must zfs create -V 64m -o volmode=none $vol
log_must test "$(pending_count $vol)" -eq 0
log_must test "$(warmed_at $vol)" -eq 0
log_must zfs presage -t 30 $vol
log_must zfs destroy $vol
log_mustnot zfs presage status $vol
presage_wait_clean $base

# 2. inline load
log_must zfs create -V 1g $vol
block_device_wait
typeset dev=$(presage_zvol_dev $vol)
if [[ -z $dev ]]; then
	log_must zfs destroy $vol
	log_pass "destroy during the pending window is clean; no device" \
	    "for the inline-load case"
fi
log_must dd if=/dev/urandom of=$dev bs=1M count=512 conv=fsync
sync_pool $TESTPOOL
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL

# 20 ms per read on 64 lanes: a 64 MiB chunk of 16K blocks takes ~1.3 s,
# the 512 MiB load ~10 s, so the destroy attempts land inside chunks.
log_must zinject -d $DISK -D 20:64 -T read $TESTPOOL
zfs presage -t 600 $vol >/dev/null 2>&1 &
typeset pid=$!
destroy_racing $vol "" $pid
wait_job $pid
log_must zinject -c all
log_mustnot zfs presage status $vol
datasetexists $vol && log_fail "$vol still exists after destroy"
presage_wait_clean $base

# 3. recursive destroy of the parent
log_must zfs create $parent
log_must zfs create -V 1g $parent/$TESTVOL
block_device_wait
dev=$(presage_zvol_dev $parent/$TESTVOL)
[[ -n $dev ]] || log_fail "no device for $parent/$TESTVOL"
log_must dd if=/dev/urandom of=$dev bs=1M count=512 conv=fsync
sync_pool $TESTPOOL
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL

log_must zinject -d $DISK -D 20:64 -T read $TESTPOOL
zfs presage -t 600 $parent/$TESTVOL >/dev/null 2>&1 &
pid=$!
destroy_racing $parent -r $pid
wait_job $pid
log_must zinject -c all
log_mustnot zfs presage status $parent/$TESTVOL
datasetexists $parent && log_fail "$parent still exists after destroy -r"
presage_wait_clean $base

# a recreated volume under the old name starts clean
log_must zfs create -V 64m -o volmode=none $vol
log_must test "$(pending_count $vol)" -eq 0
log_must test "$(presaged_bytes $vol)" -eq 0
log_pass "destroying a reserved volume never hangs and leaves nothing"

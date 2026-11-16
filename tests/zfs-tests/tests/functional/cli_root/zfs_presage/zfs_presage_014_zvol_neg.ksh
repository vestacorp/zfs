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
#	The volume form rejects filesystems, snapshots and unknown names;
#	unprivileged users can query but not presage a volume; an offset at
#	or beyond volsize presages nothing without error; export forgets a
#	volume's reservations.  No device node is needed for any of this.
#

verify_runnable "global"

typeset vol=$TESTPOOL/$TESTVOL
PRS_USER=zprsuser
PRS_GROUP=zprsgroup

function cleanup
{
	poolexists $TESTPOOL || log_must zpool import $TESTPOOL
	zfs presage -t 0 $vol >/dev/null 2>&1
	datasetexists $vol && log_must zfs destroy -r $vol
	del_user $PRS_USER
	del_group $PRS_GROUP
	restore_tunable ARC_PRESAGED_MAX_PERCENT
}

log_assert "zfs presage rejects non-volumes and unprivileged volume requests"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25
log_must add_group $PRS_GROUP
log_must add_user $PRS_GROUP $PRS_USER

log_must zfs create -V 256m -o volmode=none $vol
log_must zfs snapshot $vol@snap
sync_pool $TESTPOOL

# A filesystem by name is not a volume; a snapshot is not either.
log_mustnot zfs presage -t 60 -V $TESTPOOL
log_must eval "zfs presage -t 60 -V $TESTPOOL 2>&1 | grep -q 'not a volume'"
log_mustnot zfs presage -t 60 $TESTPOOL
log_mustnot zfs presage -t 60 -V $vol@snap
log_mustnot zfs presage status -V $vol@snap
log_mustnot zfs presage -t 60 -V $TESTPOOL/no-such-volume
log_mustnot zfs presage status $TESTPOOL/no-such-volume

# Unprivileged: no reservations, but status is fine (as 004 for files).
# stat -c is GNU and stat -f is BSD, so ask each for the octal mode.
typeset mode
if is_freebsd; then mode=$(stat -f %Lp /dev/zfs); else mode=$(stat -c %a /dev/zfs); fi
if (( (8#$mode & 6) == 6 )); then
	log_mustnot user_run $PRS_USER zfs presage -t 60 $vol
	log_mustnot user_run $PRS_USER zfs presage -t 0 $vol
	log_must user_run $PRS_USER zfs presage status $vol
else
	log_note "/dev/zfs is not world RW; skipping the unprivileged checks"
fi

# An offset at or beyond volsize presages nothing and is not an error.
log_must zfs presage -t 60 -o $((256 * 1024 * 1024)) $vol
log_must test "$(presaged_bytes $vol)" -eq 0
log_must zfs presage -t 60 -o $((300 * 1024 * 1024)) -l 1024 -V $vol
log_must test "$(presaged_bytes $vol)" -eq 0
# The same after a shrink moves volsize below a reservation's offset.
if zfs set volsize=64m $vol >/dev/null 2>&1; then
	log_must zfs presage -t 60 -o $((128 * 1024 * 1024)) $vol
	log_must test "$(presaged_bytes "-o $((128 * 1024 * 1024)) $vol")" \
	    -eq 0
fi

# Export forgets a volume's pending reservations (as 005 for files).
log_must zfs presage -t 0 $vol
log_must zfs presage -s +120s -t 60 $vol
log_must test "$(pending_count $vol)" -eq 1
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL
log_must test "$(pending_count $vol)" -eq 0
log_pass "zfs presage rejects non-volumes and unprivileged volume requests"

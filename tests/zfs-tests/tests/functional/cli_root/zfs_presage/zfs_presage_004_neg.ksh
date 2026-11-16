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
#	Disabled by default; bad arguments rejected; unprivileged users can
#	query but not presage; primarycache=metadata data is not presaged.
#

verify_runnable "global"

PRS_USER=zprsuser
PRS_GROUP=zprsgroup

function cleanup
{
	zfs presage -t 0 $TESTDIR/f >/dev/null 2>&1
	del_user $PRS_USER
	del_group $PRS_GROUP
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	log_must zfs inherit primarycache $TESTPOOL/$TESTFS
	rm -f $TESTDIR/f
}

log_assert "zfs presage rejects invalid and unprivileged requests"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
log_must add_group $PRS_GROUP
log_must add_user $PRS_GROUP $PRS_USER

log_must file_write -o create -f $TESTDIR/f -b 131072 -c 16 -d R
log_must chmod 644 $TESTDIR/f
sync_pool $TESTPOOL

log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 0
log_mustnot zfs presage -t 60 $TESTDIR/f
log_must zfs presage status $TESTDIR/f

log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 25
log_mustnot zfs presage -t -5 $TESTDIR/f
log_mustnot zfs presage -t 60x $TESTDIR/f
log_mustnot zfs presage -s yesterday $TESTDIR/f
log_mustnot zfs presage -t 40d $TESTDIR/f
log_mustnot zfs presage status -t 60 $TESTDIR/f
# Unprivileged: no reservations, but status of a readable file is fine.
# user_run needs /dev/zfs to be world RW (the udev rule does that on an
# installed system; a test box running from the build tree may lack it).
# stat -c is GNU and stat -f is BSD, so ask each for the octal mode.
typeset mode
if is_freebsd; then mode=$(stat -f %Lp /dev/zfs); else mode=$(stat -c %a /dev/zfs); fi
if (( (8#$mode & 6) == 6 )); then
	log_mustnot user_run $PRS_USER zfs presage -t 60 $TESTDIR/f
	log_must user_run $PRS_USER zfs presage status $TESTDIR/f
else
	log_note "/dev/zfs is not world RW; skipping the unprivileged checks"
fi

log_must zfs set primarycache=metadata $TESTPOOL/$TESTFS
log_must zfs presage -t 60 $TESTDIR/f
log_must test "$(presaged_bytes $TESTDIR/f)" -eq 0
log_pass "zfs presage rejects invalid and unprivileged requests"

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
#	Blocks that leave a presaged file leave the presaged state, also
#	when a snapshot keeps them alive.  Without a snapshot the free
#	destroys their ARC headers; with one nothing would, and a file
#	that is truncated, deleted or replaced by rename under snapshots
#	would leave copies nobody owns presaged until their deadline.
#	The snapshot's copy of each file names exactly those blocks, so
#	its status says whether they are still presaged.
#
# STRATEGY:
#	1. Presage three 32 MiB files for ten minutes and snapshot; the
#	   snapshot's copies report all of it presaged.
#	2. Delete the first: its copy in the snapshot reports nothing
#	   presaged within seconds.
#	3. Truncate the second to 8 MiB: 8 MiB stay presaged, in the file
#	   and in its copy.
#	4. Replace the third by renaming a new file over it: its copy
#	   reports nothing presaged, and its reservation goes.
#	5. Kill the one reservation left: no presaged data remains, and
#	   no more metadata than the rewritten blocks the snapshot keeps.
#

verify_runnable "global"

typeset fs=$TESTPOOL/prsfree
typeset snap=/$fs/.zfs/snapshot/s1
typeset -i mib=$((1024 * 1024))

function cleanup
{
	datasetexists $fs && destroy_dataset $fs -r
	restore_tunable ARC_PRESAGED_MAX_PERCENT
	arc_restore
}

# Wait up to 15 s for the snapshot's copy of $1 to report $2 bytes presaged.
function snap_presaged # name bytes
{
	typeset -i i
	for ((i = 0; i < 75; i++)); do
		[[ $(presaged_bytes $snap/$1) -eq $2 ]] && break
		sleep 0.2
	done
	log_note "the snapshot's $1: $(presaged_bytes $snap/$1) presaged," \
	    "expected $2; presaged_size $(presaged_size)"
	log_must test "$(presaged_bytes $snap/$1)" -eq $2
}

log_assert "freed blocks leave the presaged state under a snapshot"
log_onexit cleanup
save_tunable ARC_PRESAGED_MAX_PERCENT
arc_save
arc_fixed $((1024 * mib))
log_must set_tunable32 ARC_PRESAGED_MAX_PERCENT 50
typeset -i base=$(kstat presage.reservations)
typeset -i psize0=$(presaged_size)
typeset -i pdata0=$(kstat arcstats.presaged_data)

# 1. three presaged files and a snapshot that keeps their blocks
log_must zfs create -o compression=off $fs
for n in a b c; do
	log_must file_write -o create -f /$fs/$n -b 131072 -c 256 -d R
done
sync_pool $TESTPOOL
for n in a b c; do
	log_must zfs presage -t 600 /$fs/$n
done
log_must zfs snapshot $fs@s1
for n in a b c; do
	log_must test "$(presaged_bytes $snap/$n)" -eq $((32 * mib))
done

# 2. delete
log_must rm /$fs/a
sync_pool $TESTPOOL
snap_presaged a 0

# 3. truncate
log_must truncate -s $((8 * mib)) /$fs/b
sync_pool $TESTPOOL
snap_presaged b $((8 * mib))
log_must test "$(presaged_bytes /$fs/b)" -eq $((8 * mib))

# 4. replace by rename
log_must file_write -o create -f /$fs/c.new -b 131072 -c 256 -d R
log_must mv /$fs/c.new /$fs/c
sync_pool $TESTPOOL
snap_presaged c 0
log_must test "$(presaged_bytes /$fs/c)" -eq 0
typeset -i i
for ((i = 0; i < 50; i++)); do
	[[ $(kstat presage.reservations) -le $((base + 1)) ]] && break
	sleep 0.2
done
log_must test "$(kstat presage.reservations)" -eq $((base + 1))

# 5. no data is left once the last reservation is killed, and no
# indirect block: the old copy of b's, which the snapshot keeps, gave its
# deadline to the new one when it was rewritten.  The dnode blocks of the
# two files that are gone stay until their deadline; allow for them.
log_must zfs presage -t 0 /$fs/b
presage_wait_clean $base
presage_wait_settled $((psize0 + 131072)) 15
for ((i = 0; i < 75; i++)); do
	[[ $(kstat arcstats.presaged_data) -le $pdata0 ]] && break
	sleep 0.2
done
log_note "presaged_data $(kstat arcstats.presaged_data), was $pdata0;" \
    "presaged_metadata $(kstat arcstats.presaged_metadata)"
log_must test "$(kstat arcstats.presaged_data)" -le $pdata0

log_pass "freed blocks leave the presaged state under a snapshot"

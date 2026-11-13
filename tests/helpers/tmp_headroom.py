#!/usr/bin/env python3
"""tmp_headroom.py DIR -- free space for the test suite's scratch root (#250).

Prints one line: bytes=<n> inodes=<n|-> source=<quota|statvfs> note=<text>

statvfs(DIR) is always read (f_bavail*f_frsize, f_favail). A filesystem
that reports f_files == 0 has no inode limit of its own (btrfs, tmpfs with
nr_inodes=0, vfat, CIFS report f_files = f_ffree = f_favail = 0): its inode
figure is "-" (no limit) unless a quota sets one. On Linux the
per-user and per-group quota of DIR's filesystem is read too, with
quotactl_fd(fd, QCMD(Q_GETQUOTA, type), id, &if_dqblk) (syscall 443 on x86_64
and arm64): a tmpfs or disk with usrquota caps a user well below what statvfs
reports (`df` cannot see it). For each type that has limits, bytes =
max(0, limit*1024 - curspace) with limit the smaller non-zero of the hard and
soft block limits, inodes = max(0, ihard - curinodes) when ihard > 0. The
result is the minimum over statvfs and every type that returned limits;
source=quota when any did. Any errno, or all-zero limits, means "no quota
from that type"; the errno name goes into note= (usr:<..> grp:<..>).

quotactl_fd exists from Linux 5.14. On an older kernel every type answers
ENOSYS whatever the filesystem, so a quota (ext4/xfs usrquota) cannot be
seen: note= then carries "quota-unreadable" and the suite warns that the
headroom may be overstated. (On 5.14+ ENOSYS just means the filesystem has
no quota support, e.g. vfat.)

Run with python3 -I. Exit 0 with the line, 2 when DIR cannot be read.
"""
import ctypes
import errno
import os
import struct
import sys

Q_GETQUOTA = 0x800007
USRQUOTA, GRPQUOTA = 0, 1
QIF_BLIMITS, QIF_ILIMITS = 1, 4
SYS_QUOTACTL_FD = 443          # unified number; x86_64 and arm64 alike
IF_DQBLK = struct.Struct('=QQQQQQQQI')   # struct if_dqblk (72 bytes, last field u32 + pad)


def quota(path, qtype, ident):
    """(bytes_left|None, inodes_left|None, note)"""
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    except OSError as e:
        return None, None, errno.errorcode.get(e.errno, str(e.errno))
    try:
        buf = ctypes.create_string_buffer(IF_DQBLK.size + 8)
        cmd = (Q_GETQUOTA << 8) | qtype
        r = libc.syscall(SYS_QUOTACTL_FD, fd, ctypes.c_uint(cmd), ctypes.c_int(ident), buf)
        e = ctypes.get_errno()
    finally:
        os.close(fd)
    if r != 0:
        return None, None, errno.errorcode.get(e, str(e))
    bhard, bsoft, curspace, ihard, isoft, curinodes, _bt, _it, valid = IF_DQBLK.unpack(buf.raw[:IF_DQBLK.size])
    b = i = None
    lims = [x for x in (bhard, bsoft) if x]
    if (valid & QIF_BLIMITS) and lims:
        b = max(0, min(lims) * 1024 - curspace)
    ilims = [x for x in (ihard, isoft) if x]
    if (valid & QIF_ILIMITS) and ilims:
        i = max(0, min(ilims) - curinodes)
    if b is None and i is None:
        return None, None, 'nolimits'
    return b, i, 'ok'


def old_kernel():
    try:
        major, minor = (int(x) for x in os.uname().release.split('.')[:2])
    except ValueError:
        return False
    return (major, minor) < (5, 14)


def main():
    if len(sys.argv) != 2:
        print('usage: tmp_headroom.py DIR', file=sys.stderr)
        return 2
    d = sys.argv[1]
    try:
        st = os.statvfs(d)
    except OSError as e:
        print('tmp_headroom: cannot statvfs %s: %s' % (d, e), file=sys.stderr)
        return 2
    by = st.f_bavail * st.f_frsize
    ino = st.f_favail if st.f_files else None      # None: no inode limit (#265)
    source, notes = 'statvfs', []
    if sys.platform == 'linux' and os.uname().machine in ('x86_64', 'aarch64', 'arm64'):
        for tag, qt, ident in (('usr', USRQUOTA, os.geteuid()), ('grp', GRPQUOTA, os.getegid())):
            b, i, note = quota(d, qt, ident)
            notes.append('%s:%s' % (tag, note))
            if b is not None:
                by, source = min(by, b), 'quota'
            if i is not None:
                ino, source = (i if ino is None else min(ino, i)), 'quota'
    else:
        notes.append('quota:not-read-on-%s-%s' % (sys.platform, os.uname().machine))
    if st.f_files == 0:
        notes.append('statvfs:no-inode-limit')
    if sys.platform == 'linux' and 'usr:ENOSYS' in notes and old_kernel():
        notes.append('quota-unreadable(kernel<5.14)')
    print('bytes=%d inodes=%s source=%s note=%s' % (by, '-' if ino is None else ino, source, ','.join(notes)))
    return 0


if __name__ == '__main__':
    sys.exit(main())

# The ssh/scp options of every native-run script (#268); sourced by
# native_exec.sh, native_hostrows.sh, native_concurrent.sh, native_perf.sh,
# native_probe.sh and cdb_chain.sh. Row native_ssh_opts_single_site keeps every
# ssh/scp call of tests/windows/*.sh on NATIVE_SSH_OPTS; row
# native_ssh_weakcrypto_probe checks the probe below against fake ssh binaries.
#
# NATIVE_SSH_OPTS: -o BatchMode=yes (never prompt), plus
# -o WarnWeakCrypto=no-pq-kex when this ssh accepts that value. OpenSSH 10.2
# prints "** WARNING: connection is not using a post-quantum key exchange
# algorithm." (and two follow-up lines) into the stderr of every connection to
# a server without a PQ key exchange, and several native rows compare stderr.
# `no-pq-kex` silences only that warning: any other weak-crypto warning stays
# visible and fails those rows loudly. OpenSSH 9.6 does not know the option
# (rc 255, "Bad configuration option: warnweakcrypto"), so it is probed once,
# with `ssh -G`, which only prints the resulting configuration and never
# connects; an ssh that rejects the exact value gets nothing added.
# ~/.ssh/config is never touched.
NATIVE_SSH_OPTS=(-o BatchMode=yes)
if ssh -G -o WarnWeakCrypto=no-pq-kex localhost > /dev/null 2>&1; then
    NATIVE_SSH_OPTS+=(-o WarnWeakCrypto=no-pq-kex)
fi

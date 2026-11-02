#!/bin/bash
# native_hostrows.sh -- the suite rows whose expectation is the HOST's network
# (#143 A14b, spec 8.6 (a) table, last line: rows the wrapper cannot carry get
# a named per-row native script). Under Wine the program shares the Linux
# host's network, so these rows judge it against Linux; natively the program
# sees the laptop's. Laptop side: inline PowerShell only (user ruling).
#
#   native_hostrows.sh <compiler> <fixtures dir>
#
#  * sys_so_broadcast_windows_wine: the row sends to 127.255.255.255, Linux's
#    lo broadcast route, which is not a broadcast address on Windows. The
#    fixture's NATIVE mode `all` sends to 255.255.255.255 (one 48-byte UDP
#    datagram onto the laptop's LAN, port 9 discard): without SO_BROADCAST
#    the send must be refused -EACCES (-13), with it it must send 48 bytes.
#  * sys_net_ifaces_windows_wine_matches_ip_addr: the row compares the
#    interface list with Linux `ip -4 addr`; natively it is compared with the
#    laptop's own Get-NetIPAddress: the IPv4 address/prefix of every address
#    whose interface (Get-NetIPInterface) is Connected -- loopback included,
#    no special case -- both as the full list and as the UP set.
#    sys_net_ifaces enumerates with Winsock's SIO_GET_INTERFACE_LIST, which
#    leaves out Disconnected interfaces (their Tentative addresses, measured:
#    the 169.254/16 autoconfiguration addresses of disconnected adapters);
#    each such address is printed with a check that it is absent from the
#    program's list.
# Prints "<row>: PASS|FAIL (detail)"; exits 0 when both pass, 1 otherwise,
# 2 on a transport error.
set -u -o pipefail
NATIVE_HOST="${NATIVE_HOST:-laptop}"
KRC="${1:?usage: native_hostrows.sh <compiler> <fixtures dir>}"; FX="${2:?fixtures dir}"
L=$(mktemp -d "$HOME/.cache/pe_unwind/nhr.XXXXXX")
RD="C:\\Users\\pante\\pe_unwind_scratch\\nhr$$"; RDF="C:/Users/pante/pe_unwind_scratch/nhr$$"
rps() { ssh -o BatchMode=yes "$NATIVE_HOST" "powershell -NoProfile -NonInteractive -Command \"\$ProgressPreference='SilentlyContinue'; $1\"" < /dev/null; }
cleanup() {
    rm -rf "$L"
    rps "for (\$i=0; \$i -lt 120 -and (Test-Path -LiteralPath '$RD'); \$i++) { Remove-Item -LiteralPath '$RD' -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath '$RD') { Start-Sleep -Milliseconds 500 } }; if ((Test-Path 'C:\\Users\\pante\\pe_unwind_scratch') -and -not (Get-ChildItem -Force 'C:\\Users\\pante\\pe_unwind_scratch')) { Remove-Item -Force 'C:\\Users\\pante\\pe_unwind_scratch' }; if (Test-Path -LiteralPath '$RD') { exit 1 }; exit 0" \
        || { echo "native_hostrows.sh: remote $RD not removed" >&2; exit 2; }
}
for f in sys_bcast sys_ifaces; do
    ( ulimit -v 2000000; timeout 60 "$KRC" --arch=x86_64 --target=windows --emit=pe "$FX/$f.kr" -o "$L/$f.exe" ) > "$L/b.log" 2>&1 \
        || { echo "native_hostrows.sh: build of $f failed: $(grep -m1 error "$L/b.log")"; rm -rf "$L"; exit 1; }
done
rps "New-Item -ItemType Directory -Force '$RD' | Out-Null; exit 0" > /dev/null || { rm -rf "$L"; echo "native_hostrows.sh: remote mkdir failed" >&2; exit 2; }
scp -q -o BatchMode=yes "$L/sys_bcast.exe" "$L/sys_ifaces.exe" "$NATIVE_HOST:$RDF/" < /dev/null || { cleanup; exit 2; }
OUT=$(rps "Set-Location '$RD'; \$b=& '$RD\\sys_bcast.exe' all; 'BC_RC=' + \$LASTEXITCODE; \$b | ForEach-Object { 'BC=' + \$_ }; \$f=& '$RD\\sys_ifaces.exe'; 'IF_RC=' + \$LASTEXITCODE; \$f | ForEach-Object { 'IF=' + \$_ }; Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object { 'NA=' + \$_.IPAddress + '/' + \$_.PrefixLength + ' ' + (Get-NetIPInterface -InterfaceIndex \$_.InterfaceIndex -AddressFamily IPv4).ConnectionState + ' ' + \$_.AddressState }; exit 0" | tr -d '\r')
TRC=$?
cleanup
[ "$TRC" = 0 ] || { echo "native_hostrows.sh: remote run failed ($TRC)" >&2; exit 2; }
bad=0
BC=$(grep '^BC=' <<< "$OUT" | cut -c4- | paste -sd'|')
if grep -qx 'BC_RC=0' <<< "$OUT" && [ "$BC" = 'without -13|with 48' ]; then
    echo "sys_so_broadcast_windows_wine: PASS (natively, 255.255.255.255: without -13, with 48)"
else
    echo "sys_so_broadcast_windows_wine: FAIL (natively, 255.255.255.255: '$BC', rc $(grep '^BC_RC=' <<< "$OUT" | cut -d= -f2), want 'without -13|with 48' rc 0)"; bad=1
fi
m2p() { local m="$1" n=0 o; for o in ${m//./ }; do while [ "$o" -gt 0 ]; do n=$((n + (o & 1))); o=$((o >> 1)); done; done; echo "$n"; }
X=$(grep '^IF=' <<< "$OUT" | cut -c4- | sed 1d | while read -r a m b f; do echo "$a/$(m2p "$m")"; done | LC_ALL=C sort | tr '\n' ' ')
A=$(grep '^IF=' <<< "$OUT" | cut -c4- | sed 1d | awk '($4 % 2) == 1 {print $1}' | LC_ALL=C sort | tr '\n' ' ')
Y=$(grep '^NA=' <<< "$OUT" | cut -c4- | awk '$2 == "Connected" {print $1}' | LC_ALL=C sort | tr '\n' ' ')
B=$(grep '^NA=' <<< "$OUT" | cut -c4- | awk '$2 == "Connected" {print $1}' | cut -d/ -f1 | LC_ALL=C sort | tr '\n' ' ')
# every address of a Disconnected interface, and whether it is absent from
# the program's list (it must be)
NOTC=""; for e in $(grep '^NA=' <<< "$OUT" | cut -c4- | awk '$2 != "Connected" {print $1 "|" $2 "|" $3}'); do
    a=${e%%|*}; r=${e#*|}
    if grep -qw -- "${a%/*}" <<< "$X $A"; then NOTC="$NOTC $a (${r/|/,}) PRESENT in the program's list;"; bad=1
    else NOTC="$NOTC $a (${r/|/,}) absent from Winsock's list;"; fi
done
if grep -qx 'IF_RC=0' <<< "$OUT" && [ -n "$Y" ] && [ "$X" = "$Y" ] && [ "$A" = "$B" ]; then
    echo "sys_net_ifaces_windows_wine_matches_ip_addr: PASS (natively vs Get-NetIPAddress: $(wc -w <<< "$Y") addr/prefix, $(wc -w <<< "$B") UP;${NOTC:- no Disconnected interface})"
else
    echo "sys_net_ifaces_windows_wine_matches_ip_addr: FAIL (natively: got '$X' want '$Y'; UP got '$A' want '$B')"; bad=1
fi
exit $bad

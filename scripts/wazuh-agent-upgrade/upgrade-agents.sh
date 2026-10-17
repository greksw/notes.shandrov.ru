#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
MODE=check; YES=0; FILE=''; TARGET=''; LIMIT=900; WAIT=300
die(){ echo "ERROR: $*" >&2; exit 1; }
usage(){ echo "Usage: $0 --check|--apply --yes --inventory FILE --version X.Y.Z"; }
while (($#)); do
 case "$1" in
 --check) MODE=check; shift;;
 --apply) MODE=apply; shift;;
 --yes) YES=1; shift;;
 --inventory) FILE=$2; shift 2;;
 --version) TARGET=$2; shift 2;;
 --command-timeout) LIMIT=$2; shift 2;;
 --reconnect-timeout) WAIT=$2; shift 2;;
 -h|--help) usage; exit 0;;
 *) usage; die "Unexpected option $1";;
 esac
done
[[ $EUID == 0 ]] || die 'Run as root'
[[ -r $FILE && -f $FILE ]] || die 'Missing inventory'
[[ $TARGET =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Explicit version X.Y.Z required'
[[ $LIMIT =~ ^[0-9]+$ && $LIMIT -ge 60 ]] || die 'Invalid command timeout'
[[ $WAIT =~ ^[0-9]+$ && $WAIT -ge 30 ]] || die 'Invalid reconnect timeout'
[[ $MODE != apply || $YES == 1 ]] || die 'Use --apply --yes'
for cmd in flock timeout rpm systemctl sort tee; do command -v "$cmd" >/dev/null || die "Missing $cmd"; done
systemctl is-active --quiet wazuh-manager || die 'Manager inactive'
MANAGER=$(rpm -q --qf '%{VERSION}' wazuh-manager)
[[ $MANAGER == "$TARGET" ]] || die "Manager $MANAGER differs from target $TARGET"
CONTROL=/var/ossec/bin/agent_control
UPGRADE=/var/ossec/bin/agent_upgrade
[[ -x $CONTROL && -x $UPGRADE ]] || die 'Missing Wazuh CLI'
LOG="/var/log/wazuh-upgrade-$(date +%Y%m%d-%H%M%S)-$$.log"
exec > >(tee -a "$LOG") 2>&1
exec 9>/var/log/.wazuh-agent-upgrade.lock
flock -n 9 || die 'Another batch is running'
declare -a IDS=()
declare -A NAMES=() FAMILIES=() POLICIES=() SEEN=()
while IFS=$'\t' read -r id name family policy extra || [[ -n ${id:-} ]]; do
 [[ -z $id || $id == \#* ]] && continue
 [[ $id =~ ^[0-9]{3}$ && $id != 000 ]] || die "Bad ID $id"
 [[ -z ${SEEN[$id]:-} ]] || die "Duplicate ID $id"
 [[ -n $name && $name != *' '* && -z ${extra:-} ]] || die "Bad entry $id"
 [[ $family == linux || $family == windows ]] || die "Bad OS $id"
 [[ $policy == upgrade || $policy == skip ]] || die "Bad policy $id"
 IDS+=("$id"); NAMES[$id]=$name; FAMILIES[$id]=$family; POLICIES[$id]=$policy; SEEN[$id]=1
done < "$FILE"
((${#IDS[@]})) || die 'Empty inventory'
extract(){ sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" | head -1; }
info(){ "$CONTROL" -i "$1"; }
check(){
 local id=$1 data name os status version parsed
 data=$(info "$id") || die "No agent $id"
 name=$(printf '%s\n' "$data" | extract 'Agent Name')
 os=$(printf '%s\n' "$data" | extract 'Operating system')
 status=$(printf '%s\n' "$data" | extract Status)
 version=$(printf '%s\n' "$data" | extract 'Client version')
 [[ $name == "${NAMES[$id]}" ]] || die "Name mismatch $id"
 if [[ ${FAMILIES[$id]} == linux ]]; then
  [[ $os == Linux* ]] || die "OS mismatch $id"
 else
  [[ $os == *Windows* ]] || die "OS mismatch $id"
 fi
 echo "$id | $name | $status | $version | ${POLICIES[$id]}"
 [[ ${POLICIES[$id]} == skip ]] && return 0
 [[ $status == Active ]] || die "Inactive agent $id"
 [[ $os != *'Windows Server 2008'* && $os != *'Windows Server 2003'* ]] || die "Legacy Windows $id: local MSI only"
 [[ $version =~ ^Wazuh\ v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "Unexpected version $id"
 parsed=${BASH_REMATCH[1]}
 [[ ${parsed%.*} == "${TARGET%.*}" ]] || die "Different release series $id"
 if [[ $parsed != "$TARGET" ]]; then
  [[ $(printf '%s\n%s\n' "$parsed" "$TARGET" | sort -V | head -1) == "$parsed" ]] || die "Downgrade blocked $id"
 fi
}
echo "=== PREFLIGHT: $MODE $TARGET ==="
for id in "${IDS[@]}"; do check "$id"; done
echo 'PREFLIGHT PASSED'
[[ $MODE == check ]] && { echo 'No changes made'; exit 0; }
for id in "${IDS[@]}"; do
 [[ ${POLICIES[$id]} == skip ]] && continue
 check "$id"
 data=$(info "$id") || die "Agent not queryable $id"
 version=$(printf '%s\n' "$data" | extract 'Client version')
 [[ $version == "Wazuh v$TARGET" ]] && { echo "SKIP current $id"; continue; }
 echo "UPGRADE $id"
 timeout --signal=INT --kill-after=15s "${LIMIT}s" "$UPGRADE" -a "$id" -v "$TARGET" || die "Upgrade failed/timed out $id; do not retry without inspection"
 ok=0
 for ((n=0;n<(WAIT+9)/10;n++)); do
  sleep 10
  data=$(info "$id" 2>/dev/null) || continue
  status=$(printf '%s\n' "$data" | extract Status)
  version=$(printf '%s\n' "$data" | extract 'Client version')
  [[ $status == Active && $version == "Wazuh v$TARGET" ]] && { ok=1; break; }
 done
 ((ok)) || die "Agent $id failed reconnect"
 echo "SUCCESS $id"
done
echo '=== FINAL CHECK ==='
for id in "${IDS[@]}"; do
 [[ ${POLICIES[$id]} == skip ]] && continue
 data=$(info "$id") || die "Cannot verify $id"
 [[ $(printf '%s\n' "$data" | extract Status) == Active ]] || die "Not Active $id"
 [[ $(printf '%s\n' "$data" | extract 'Client version') == "Wazuh v$TARGET" ]] || die "Wrong version $id"
 echo "OK $id"
done
"$UPGRADE" -l
echo "COMPLETE log=$LOG"

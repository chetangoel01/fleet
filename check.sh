#!/bin/zsh
# Asks each Mac's helper for its status and prints the release it runs and every reading it
# could not take. Fails if a Mac does not answer or the releases differ. Run from m5-macbook
# after installing or upgrading.
#
#   ./check.sh                  this Mac, m1-server and mini
#   ./check.sh local mini       only the ones named ("local" is this Mac)
#   ./check.sh --save DIR ...   also keep each status as DIR/<mac>.json, to compare before and after
set -uo pipefail
save=
if [[ ${1:-} == --save ]]; then save=$2; mkdir -p $save; shift 2; fi
hosts=($@)
(( $#hosts )) || hosts=(local m1-server mini)

failed=0 releases=()
for host in $hosts; do
    # The other Macs are read the way the app reads them: through Tailscale's forward to the helper.
    if [[ $host == local ]]; then url=http://127.0.0.1:4790/status; else url=http://$host:4791/status; fi
    reply=$(curl -s -m 15 --retry 5 --retry-connrefused --retry-delay 1 $url)
    line=$(print -r -- $reply | /usr/bin/python3 -I -c '
import json, sys
d = json.load(sys.stdin)
states = {k: v["state"] for k, v in d.items() if isinstance(v, dict) and "state" in v}
unknown = sorted(k + ": " + d[k].get("error", "") for k, s in states.items() if s == "unknown")
print(d["build"], d["host"], "| not read: " + ("; ".join(unknown) or "nothing"),
      "| absent here: " + (", ".join(sorted(k for k, s in states.items() if s == "none")) or "nothing"))' 2>/dev/null)
    if [[ -z $line ]]; then print "FAIL  $host did not answer"; failed=1; continue; fi
    [[ -n $save ]] && print -r -- $reply > $save/${line[(w)2]}.json
    releases+=(${line%% *})
    print "ok    ${line#* }, release ${line%% *}"
done
typeset -U releases
if (( $#releases > 1 )); then print "FAIL  the Macs run different releases: $releases"; failed=1; fi
exit $failed

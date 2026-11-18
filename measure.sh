#!/bin/zsh
# Measures what the installed fleetd costs on each Mac, in two states:
#   1. nobody asking, for IDLE seconds (default 300)
#   2. one status request every INTERVAL seconds, REQUESTS times (default 5 x 60 s)
# It reads the copy launchd started, not a fresh one. Results print and are saved
# under measurements/. Run from m5-macbook; other Macs are sampled over ssh.
#
#   ./measure.sh
#   IDLE=60 REQUESTS=3 INTERVAL=20 ./measure.sh     a quicker pass
#
# CPU seconds are the helper's own. The tools it starts (launchctl, ps and tailscale status on each
# request, brew on a slow schedule) are timed separately at the end.
set -uo pipefail
cd "${0:A:h}"
hosts=(local m1-server mini)
idle=${IDLE:-300} count=${REQUESTS:-5} interval=${INTERVAL:-60} port=4790
mkdir -p measurements
out="measurements/$(date +%Y%m%d-%H%M%S).txt"

on() { if [[ $1 == local ]]; then zsh -c "$2"; else ssh -o BatchMode=yes -o ConnectTimeout=8 $1 "$2"; fi }

# Prints: pid|rss KB|cpu time|footprint|helper open files|idle wakeups|open files on the whole Mac
sample=$(cat <<'EOS'
pid=$(pgrep -x fleetd | head -1)
[ -z "$pid" ] && { echo missing; exit 0; }
rss=$(ps -o rss= -p $pid | tr -d " ")
cpu=$(ps -o time= -p $pid | tr -d " ")
fp=$(footprint -p $pid 2>/dev/null | grep -m1 phys_footprint: | tr -s " " | cut -d" " -f3,4 | tr -d " ")
fds=$(lsof -n -p $pid 2>/dev/null | tail -n +2 | wc -l | tr -d " ")
wake=$(top -l 1 -pid $pid -stats idlew 2>/dev/null | tail -1 | tr -d " ")
echo "$pid|$rss|$cpu|$fp|$fds|$wake|$(sysctl -n kern.num_files)"
EOS
)

seconds() { print -r -- $1 | awk -F: '{ if (NF == 3) print $1 * 3600 + $2 * 60 + $3; else print $1 * 60 + $2 }' }

typeset -A a b c
{
print "fleetd measurement, $(date '+%Y-%m-%d %H:%M'), idle ${idle} s, then $count requests ${interval} s apart"
for h in $hosts; do a[$h]=$(on $h $sample); done
sleep $idle
for h in $hosts; do b[$h]=$(on $h $sample); done

print "\nrequests (time each status took to build, in ms)"
for i in {1..$count}; do
    line="  $i:"
    for h in $hosts; do
        took=$(on $h "curl -s -m 20 http://127.0.0.1:$port/status" | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["took_ms"])' 2>/dev/null)
        line+="  $h ${took:-FAILED}"
    done
    print -r -- $line
    (( i < count )) && sleep $interval
done
for h in $hosts; do c[$h]=$(on $h $sample); done

print "\nsamples: pid | rss KB | cpu time | footprint | helper open files | idle wakeups | open files on the whole Mac"
for h in $hosts; do print "  $h\n    start       ${a[$h]}\n    after idle  ${b[$h]}\n    after asks  ${c[$h]}"; done

print "\nhelper's own CPU"
for h in $hosts; do
    ta=$(seconds ${${(s:|:)a[$h]}[3]}) tb=$(seconds ${${(s:|:)b[$h]}[3]}) tc=$(seconds ${${(s:|:)c[$h]}[3]})
    awk -v h=$h -v ta=$ta -v tb=$tb -v tc=$tc -v idle=$idle -v n=$count 'BEGIN {
        printf "  %-10s idle: %.2f s over %d s (%.4f%% of one core)   asked: %.3f s per request\n",
               h, tb - ta, idle, (tb - ta) / idle * 100, (tc - tb) / n }'
done

print "\ntools the helper starts (CPU seconds, user + system, measured by running each once)"
for h in $hosts; do
    each=$(on $h '/usr/bin/time -p sh -c "/bin/launchctl list >/dev/null; /bin/ps -Aco pcpu=,rss=,comm= >/dev/null; TAILSCALE_BE_CLI=1 /Applications/Tailscale.app/Contents/MacOS/Tailscale status --json >/dev/null" 2>&1 | awk "/user|sys/{t+=\$2} END{print t}"')
    brew=$(on $h 'HOMEBREW_NO_AUTO_UPDATE=1 /usr/bin/time -p /opt/homebrew/bin/brew outdated --quiet 2>&1 >/dev/null | awk "/user|sys/{t+=\$2} END{print t}"')
    print "  $h: launchctl + ps + tailscale status on every request ${each} s; brew outdated every 6 h ${brew} s"
done
} | tee $out
print "\nsaved $out"

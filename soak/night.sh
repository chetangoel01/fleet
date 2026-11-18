#!/bin/zsh
# Through the night: every 20 to 40 minutes, two randomly chosen edge tests on a
# randomly chosen Mac, logged by edge-run.sh. Runs on m5-macbook and stops by
# itself at the end time.
#
#   nohup soak/night.sh "2026-11-18 09:30" &
#   kill $(<soak/night.pid)       stop it early
cd "${0:A:h}"
end=$(date -j -f "%Y-%m-%d %H:%M" "$1" +%s) || exit 1
print $$ > night.pid
hosts=(local mini m1-server)
all=(burst flood silent garbage freeze kill cold conflict hung-docker stuck-tool fd-limit cpu-load)
light=(burst flood silent garbage freeze kill cold conflict)     # m1-server: requests and restarts only, no added load

while true; do
    sleep ${DRY:-$(( 1200 + RANDOM % 1200 ))}      # DRY=0.01 prints the picks instead of running them
    (( $(date +%s) < end )) || break
    host=${hosts[$(( RANDOM % 3 + 1 ))]}
    if [[ $host == m1-server ]]; then pool=($light); else pool=($all); fi
    first=${pool[$(( RANDOM % $#pool + 1 ))]} second=${pool[$(( RANDOM % $#pool + 1 ))]}
    if [[ -n ${DRY:-} ]]; then print "$host $first $second"; continue; fi
    ./edge-run.sh $host $first $second >/dev/null 2>&1
done
rm -f night.pid

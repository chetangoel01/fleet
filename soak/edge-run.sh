#!/bin/zsh
# Runs edge tests on one Mac and appends what happened to soak/edge-log.txt, so
# anything odd in the overnight samples can be matched to a test. Run from m5-macbook.
#
#   soak/edge-run.sh local burst flood
#   soak/edge-run.sh m1-server garbage
cd "${0:A:h}"
host=$1; shift
for t in $@; do
    stamp=$(date "+%Y-%m-%d %H:%M:%S")
    if [[ $host == local ]]; then out=$(zsh "$HOME/Library/Application Support/Fleet/edge.sh" $t 2>&1)
    else out=$(ssh -o BatchMode=yes -o ConnectTimeout=8 $host "zsh \"\$HOME/Library/Application Support/Fleet/edge.sh\" $t" 2>&1); fi
    print -r -- "$stamp  ${host/local/m5-macbook}  $t"$'\n'"$(print -r -- $out | sed 's/^/    /')" | tee -a edge-log.txt
done

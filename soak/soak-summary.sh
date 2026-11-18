#!/bin/zsh
# Summarises each Mac's soak.csv: what the helper cost over the run and whether
# anything moved that should stay flat. Run from m5-macbook.
#
#   soak/soak-summary.sh              whole run
#   soak/soak-summary.sh 60           only the last 60 samples
#   soak/soak-summary.sh alerts 60    print only what needs a look in the last 60 samples
#   soak/soak-summary.sh results      summarise the copies saved by "soak-start.sh clean"
#
# CPU is the helper's own count (getrusage): its own, plus the tools it started.
set -uo pipefail
cd "${0:A:h}"
hosts=(local m1-server mini)
mode=all window=0 saved=0
for a in $@; do case $a in alerts) mode=alerts;; results) saved=1;; <->) window=$a;; esac; done

for h in $hosts; do
    name=${h/local/m5-macbook}
    if (( saved )); then csv=$(cat results/$name.csv 2>/dev/null)
    elif [[ $h == local ]]; then csv=$(cat "$HOME/Library/Application Support/Fleet/soak.csv" 2>/dev/null)
    else csv=$(ssh -o BatchMode=yes -o ConnectTimeout=8 $h 'cat "$HOME/Library/Application Support/Fleet/soak.csv"' 2>/dev/null); fi
    if [[ -z $csv ]]; then print "$name: NO SAMPLES (unreachable or sampler not started)"; continue; fi
    (( window )) && csv=$(print -r -- $csv | tail -n +2 | tail -n $(( window + 1 )))    # one extra row as the baseline
    print -r -- $csv | awk -F, -v name=$name -v mode=$mode '
        $1 == "epoch" { next }
        {
            n++
            if ($3 == "") { down++; next }
            if ($14 != 200) fails++
            if (first == "") { first = $2; e0 = $1 }
            last = $2; e1 = $1
            if ($5 != "") {
                if (pid == "") { dc = dt = dr = dn = 0 }                                              # baseline row
                else if ($3 != pid) { restarts++; dc = $5; dt = $6; dr = $7; dn = $8 }                # new process: counters began again
                else { dc = $5 - pc; dt = $6 - pt; dr = $7 - pr; dn = $8 - pn }
                cpu += dc; tools += dt; reqs += dr; ran += dn
                if (dc + dt > spike) { spike = dc + dt; spikeat = $2; spikereqs = dr; spiketools = dn }
                pc = $5; pt = $6; pr = $7; pn = $8; pid = $3
            }
            if (fpmin == "" || $10 < fpmin) fpmin = $10; if ($10 > fpmax) fpmax = $10
            if (fdmin == "" || $11 < fdmin) fdmin = $11; if ($11 > fdmax) fdmax = $11
            if ($12 > thmax) thmax = $12
            if (sfmin == "" || $13 < sfmin) sfmin = $13; if ($13 > sfmax) sfmax = $13
            if ($15 + 0 > tookmax) { tookmax = $15 + 0; tookat = $2 }
            took[++m] = $15 + 0
            if ($17 + 0 > 0) { unk++; unkat = $2 }
            if ($15 + 0 >= 1000) { over++; overlist = overlist "    " $2 " " $15 " ms: " $18 "\n" }
        }
        END {
            elapsed = e1 - e0; if (elapsed < 1) elapsed = 1
            each = reqs > 0 ? (cpu + tools) / reqs : 0
            share = (cpu + tools) / elapsed * 100
            for (i = 2; i <= m; i++) { v = took[i]; for (j = i - 1; j >= 1 && took[j] > v; j--) took[j + 1] = took[j]; took[j + 1] = v }
            median = took[int((m + 1) / 2)]
            if (mode == "alerts") {
                if (fails) printf "%s: %d of %d sampler requests failed\n", name, fails, n
                if (down) printf "%s: helper not running in %d samples\n", name, down
                if (restarts) printf "%s: helper restarted %d times\n", name, restarts
                if (fpmax > 20480) printf "%s: footprint reached %.1f MB\n", name, fpmax / 1024
                if (fdmax > 40) printf "%s: helper held %d open files\n", name, fdmax
                if (thmax > 24) printf "%s: helper reached %d threads\n", name, thmax
                if (each > 0.5) printf "%s: %.2f CPU s per request\n", name, each
                if (share > 1) printf "%s: %.2f%% of one core over %d min\n", name, share, elapsed / 60
                if (tookmax > 5000) printf "%s: a status took %d ms at %s\n", name, tookmax, tookat
                if (unk) printf "%s: %d samples had a reading that could not be taken (last at %s)\n", name, unk, unkat
                if (sfmax > 400000) printf "%s: whole-Mac open files reached %d\n", name, sfmax
                exit
            }
            printf "%s  %s to %s (%.1f h), %d samples\n", name, first, last, elapsed / 3600, n
            printf "  CPU             helper %.2f s + its tools %.2f s = %.2f s, %.4f%% of one core\n", cpu, tools, cpu + tools, share
            printf "  per request     %.3f s over %d requests (%d tools started)\n", each, reqs, ran
            printf "  largest step    %.2f CPU s between two samples, at %s (%d requests, %d tools)\n", spike, spikeat, spikereqs, spiketools
            printf "  footprint       %.1f to %.1f MB\n", fpmin / 1024, fpmax / 1024
            printf "  open files      %d to %d (helper), %d to %d (whole Mac)\n", fdmin, fdmax, sfmin, sfmax
            printf "  threads         up to %d\n", thmax
            printf "  status time     median %d ms, slowest %d ms at %s\n", median, tookmax, tookat
            printf "  failed sampler requests %d, restarts %d, samples with helper down %d, samples with an unknown reading %d\n", fails + 0, restarts + 0, down + 0, unk + 0
            if (over) printf "  statuses of 1 s or more (%d), with the slow readings in ms:\n%s", over, overlist
        }'
done

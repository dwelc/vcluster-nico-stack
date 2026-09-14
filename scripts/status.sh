#!/usr/bin/env bash
# status.sh <context> <project-namespace> <stackinstance>: phase, then one line per task.
set -euo pipefail
K="kubectl --context ${1:?context} -n ${2:?namespace}"
${K} get stackinstances.management.loft.sh "${3:?name}" -o json | jq -r '
  "\(.metadata.name)\t\(.status.phase)\t\(.status.conditions[]? | select(.type=="Ready") | .reason + " " + (.message // ""))",
  (.status.tasks[]? | "  \(.name)\t\(.phase)\t\(.reason // "")\t\(.message // "" | .[0:120])")'

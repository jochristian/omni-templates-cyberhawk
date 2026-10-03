#!/usr/bin/env bash
# Re-applies tier-3 soft zone preference after it drifts.
#
# `preferredDuringSchedulingIgnoredDuringExecution` is read once, at scheduling
# time. A node reboot or cordon parks those pods on the wrong zone and nothing
# ever moves them back (2026-10-03: 10 of 11 sat on the blix worker for weeks).
#
# Fix is a `rollout restart`, not an eviction: at replicas=1 the new pod starts
# before the old one goes, so there is no downtime, and no PDB/local-storage
# handling is needed. One restart per Deployment per run.
set -euo pipefail

DRY_RUN="${DRY_RUN:-false}"
# Skip pods younger than this, so a run can't hammer a workload that keeps
# landing back on the wrong zone (target node full, for instance).
MIN_AGE_HOURS="${MIN_AGE_HOURS:-2}"

# BusyBox date has no relative -d, so do the arithmetic here.
cutoff=$(( $(date -u +%s) - MIN_AGE_HOURS * 3600 ))

zones=$(kubectl get nodes -o json)

# Zones that currently have at least one Ready, schedulable node. Restarting
# towards a zone that is down would just move the pod right back.
usable=$(jq -r '.items[]
  | select((.spec.unschedulable // false) | not)
  | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))
  | .metadata.labels["topology.kubernetes.io/zone"] // empty' <<<"$zones" | sort -u)

node_zone() { jq -r --arg n "$1" '.items[] | select(.metadata.name == $n)
  | .metadata.labels["topology.kubernetes.io/zone"] // ""' <<<"$zones"; }

kubectl get pods -A -o json | jq -r --argjson maxstart "$cutoff" '
  .items[]
  | select(.status.phase == "Running")
  | select((.metadata.ownerReferences[0].kind // "") == "ReplicaSet")
  | select((.status.startTime | fromdateiso8601) < $maxstart)
  | . as $p
  | [.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[]?
      | select(.preference.matchExpressions[]?.key == "topology.kubernetes.io/zone")
      | .preference.matchExpressions[].values[]] as $want
  | select($want | length > 0)
  | [$p.metadata.namespace, $p.metadata.name, $p.spec.nodeName,
     $p.metadata.ownerReferences[0].name, ($want | join(","))] | @tsv' |
  while IFS=$'\t' read -r ns pod node rs want; do
    here=$(node_zone "$node")
    [[ ",$want," == *",$here,"* ]] && continue

    # Restart only towards a zone that can actually take the pod right now.
    target=""
    for z in ${want//,/ }; do
      grep -qx "$z" <<<"$usable" && { target=$z; break; }
    done
    [[ -z "$target" ]] && { echo "$ns/$pod: on '$here', wants '$want', none usable"; continue; }

    # ReplicaSet name is the Deployment name plus a pod-template hash.
    deploy=$(kubectl -n "$ns" get rs "$rs" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null) || continue
    [[ -z "$deploy" ]] && continue

    echo "$ns/$deploy: pod on '$here', prefers '$want' -> rollout restart"
    [[ "$DRY_RUN" == "true" ]] || kubectl -n "$ns" rollout restart "deploy/$deploy"
  done

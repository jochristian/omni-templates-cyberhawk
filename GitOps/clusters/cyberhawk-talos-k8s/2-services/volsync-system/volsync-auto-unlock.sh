#!/usr/bin/env bash
# Clears orphaned restic locks by asking VolSync to run `restic unlock` on the
# next attempt of any backup whose mover Job is failing.
#
# Why: a mover killed mid-run (node reboot, rollout) leaves its exclusive lock
# behind. Every later run still saves a snapshot but fails at `forget`, so the
# ReplicationSource retries forever and retention never runs.
#
# How: setting spec.restic.unlock to a new value makes VolSync prepend a plain
# `restic unlock` (stale locks only: >30 min old) to every mover attempt until
# a sync succeeds. Changing it rewrites the Job template, which VolSync applies
# by deleting and recreating the Job -- killing any running mover and creating
# the very orphan we are cleaning up. So only act while the Job has failed and
# has NO active pod (it is sitting in its retry backoff).
set -euo pipefail

DRY_RUN="${DRY_RUN:-false}"

kubectl get replicationsources.volsync.backube -A -o json |
  jq -r '.items[] | select(.spec.restic != null)
    | [.metadata.namespace, .metadata.name,
       (.spec.restic.unlock // ""), (.status.restic.lastUnlocked // "")] | @tsv' |
  while IFS=$'\t' read -r ns name unlock last_unlocked; do
    # An unlock is already pending; VolSync keeps retrying it until a sync succeeds.
    if [[ -n "$unlock" && "$unlock" != "$last_unlocked" ]]; then
      echo "$ns/$name: unlock '$unlock' already pending"
      continue
    fi

    job=$(kubectl -n "$ns" get job "volsync-src-$name" -o json 2>/dev/null) || continue
    failed=$(jq '.status.failed // 0' <<<"$job")
    active=$(jq '.status.active // 0' <<<"$job")

    if (( failed > 0 && active == 0 )); then
      value="auto-$(date -u +%Y%m%dT%H%M%SZ)"
      echo "$ns/$name: mover failed ${failed}x, none active -> unlock=$value"
      if [[ "$DRY_RUN" != "true" ]]; then
        kubectl -n "$ns" patch replicationsources.volsync.backube "$name" \
          --type merge -p "{\"spec\":{\"restic\":{\"unlock\":\"$value\"}}}"
      fi
    elif (( failed > 0 )); then
      echo "$ns/$name: mover failed ${failed}x but a pod is active; next run"
    fi
  done

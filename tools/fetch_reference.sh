#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
commit=cd895d17ce8a97d883c10f87b26c7356d5e0ccb1
path=research/pymobiledevice3
if [[ -e "$path" ]]; then
  [[ "$(git -C "$path" rev-parse HEAD)" == "$commit" ]] || { echo 'Existing reference has a different commit; not modifying it.' >&2; exit 1; }
  [[ -z "$(git -C "$path" status --porcelain)" ]] || { echo 'Existing reference has local changes; not modifying it.' >&2; exit 1; }
else
  mkdir -p research
  git clone --no-checkout --filter=blob:none https://github.com/doronz88/pymobiledevice3.git "$path"
  git -C "$path" fetch --depth 1 origin "$commit"
  git -C "$path" checkout --detach "$commit"
fi
printf 'Reference verified: %s\n' "$commit"

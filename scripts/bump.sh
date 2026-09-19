#!/bin/sh
# Bump the version for a release. Usage: bump.sh [patch|minor|major]  (default: patch)
# Ordinary commits must NOT run this — the version changes only at a release.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/.claude-plugin/plugin.json"
market="$root/.claude-plugin/marketplace.json"

cur=$(jq -r '.version' "$manifest")
major=${cur%%.*}
rest=${cur#*.}
minor=${rest%%.*}
patch=${rest#*.}

case "${1:-patch}" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "usage: bump.sh [patch|minor|major]" >&2; exit 2 ;;
esac
new="$major.$minor.$patch"

jq --arg v "$new" '.version = $v' "$manifest" > "$manifest.tmp" && mv "$manifest.tmp" "$manifest"
jq --arg v "$new" '.plugins[0].version = $v' "$market" > "$market.tmp" && mv "$market.tmp" "$market"

printf '%s\n' "$new"
printf 'next: git commit -am "chore: release %s" && git tag v%s && git push --follow-tags\n' "$new" "$new"

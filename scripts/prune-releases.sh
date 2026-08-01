#!/usr/bin/env bash
set -euo pipefail

REPO="${PRUNE_REPO:-MKITConsulting/ts-desktop-releases}"
KEEP_RECENT="${PRUNE_KEEP_RECENT:-10}"
KEEP_MONTHS="${PRUNE_KEEP_MONTHS:-12}"
MIN_VERSION="${PRUNE_MIN_VERSION:-}"
APPLY=0
ASSUME_YES=0
PRUNE_DRAFTS=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${PRUNE_LOG_DIR:-${SCRIPT_DIR%/scripts}/audit}"

TMPDIR_SELF=""
cleanup() { [ -n "$TMPDIR_SELF" ] && rm -rf "$TMPDIR_SELF"; }
trap cleanup EXIT

usage() {
  cat <<'EOF'
prune-releases.sh — prune GitHub release ASSETS, keep release entries + notes + tags.

Deletes only binary assets of superseded releases. The release page, its notes and
its tag always survive, so the changelog history stays intact and permalinks to the
release page keep working. Only the download links die.

USAGE
  scripts/prune-releases.sh [options]

OPTIONS
  --apply              Actually delete. Without this flag the script is a DRY RUN.
  --yes                Skip the interactive confirmation (only with --apply).
  --repo OWNER/NAME    Target repository. Default: MKITConsulting/ts-desktop-releases
  --keep-recent N      Keep assets of the N newest stable releases. Default: 10
  --keep-months M      Keep assets of everything published within the last M months. Default: 12
  --min-version X.Y.Z  Hard floor: prune assets of every release below X.Y.Z even when a
                       keep rule would otherwise hold it. Use when older builds carry a
                       vulnerability that must stop being downloadable.
  --prune-drafts       Additionally DELETE stale draft releases outright (draft version
                       <= newest published version). Drafts have no audit value.
  --log-dir DIR        Where to write the audit log on --apply. Default: audit/ next to
                       this script, so the trail lands in the repository by default.
  -h, --help           This text.

RETENTION POLICY
  A release keeps its assets when ANY of these holds:
    updater-latest   it is what /releases/latest resolves to (auto-update depends on it)
    recent           among the N newest stable releases
    minor-tip        highest patch of its MAJOR.MINOR line (rollback anchor per line)
    fresh            published within the last M months
  Everything else is an asset-prune candidate. Releases with an unparseable tag are
  never touched.

  --min-version overrides recent, minor-tip and fresh — a release below the floor is
  pruned whatever else applies. updater-latest is the one exception: the release that
  /releases/latest resolves to is never pruned, because auto-update depends on its
  assets. Passing a floor above that release is rejected rather than honoured.

EXAMPLES
  scripts/prune-releases.sh
  scripts/prune-releases.sh --keep-recent 15 --keep-months 18
  scripts/prune-releases.sh --min-version 0.9.4 --keep-recent 5 --keep-months 0
  scripts/prune-releases.sh --apply
  scripts/prune-releases.sh --apply --prune-drafts
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply)        APPLY=1; shift ;;
      --yes)          ASSUME_YES=1; shift ;;
      --prune-drafts) PRUNE_DRAFTS=1; shift ;;
      --repo)         REPO="${2:?--repo needs a value}"; shift 2 ;;
      --keep-recent)  KEEP_RECENT="${2:?--keep-recent needs a value}"; shift 2 ;;
      --keep-months)  KEEP_MONTHS="${2:?--keep-months needs a value}"; shift 2 ;;
      --min-version)  MIN_VERSION="${2:?--min-version needs a value}"; shift 2 ;;
      --log-dir)      LOG_DIR="${2:?--log-dir needs a value}"; shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      *)              die "unknown option: $1 (try --help)" ;;
    esac
  done
  case "$KEEP_RECENT" in ''|*[!0-9]*) die "--keep-recent must be a non-negative integer" ;; esac
  case "$KEEP_MONTHS" in ''|*[!0-9]*) die "--keep-months must be a non-negative integer" ;; esac
  MIN_VERSION="${MIN_VERSION#v}"
  if [ -n "$MIN_VERSION" ]; then
    case "$MIN_VERSION" in
      [0-9]*.[0-9]*.[0-9]*) ;;
      *) die "--min-version must look like X.Y.Z (got '$MIN_VERSION')" ;;
    esac
  fi
  [ "$ASSUME_YES" -eq 1 ] && [ "$APPLY" -eq 0 ] && die "--yes is meaningless without --apply"
  return 0
}

min_version_json() {
  [ -z "$MIN_VERSION" ] && { printf 'null'; return 0; }
  printf '%s' "$MIN_VERSION" | jq -R 'split(".") | map(tonumber)'
}

assert_floor_below_latest() {
  local latest_tag="$1"
  [ -z "$MIN_VERSION" ] && return 0
  printf '%s' "${latest_tag#v}" | jq -Re \
    --argjson floor "$(min_version_json)" \
    'split("-")[0] | split(".") | map(tonumber) | . >= $floor' >/dev/null 2>&1 \
    || die "--min-version $MIN_VERSION is above the updater-latest release $latest_tag — refusing to prune everything"
}

preflight() {
  command -v gh >/dev/null 2>&1 || die "gh CLI not found — https://cli.github.com"
  command -v jq >/dev/null 2>&1 || die "jq not found — brew install jq"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"
  gh repo view "$REPO" >/dev/null 2>&1 || die "cannot access repository: $REPO"
}

resolve_latest_tag() {
  local tag
  tag="$(gh api "repos/${REPO}/releases/latest" --jq '.tag_name' 2>/dev/null)" \
    || die "cannot resolve /releases/latest for $REPO — refusing to prune blind"
  [ -n "$tag" ] || die "/releases/latest returned an empty tag — refusing to prune blind"
  printf '%s' "$tag"
}

fetch_releases() {
  gh api --paginate "repos/${REPO}/releases" \
    --jq '.[] | {tag_name, draft, prerelease, published_at, created_at, assets: [.assets[] | {name, size}]}' \
    | jq -s '.'
}

build_plan() {
  local releases_json="$1" latest_tag="$2"
  printf '%s' "$releases_json" | jq \
    --arg latestTag "$latest_tag" \
    --argjson keepRecent "$KEEP_RECENT" \
    --argjson keepMonths "$KEEP_MONTHS" \
    --argjson minVersion "$(min_version_json)" '
    def parts: (.tag_name | ltrimstr("v") | split("-")[0] | split("."));
    def ok:    (parts | length) == 3 and (parts | map(test("^[0-9]+$")) | all);
    def sv:    parts | map(tonumber);
    def bytes: ([.assets[].size] | add // 0);

    . as $all
    | ($all | map(select(.draft | not)))                       as $published
    | ($published | map(select(ok | not)) | map(.tag_name))    as $unparseable
    | ($published | map(select(ok)) | sort_by(sv) | reverse)   as $desc
    | ($desc | map(select(.prerelease | not)))                 as $stable
    | ($stable[0:$keepRecent] | map(.tag_name))                as $recent
    | ($stable | group_by(sv[0:2]) | map(max_by(sv[2]).tag_name)) as $minorTips
    | (now - ($keepMonths * 2629800))                          as $cutoff
    | ($desc | map(select((.published_at // "1970-01-01T00:00:00Z" | fromdateiso8601) > $cutoff) | .tag_name)) as $fresh
    | ($stable | map(sv) | max)                                as $maxSv
    | ($recent + $minorTips + $fresh + [$latestTag] | unique)  as $keep

    | {
        repo_latest: $latestTag,
        unparseable: $unparseable,
        releases: ($desc | map(
            . as $r
            | ([ (if $r.tag_name == $latestTag      then "updater-latest" else empty end),
                 (if ($recent    | index($r.tag_name)) then "recent"      else empty end),
                 (if ($minorTips | index($r.tag_name)) then "minor-tip"   else empty end),
                 (if ($fresh     | index($r.tag_name)) then "fresh"       else empty end) ]) as $why
            | (($minVersion != null) and (sv < $minVersion)
               and ($r.tag_name != $latestTag))                as $belowMin
            | { tag:        $r.tag_name,
                published:  (($r.published_at // "")[0:10]),
                prerelease: $r.prerelease,
                count:      ($r.assets | length),
                bytes:      ($r | bytes),
                decision:   (if $r.tag_name == $latestTag then "KEEP"
                             elif ($r.assets | length) == 0 then "EMPTY"
                             elif $belowMin then "PRUNE"
                             elif ($why | length) > 0 then "KEEP"
                             else "PRUNE" end),
                why:        (if $belowMin then
                               (if ($why | length) > 0
                                then "below-min (overrides \($why | join(",")))"
                                else "below-min" end)
                             else ($why | join(",")) end),
                assets:     [$r.assets[].name] }
          )),
        drafts: ($all | map(select(.draft)) | map(
            { tag:       .tag_name,
              published: ((.created_at // .published_at // "")[0:10]),
              count:     (.assets | length),
              bytes:     bytes,
              stale:     (if ok then ((sv) <= $maxSv) else false end) }
          ))
      }
  '
}

human_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.2f GB", b/1073741824;
    else if (b >= 1048576) printf "%.1f MB", b/1048576;
    else if (b >= 1024) printf "%.1f KB", b/1024;
    else printf "%d B", b;
  }'
}

render_plan() {
  local plan="$1"

  printf '\n'
  printf 'Repository      %s\n' "$REPO"
  printf 'Updater latest  %s  (assets pinned, never pruned)\n' "$(jq -r '.repo_latest' <<<"$plan")"
  printf 'Policy          keep %s newest stable + minor-line tips + last %s months\n' \
    "$KEEP_RECENT" "$KEEP_MONTHS"
  if [ -n "$MIN_VERSION" ]; then
    printf 'Hard floor      %s  (overrides every keep rule except updater-latest)\n' "$MIN_VERSION"
  fi
  printf '\n'

  printf '%-12s %-12s %6s %12s  %-8s %s\n' TAG PUBLISHED ASSETS SIZE ACTION REASON
  printf '%s\n' "$(printf '%.0s-' $(seq 1 78))"
  jq -r '.releases[] | [.tag, .published, .count, .bytes, .decision, .why] | @tsv' <<<"$plan" \
  | while IFS=$'\t' read -r tag published count bytes decision why; do
      printf '%-12s %-12s %6s %12s  %-8s %s\n' \
        "$tag" "$published" "$count" "$(human_bytes "$bytes")" "$decision" "$why"
    done

  local prune_n prune_bytes keep_bytes
  prune_n="$(jq '[.releases[] | select(.decision == "PRUNE")] | length' <<<"$plan")"
  prune_bytes="$(jq '[.releases[] | select(.decision == "PRUNE") | .bytes] | add // 0' <<<"$plan")"
  keep_bytes="$(jq '[.releases[] | select(.decision == "KEEP") | .bytes] | add // 0' <<<"$plan")"

  printf '\n'
  printf 'Keep      %s releases, %s\n' \
    "$(jq '[.releases[] | select(.decision == "KEEP")] | length' <<<"$plan")" "$(human_bytes "$keep_bytes")"
  printf 'Prune     %s releases, %s reclaimed (entries + notes + tags survive)\n' \
    "$prune_n" "$(human_bytes "$prune_bytes")"

  local unparseable
  unparseable="$(jq -r '.unparseable | join(", ")' <<<"$plan")"
  [ -n "$unparseable" ] && printf 'Skipped   unparseable tags, never touched: %s\n' "$unparseable"

  local stale_n
  stale_n="$(jq '[.drafts[] | select(.stale)] | length' <<<"$plan")"
  if [ "$stale_n" -gt 0 ]; then
    printf '\nStale drafts (superseded by a published release):\n'
    jq -r '.drafts[] | select(.stale) | [.tag, .published, .count, .bytes] | @tsv' <<<"$plan" \
    | while IFS=$'\t' read -r tag published count bytes; do
        printf '  %-12s %-12s %s assets  %s\n' "$tag" "$published" "$count" "$(human_bytes "$bytes")"
      done
    if [ "$PRUNE_DRAFTS" -eq 1 ]; then
      printf '  --prune-drafts is set: these releases will be DELETED entirely.\n'
    else
      printf '  Pass --prune-drafts to delete them entirely.\n'
    fi
  fi
}

confirm_or_abort() {
  local plan="$1" prune_n draft_n
  prune_n="$(jq '[.releases[] | select(.decision == "PRUNE")] | length' <<<"$plan")"
  draft_n=0
  [ "$PRUNE_DRAFTS" -eq 1 ] && draft_n="$(jq '[.drafts[] | select(.stale)] | length' <<<"$plan")"

  if [ "$prune_n" -eq 0 ] && [ "$draft_n" -eq 0 ]; then
    printf '\nNothing to do.\n'
    exit 0
  fi

  [ "$ASSUME_YES" -eq 1 ] && return 0

  printf '\nThis deletes %s release asset sets and %s draft releases from %s.\n' \
    "$prune_n" "$draft_n" "$REPO"
  printf 'Deleted assets cannot be restored. Type PRUNE to continue: '
  local answer
  read -r answer
  [ "$answer" = "PRUNE" ] || die "aborted"
}

execute_plan() {
  local plan="$1"
  local stamp log
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  log="${LOG_DIR%/}/prune-releases-${stamp}.log"
  mkdir -p "${LOG_DIR%/}"

  printf 'repo=%s date=%s latest=%s\n' \
    "$REPO" "$stamp" "$(jq -r '.repo_latest' <<<"$plan")" >"$log"
  printf 'policy=keep-recent:%s,keep-months:%s,min-version:%s,prune-drafts:%s\n' \
    "$KEEP_RECENT" "$KEEP_MONTHS" "${MIN_VERSION:-none}" "$PRUNE_DRAFTS" >>"$log"

  local failures=0
  while IFS=$'\t' read -r tag asset; do
    [ -z "$tag" ] && continue
    printf 'deleting asset %s :: %s\n' "$tag" "$asset"
    if gh release delete-asset "$tag" "$asset" --repo "$REPO" --yes >/dev/null 2>&1; then
      printf 'deleted-asset\t%s\t%s\n' "$tag" "$asset" >>"$log"
    else
      printf 'FAILED-asset\t%s\t%s\n' "$tag" "$asset" >>"$log"
      printf '  failed: %s :: %s\n' "$tag" "$asset" >&2
      failures=$((failures + 1))
    fi
  done < <(jq -r '.releases[] | select(.decision == "PRUNE") | .tag as $t | .assets[] | [$t, .] | @tsv' <<<"$plan")

  if [ "$PRUNE_DRAFTS" -eq 1 ]; then
    while IFS= read -r tag; do
      [ -z "$tag" ] && continue
      printf 'deleting draft release %s\n' "$tag"
      if gh release delete "$tag" --repo "$REPO" --yes >/dev/null 2>&1; then
        printf 'deleted-draft\t%s\n' "$tag" >>"$log"
      else
        printf 'FAILED-draft\t%s\n' "$tag" >>"$log"
        printf '  failed to delete draft: %s\n' "$tag" >&2
        failures=$((failures + 1))
      fi
    done < <(jq -r '.drafts[] | select(.stale) | .tag' <<<"$plan")
  fi

  local verify
  verify="$(gh api "repos/${REPO}/releases/latest" --jq '[.assets[].name] | length' 2>/dev/null || echo 0)"
  printf '\nAudit log: %s\n' "$log"
  printf 'Verify:    /releases/latest still carries %s assets\n' "$verify"
  [ "$verify" -eq 0 ] && die "POST-CHECK FAILED: latest release has no assets — auto-update is broken"

  if [ "$failures" -gt 0 ]; then
    die "$failures operation(s) failed — see $log"
  fi
  printf 'Done.\n'
}

main() {
  parse_args "$@"
  preflight
  TMPDIR_SELF="$(mktemp -d)"

  local latest_tag releases_json plan
  latest_tag="$(resolve_latest_tag)"
  assert_floor_below_latest "$latest_tag"
  releases_json="$(fetch_releases)"
  plan="$(build_plan "$releases_json" "$latest_tag")"

  render_plan "$plan"

  if [ "$APPLY" -eq 1 ]; then
    confirm_or_abort "$plan"
    execute_plan "$plan"
  else
    printf '\nDRY RUN — nothing was deleted. Re-run with --apply to execute.\n'
  fi
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# Prepare release changelog and contributors for a new version.
# PRs are categorized using the table in the PR body (Type? and Category? from PULL_REQUEST_TEMPLATE).
# PRs with Type or Category "Other" are treated as anomalies and block file updates.
#
# Usage: run from repo root with env:
#   PREVIOUS_REF      - Git ref to compare from (tag, branch, or commit SHA, e.g. 9.0.2)
#   TARGET_REF        - Git ref to compare to (tag, branch, or commit SHA), default: HEAD
#   NEXT_VERSION      - New version string (e.g. 9.1.0 Beta 1)
#   RELEASE_DATE      - Date for the new release (YYYY-MM-DD), default: today
#   GH_REPOSITORY     - owner/repo
#   FALLBACK_REPOSITORY - optional owner/repo used to resolve PRs not found in GH_REPOSITORY
#                         (e.g. when GH_REPOSITORY is a private mirror whose history references
#                         PRs merged in the upstream repository)

PREVIOUS_REF="${PREVIOUS_REF:?PREVIOUS_REF is required}"
TARGET_REF="${TARGET_REF:-HEAD}"
NEXT_VERSION="${NEXT_VERSION:?NEXT_VERSION is required}"
RELEASE_DATE="${RELEASE_DATE:-$(date +%Y-%m-%d)}"
REPO="${GH_REPOSITORY:?GH_REPOSITORY is required}"
FALLBACK_REPO="${FALLBACK_REPOSITORY:-}"
# No fallback needed when it points to the repository itself
[[ "$FALLBACK_REPO" == "$REPO" ]] && FALLBACK_REPO=""

# -----------------------------------------------------------------------------
# Map Category code (template) -> Changelog section name
# -----------------------------------------------------------------------------
category_to_name() {
  local raw
  raw=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
  case "$raw" in
    bo) echo "Back Office" ;;
    fo) echo "Front Office" ;;
    co) echo "Core" ;;
    in) echo "Installer" ;;
    ws) echo "Web Services" ;;
    te) echo "Tests" ;;
    lo) echo "Localization" ;;
    me) echo "Merge" ;;
    pm) echo "Project management" ;;
    *) echo "Other" ;;
  esac
}

# -----------------------------------------------------------------------------
# Map Type (template) -> Changelog type name
# -----------------------------------------------------------------------------
type_to_name() {
  local raw
  raw=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
  case "$raw" in
    bugfix|"bug fix") echo "Bug fix" ;;
    improvement) echo "Improvement" ;;
    newfeature|"new feature") echo "New feature" ;;
    refacto|refactoring) echo "Refactoring" ;;
    *) echo "Other" ;;
  esac
}

# -----------------------------------------------------------------------------
# Extract second column (Answers) from table row matching row_label (e.g. Type?, Category?).
# -----------------------------------------------------------------------------
parse_table_cell() {
  local body="$1"
  local row_label="$2"
  local row
  row=$(echo "$body" | grep -F "| ${row_label}" | head -1 || true)
  if [[ -n "$row" ]]; then
    echo "$row" | tr -d '\r' | awk -F'|' '{
      for (i=1;i<=NF;i++) { gsub(/^[ \t]+|[ \t]+$/,"",$i) }
      for (i=1;i<=NF;i++) { if ($i != "" && ++n == 2) { print $i; exit } }
    }'
  fi
}

# -----------------------------------------------------------------------------
# Use GitHub compare API to list the merge commits between PREVIOUS_REF and
# TARGET_REF. Works identically on Linux and macOS (no git log needed).
# The API accepts tags, branches, and commit SHAs as refs.
# -----------------------------------------------------------------------------
echo "Comparing ${PREVIOUS_REF}...${TARGET_REF} in ${REPO} via GitHub API..."

# --paginate emits one JSON document per page, jq -s merges them into one array.
MERGE_COMMITS_JSON=$(gh api "repos/${REPO}/compare/${PREVIOUS_REF}...${TARGET_REF}" \
  --paginate \
  -q '[.commits[] | select(.parents | length > 1) | {sha: .sha, message: .commit.message}]' 2>/dev/null \
  | jq -s 'add // []' 2>/dev/null || echo '[]')

# SHAs of the merge commits of the range, used to verify that a resolved PR was
# really merged here (see pr_merged_in_range).
MERGE_SHAS_FILE=$(mktemp)
echo "$MERGE_COMMITS_JSON" | jq -r '.[].sha' > "$MERGE_SHAS_FILE"
echo "Found $(wc -l < "$MERGE_SHAS_FILE" | tr -d ' ') merge commit(s)."

# -----------------------------------------------------------------------------
# List the PRs of REPO that GitHub associates with the given commits.
# This is authoritative: a number obtained this way always designates a PR of
# REPO, unlike a number parsed from a commit message, which may come from a merge
# commit created in another repository (private security mirror, imported
# history, ...) and collide with an unrelated PR of REPO.
# Commits are queried in batches through the GraphQL API to keep the number of
# requests low (one request per 100 commits).
# -----------------------------------------------------------------------------
associated_pr_numbers() {
  local sha_file="$1"
  local owner="${REPO%%/*}"
  local name="${REPO##*/}"
  local batch_dir batch query sha i

  [[ -s "$sha_file" ]] || return 0

  batch_dir=$(mktemp -d)
  split -l 100 "$sha_file" "${batch_dir}/batch_"
  for batch in "${batch_dir}"/batch_*; do
    query="${batch}.graphql"
    {
      echo "{ repository(owner: \"${owner}\", name: \"${name}\") {"
      i=0
      while read -r sha; do
        [[ -z "$sha" ]] && continue
        echo "  c${i}: object(expression: \"${sha}\") { ... on Commit { associatedPullRequests(first: 10) { nodes { number repository { nameWithOwner } } } } }"
        i=$((i + 1))
      done < "$batch"
      echo "} }"
    } > "$query"
    gh api graphql -F query=@"$query" -q "
      [.data.repository[]
        | select(. != null)
        | .associatedPullRequests.nodes[]
        | select(.repository.nameWithOwner == \"${REPO}\")
        | .number] | .[]" 2>/dev/null || true
  done
  rm -rf "$batch_dir"
}

# -----------------------------------------------------------------------------
# Fetch a PR (title, author, merge commit) from a given repository.
# -----------------------------------------------------------------------------
fetch_pr() {
  gh pr view "$1" --repo "$2" --json number,title,author,mergeCommit -q '.' 2>/dev/null || echo ''
}

# -----------------------------------------------------------------------------
# True when the PR was merged by one of the merge commits of the range.
# Rejects PRs that are still open and PRs whose number was borrowed from another
# repository.
# -----------------------------------------------------------------------------
pr_merged_in_range() {
  local merge_sha
  merge_sha=$(echo "$1" | jq -r '.mergeCommit.oid // ""')
  [[ -n "$merge_sha" ]] && grep -qxF "$merge_sha" "$MERGE_SHAS_FILE"
}

if [[ -z "$FALLBACK_REPO" ]]; then
  # Ask GitHub which PR of REPO introduced each merge commit.
  PR_NUMBERS=$(associated_pr_numbers "$MERGE_SHAS_FILE" | sort -n -u)
else
  # REPO is a private mirror: its history carries merge commits created in the
  # upstream repository, whose PR numbers exist only in the commit messages.
  # Association cannot be used here, so numbers are parsed and every PR resolved
  # in REPO is then checked against the merge commits of the range.
  PR_NUMBERS=$(echo "$MERGE_COMMITS_JSON" | jq -r '
    [.[] | .message
      | capture("Merge pull request #(?<n>[0-9]+)") .n
    ] | unique | .[]' 2>/dev/null || true)
fi

if [[ -z "$PR_NUMBERS" ]]; then
  echo "::error::No merged PRs found between ${PREVIOUS_REF} and ${TARGET_REF}."
  PRS_JSON="[]"
  PR_COUNT=0
else
  # Build PRS_JSON array by fetching title+author for each PR from the API.
  # PRs are searched in REPO first, then in FALLBACK_REPO (if configured); each entry
  # keeps track of the repository it was resolved in (used for API calls and URLs).
  PRS_JSON="[]"
  for number in $PR_NUMBERS; do
    pr_repo="$REPO"
    out_of_range=0
    pr_info=$(fetch_pr "$number" "$pr_repo")
    # A PR of REPO that was not merged by one of the merge commits of the range
    # does not belong to this release: the number comes from a merge commit
    # created in another repository and happens to exist in REPO as well.
    if [[ -n "$pr_info" ]] && ! pr_merged_in_range "$pr_info"; then
      out_of_range=1
      pr_info=''
    fi
    if [[ -z "$pr_info" && -n "$FALLBACK_REPO" ]]; then
      pr_repo="$FALLBACK_REPO"
      pr_info=$(fetch_pr "$number" "$pr_repo")
      [[ -n "$pr_info" ]] && out_of_range=0
    fi
    if [[ -n "$pr_info" ]]; then
      PRS_JSON=$(echo "$PRS_JSON" | jq --argjson pr "$pr_info" --arg repo "$pr_repo" \
        '. + [($pr | del(.mergeCommit)) + {repo: $repo}]')
    elif [[ "$out_of_range" -eq 1 ]]; then
      echo "::notice::Ignoring PR #${number} of ${REPO}: not merged between ${PREVIOUS_REF} and ${TARGET_REF}." >&2
      continue
    else
      if [[ -n "$FALLBACK_REPO" ]]; then
        echo "::error::Could not fetch PR #${number} (searched in ${REPO} and ${FALLBACK_REPO})." >&2
      else
        echo "::error::Could not fetch PR #${number}." >&2
      fi
      exit 1
    fi
  done
  PR_COUNT=$(echo "$PRS_JSON" | jq 'length')
  echo "Found ${PR_COUNT} merged PR(s)."
fi

# Order of sections (as in docs/CHANGELOG.txt)
CATEGORY_ORDER=( "Back Office" "Front Office" "Core" "Installer" "Web Services" "Localization" "Tests" "Other" )
TYPE_ORDER=( "New feature" "Improvement" "Bug fix" "Refactoring" "Other" )

CATEGORIZED_FILE=$(mktemp)
CATEGORIZED_FORMATTED_FILE=$(mktemp)
ERRORS_FILE=$(mktemp)
trap 'rm -f "$CATEGORIZED_FILE" "$CATEGORIZED_FORMATTED_FILE" "$ERRORS_FILE" "$MERGE_SHAS_FILE"' EXIT

# -----------------------------------------------------------------------------
# Fetch body + milestone per PR, parse Type?/Category?, collect errors (Other, title, milestone)
# -----------------------------------------------------------------------------
idx=0
while read -r pr; do
  idx=$((idx + 1))
  number=$(echo "$pr" | jq -r '.number')
  echo "- Processing PR ${idx}/${PR_COUNT} (#${number})..." >&2

  title=$(echo "$pr" | jq -r '.title | gsub("\n"; " ")')
  author=$(echo "$pr" | jq -r '.author.login')
  pr_repo=$(echo "$pr" | jq -r '.repo')
  pr_data=$(gh pr view "$number" --repo "$pr_repo" --json body,milestone -q '.' 2>/dev/null || echo '{}')
  body=$(echo "$pr_data" | jq -r '.body // ""')
  milestone=$(echo "$pr_data" | jq -r '.milestone.title // ""')

  type_raw=$(parse_table_cell "$body" "Type")
  category_raw=$(parse_table_cell "$body" "Category")
  type_name=$(type_to_name "$type_raw")
  category_name=$(category_to_name "$category_raw")
  [[ -z "$type_name" ]] && type_name="Other"
  [[ -z "$category_name" ]] && category_name="Other"

  # Collect reasons for this PR
  reasons=()
  [[ "$category_name" == "Other" ]] && reasons+=("Invalid or missing Category in PR body")
  [[ "$type_name" == "Other" ]] && reasons+=("Invalid or missing Type in PR body")
  [[ ! "$title" =~ ^[[:space:]]*[[:upper:]] ]] && reasons+=("Title does not start with a capital letter")
  [[ -z "$milestone" || "$milestone" == "null" ]] && reasons+=("Milestone is empty")

  if [[ ${#reasons[@]} -gt 0 ]]; then
    echo "#${number}|${pr_repo}" >> "$ERRORS_FILE"
    echo "$title" >> "$ERRORS_FILE"
    for r in "${reasons[@]}"; do echo "$r" >> "$ERRORS_FILE"; done
    echo "---" >> "$ERRORS_FILE"
  fi

  line="    - #${number}: ${title} (by @${author})"
  # When a fallback repository is configured, REPO is a private mirror: its address must
  # never appear in the generated changelog, so PRs resolved in it are not linked.
  if [[ -n "$FALLBACK_REPO" && "$pr_repo" == "$REPO" ]]; then
    formatted_line="    - #${number}: ${title} (by [@${author}](https://github.com/${author}))"
  else
    formatted_line="    - [#${number}](https://github.com/${pr_repo}/pull/${number}): ${title} (by [@${author}](https://github.com/${author}))"
  fi
  echo "${category_name}|${type_name}|${line}" >> "$CATEGORIZED_FILE"
  echo "${category_name}|${type_name}|${formatted_line}" >> "$CATEGORIZED_FORMATTED_FILE"
done < <(echo "$PRS_JSON" | jq -c 'sort_by(-.number) | .[]')

# -----------------------------------------------------------------------------
# If any errors: list each PR with its reasons, then exit without updating files
# -----------------------------------------------------------------------------
if [[ -s "$ERRORS_FILE" ]]; then
  ERROR_COUNT=$(grep -c '^#' "$ERRORS_FILE" 2>/dev/null || echo 0)
  echo "---" >&2
  echo "Warning! ${ERROR_COUNT} PR(s) with errors. Files were not updated." >&2
  echo "" >&2
  echo "PRs in error:" >&2
  while IFS= read -r err_line; do
    if [[ "$err_line" == \#* ]]; then
      num_and_repo="${err_line#\#}"
      num="${num_and_repo%%|*}"
      err_repo="${num_and_repo##*|}"
      read -r tit || true
      echo "::error:: #${num}: ${tit}  (https://github.com/${err_repo}/pull/${num})" >&2
      while IFS= read -r reason_line; do
        [[ "$reason_line" == "---" ]] && break
        echo "  • $reason_line" >&2
      done
      echo "" >&2
    fi
  done < "$ERRORS_FILE"
  exit 1
fi

# -----------------------------------------------------------------------------
# Build changelog sections (category -> type -> entries), one newline between type blocks
# -----------------------------------------------------------------------------
CHANGELOG_SECTIONS=""
for cat in "${CATEGORY_ORDER[@]}"; do
  type_lines=""
  for typ in "${TYPE_ORDER[@]}"; do
    entries=$(grep -F "${cat}|${typ}|" "$CATEGORIZED_FILE" 2>/dev/null | cut -d'|' -f3- || true)
    if [[ -n "$entries" ]]; then
      type_lines="${type_lines}  - ${typ}:
${entries}
"
    fi
  done
  if [[ -n "$type_lines" ]]; then
    CHANGELOG_SECTIONS="${CHANGELOG_SECTIONS}- ${cat}:
${type_lines}"
  fi
done

CHANGELOG_SECTIONS="${CHANGELOG_SECTIONS%$'\n'}"

# Build formatted changelog sections (with GitHub URLs for PRs and authors)
CHANGELOG_FORMATTED=""
for cat in "${CATEGORY_ORDER[@]}"; do
  type_lines=""
  for typ in "${TYPE_ORDER[@]}"; do
    entries=$(grep -F "${cat}|${typ}|" "$CATEGORIZED_FORMATTED_FILE" 2>/dev/null | cut -d'|' -f3- || true)
    if [[ -n "$entries" ]]; then
      type_lines="${type_lines}  - ${typ}:
${entries}
"
    fi
  done
  if [[ -n "$type_lines" ]]; then
    CHANGELOG_FORMATTED="${CHANGELOG_FORMATTED}- ${cat}:
${type_lines}"
  fi
done
CHANGELOG_FORMATTED="${CHANGELOG_FORMATTED%$'\n'}"

# -----------------------------------------------------------------------------
# Update docs/CHANGELOG.txt
# If the version block already exists, replace it; otherwise insert after the header.
# A version block spans from its "####" line to just before the next "####" line.
# -----------------------------------------------------------------------------
CHANGELOG_BLOCK="####################################
#   v${NEXT_VERSION} - (${RELEASE_DATE})
####################################

${CHANGELOG_SECTIONS}"

CHANGELOG_FILE="docs/CHANGELOG.txt"
VERSION_HEADER="#   v${NEXT_VERSION} - "

# Find the line number of the existing version header (if any)
EXISTING_LINE=$(grep -n -F "$VERSION_HEADER" "$CHANGELOG_FILE" | head -1 | cut -d: -f1 || true)

if [[ -n "$EXISTING_LINE" ]]; then
  # The block starts one line before the header (the opening #### line)
  BLOCK_START=$((EXISTING_LINE - 1))
  # Skip past the closing #### line (EXISTING_LINE + 2), then find the next #### block
  SEARCH_FROM=$((EXISTING_LINE + 2))
  BLOCK_END=$(tail -n +"$SEARCH_FROM" "$CHANGELOG_FILE" \
    | grep -n '^####' | head -1 | cut -d: -f1 || true)
  if [[ -n "$BLOCK_END" ]]; then
    # BLOCK_END is relative to SEARCH_FROM, convert to absolute (exclusive)
    BLOCK_END=$((SEARCH_FROM - 1 + BLOCK_END))
  else
    # No next block found, replace until end of file
    BLOCK_END=$(($(wc -l < "$CHANGELOG_FILE") + 1))
  fi
  head -$((BLOCK_START - 1)) "$CHANGELOG_FILE" > "${CHANGELOG_FILE}.tmp"
  echo "" >> "${CHANGELOG_FILE}.tmp"
  echo "$CHANGELOG_BLOCK" >> "${CHANGELOG_FILE}.tmp"
  echo "" >> "${CHANGELOG_FILE}.tmp"
  tail -n +"$BLOCK_END" "$CHANGELOG_FILE" >> "${CHANGELOG_FILE}.tmp"
  echo "Replaced existing ${NEXT_VERSION} block in ${CHANGELOG_FILE}."
else
  # Insert new block after the header (line 24 = "Changelog for PrestaShop ...")
  head -24 "$CHANGELOG_FILE" > "${CHANGELOG_FILE}.tmp"
  echo "" >> "${CHANGELOG_FILE}.tmp"
  echo "$CHANGELOG_BLOCK" >> "${CHANGELOG_FILE}.tmp"
  echo "" >> "${CHANGELOG_FILE}.tmp"
  tail -n +26 "$CHANGELOG_FILE" >> "${CHANGELOG_FILE}.tmp"
  echo "Inserted new ${NEXT_VERSION} block in ${CHANGELOG_FILE}."
fi
mv "${CHANGELOG_FILE}.tmp" "$CHANGELOG_FILE"

# -----------------------------------------------------------------------------
# Update CONTRIBUTORS.md (merge existing + new from PRs, sort, dedupe case-insensitive)
# -----------------------------------------------------------------------------

# Blacklist of bot accounts to exclude from contributors
BLACKLISTED_LOGINS="ps-jarvis,dependabot"

PR_AUTHOR_LOGINS=$(echo "$PRS_JSON" | jq -r '[.[].author.login] | unique | .[]' | sort -f)

# Filter out blacklisted logins
NEW_CONTRIBUTOR_LOGINS=""
for login in $PR_AUTHOR_LOGINS; do
  if echo "$BLACKLISTED_LOGINS" | tr ',' '\n' | grep -qixF "$login"; then
    echo "Skipping blacklisted account @${login}." >&2
  else
    NEW_CONTRIBUTOR_LOGINS="${NEW_CONTRIBUTOR_LOGINS}${login}"$'\n'
  fi
done
NEW_CONTRIBUTOR_LOGINS=$(echo "$NEW_CONTRIBUTOR_LOGINS" | sed '/^$/d' | sort -f)

# Resolve GitHub usernames to real names (firstname lastname) via the GitHub API
# Stores both "login:name" pairs (for CSV output) and names only (for CONTRIBUTORS.md)
NEW_CONTRIBUTORS=""
NEW_CONTRIBUTORS_PAIRS=""
for login in $NEW_CONTRIBUTOR_LOGINS; do
  real_name=$(gh api "users/${login}" --jq '.name // empty' 2>/dev/null || true)
  if [[ -n "$real_name" ]]; then
    NEW_CONTRIBUTORS="${NEW_CONTRIBUTORS}${real_name}"$'\n'
    NEW_CONTRIBUTORS_PAIRS="${NEW_CONTRIBUTORS_PAIRS}${login}:${real_name}"$'\n'
  else
    echo "::notice::No real name for @${login}, using login instead." >&2
    NEW_CONTRIBUTORS="${NEW_CONTRIBUTORS}${login}"$'\n'
    NEW_CONTRIBUTORS_PAIRS="${NEW_CONTRIBUTORS_PAIRS}${login}:${login}"$'\n'
  fi
done
NEW_CONTRIBUTORS=$(echo "$NEW_CONTRIBUTORS" | sed '/^$/d' | sort -f)
NEW_CONTRIBUTORS_PAIRS=$(echo "$NEW_CONTRIBUTORS_PAIRS" | sed '/^$/d' | sort -f)

# Extract only the GitHub contributors section (before the SVN section)
SVN_LINE=$(grep -n '^SVN contributors:' CONTRIBUTORS.md | head -1 | cut -d: -f1 || true)
if [[ -n "$SVN_LINE" ]]; then
  EXISTING=$(head -$((SVN_LINE - 1)) CONTRIBUTORS.md | grep -E '^\s*-\s+' | sed 's/^\s*-\s*//' | grep -v '^$' || true)
  SVN_SECTION=$(tail -n +"$SVN_LINE" CONTRIBUTORS.md)
else
  EXISTING=$(grep -E '^\s*-\s+' CONTRIBUTORS.md 2>/dev/null | sed 's/^\s*-\s*//' | grep -v '^$' || true)
  SVN_SECTION=""
fi

ALL_CONTRIBUTORS=$( (echo "$EXISTING"; echo "$NEW_CONTRIBUTORS") | awk '{
  key = tolower($0)
  if (key != "" && !seen[key]++) print $0
}' | sort -f -u)

{
  echo "GitHub contributors:"
  echo "--------------------------------"
  echo "$ALL_CONTRIBUTORS" | while read -r name; do
    [[ -n "$name" ]] && echo "- $name"
  done
  if [[ -n "$SVN_SECTION" ]]; then
    echo ""
    echo "$SVN_SECTION"
  fi
} > CONTRIBUTORS.md
echo "Updated CONTRIBUTORS.md."

# -----------------------------------------------------------------------------
# Identify first-time contributors (PR authors not in the repo's full contributor list)
# Uses the GitHub API to get all historical contributors by login.
# -----------------------------------------------------------------------------
echo "Fetching all repository contributors from GitHub API..."
ALL_REPO_CONTRIBUTOR_LOGINS=$(gh api "repos/${REPO}/contributors" --paginate --jq '.[].login' 2>/dev/null | sort -f -u || true)

FIRST_TIME_LOGINS=""
for login in $NEW_CONTRIBUTOR_LOGINS; do
  if ! echo "$ALL_REPO_CONTRIBUTOR_LOGINS" | grep -qixF "$login"; then
    FIRST_TIME_LOGINS="${FIRST_TIME_LOGINS}${login}"$'\n'
  fi
done
FIRST_TIME_LOGINS=$(echo "$FIRST_TIME_LOGINS" | sed '/^$/d' | sort -f -u)

# Resolve first-time contributor logins to real names (reuse already resolved pairs)
FIRST_TIME_CONTRIBUTORS=""
FIRST_TIME_CONTRIBUTORS_PAIRS=""
for login in $FIRST_TIME_LOGINS; do
  # Look up from already resolved pairs
  pair=$(echo "$NEW_CONTRIBUTORS_PAIRS" | grep -i "^${login}:" | head -1 || true)
  if [[ -n "$pair" ]]; then
    name="${pair#*:}"
    FIRST_TIME_CONTRIBUTORS="${FIRST_TIME_CONTRIBUTORS}${name}"$'\n'
    FIRST_TIME_CONTRIBUTORS_PAIRS="${FIRST_TIME_CONTRIBUTORS_PAIRS}${pair}"$'\n'
  else
    real_name=$(gh api "users/${login}" --jq '.name // empty' 2>/dev/null || true)
    if [[ -n "$real_name" ]]; then
      FIRST_TIME_CONTRIBUTORS="${FIRST_TIME_CONTRIBUTORS}${real_name}"$'\n'
      FIRST_TIME_CONTRIBUTORS_PAIRS="${FIRST_TIME_CONTRIBUTORS_PAIRS}${login}:${real_name}"$'\n'
    else
      FIRST_TIME_CONTRIBUTORS="${FIRST_TIME_CONTRIBUTORS}${login}"$'\n'
      FIRST_TIME_CONTRIBUTORS_PAIRS="${FIRST_TIME_CONTRIBUTORS_PAIRS}${login}:${login}"$'\n'
    fi
  fi
done
FIRST_TIME_CONTRIBUTORS=$(echo "$FIRST_TIME_CONTRIBUTORS" | sed '/^$/d' | sort -f -u)
FIRST_TIME_CONTRIBUTORS_PAIRS=$(echo "$FIRST_TIME_CONTRIBUTORS_PAIRS" | sed '/^$/d' | sort -f -u)

# Format contributor outputs
CONTRIBUTORS_CSV=$(echo "$NEW_CONTRIBUTORS_PAIRS" | paste -sd ',' - | sed 's/,/, /g')
NEW_CONTRIBUTORS_CSV=$(echo "$FIRST_TIME_CONTRIBUTORS_PAIRS" | paste -sd ',' - | sed 's/,/, /g')

CONTRIBUTORS_GRID_INNER=$(echo "$NEW_CONTRIBUTOR_LOGINS" | sed '/^$/d' | sed 's/.*/"&"/' | paste -sd ' ' -)
CONTRIBUTORS_GRID="{{< contributors-grid ${CONTRIBUTORS_GRID_INNER} / >}}"

NEW_CONTRIBUTORS_GRID_INNER=$(echo "$FIRST_TIME_LOGINS" | sed '/^$/d' | sed 's/.*/"&"/' | paste -sd ' ' -)
NEW_CONTRIBUTORS_GRID="{{< contributors-grid ${NEW_CONTRIBUTORS_GRID_INNER} / >}}"

# -----------------------------------------------------------------------------
# Summary output
# -----------------------------------------------------------------------------
echo ""
echo "=== Changelog content ==="
echo "$CHANGELOG_SECTIONS"
echo ""
echo "=== Contributors ==="
echo "$CONTRIBUTORS_CSV"
if [[ -n "$FIRST_TIME_CONTRIBUTORS" ]]; then
  echo ""
  echo "=== New contributors ==="
  echo "$NEW_CONTRIBUTORS_CSV"
  echo "$NEW_CONTRIBUTORS_GRID"
fi

# Export to GITHUB_OUTPUT if running in GitHub Actions
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "contributors=${CONTRIBUTORS_CSV}" >> "$GITHUB_OUTPUT"
  echo "contributors_grid=${CONTRIBUTORS_GRID}" >> "$GITHUB_OUTPUT"
  echo "new_contributors=${NEW_CONTRIBUTORS_CSV}" >> "$GITHUB_OUTPUT"
  echo "new_contributors_grid=${NEW_CONTRIBUTORS_GRID}" >> "$GITHUB_OUTPUT"
  {
    echo "changelog<<CHANGELOG_EOF"
    echo "$CHANGELOG_SECTIONS"
    echo "CHANGELOG_EOF"
  } >> "$GITHUB_OUTPUT"
  {
    echo "changelog_formatted<<CHANGELOG_FORMATTED_EOF"
    echo "$CHANGELOG_FORMATTED"
    echo "CHANGELOG_FORMATTED_EOF"
  } >> "$GITHUB_OUTPUT"
fi

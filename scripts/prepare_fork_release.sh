#!/usr/bin/env bash
set -euo pipefail

: "${RELEASE_TAG:?}"
: "${GITHUB_SHA:?}"
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_OUTPUT:?}"
: "${GITHUB_STEP_SUMMARY:?}"
: "${RUNNER_TEMP:?}"

# 先在 main 的目前提交保留標籤，避免建置期間 main 前進後觸發工作流程權限限制。
if git show-ref --verify --quiet "refs/tags/$RELEASE_TAG"; then
  test "$(git rev-parse "$RELEASE_TAG^{commit}")" = "$GITHUB_SHA"
else
  current_head="$(gh api "repos/$GITHUB_REPOSITORY/git/ref/heads/main" --jq '.object.sha')"
  if [[ "$current_head" != "$GITHUB_SHA" ]]; then
    echo "skip=true" >> "$GITHUB_OUTPUT"
    echo "Skipped obsolete commit; the newer main push will publish its own build." >> "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
  git tag "$RELEASE_TAG" "$GITHUB_SHA"
  git push origin "refs/tags/$RELEASE_TAG"
fi

if gh release view "$RELEASE_TAG" --json isDraft --jq '.isDraft' > "$RUNNER_TEMP/release-draft"; then
  echo "skip=$(test "$(cat "$RUNNER_TEMP/release-draft")" = false && echo true || echo false)" >> "$GITHUB_OUTPUT"
else
  echo "skip=false" >> "$GITHUB_OUTPUT"
fi

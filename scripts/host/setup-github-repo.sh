#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sameer Alam
# =============================================================================
# setup-github-repo.sh - apply this project's public-repository policy on GitHub.
#
#   ./scripts/host/setup-github-repo.sh              # apply
#   ./scripts/host/setup-github-repo.sh --dry-run    # show what would change
#
# Idempotent: safe to re-run. Requires the `gh` CLI, authenticated as a user
# with admin rights on the repository.
#
# What it does:
#   1. Repository metadata: description, homepage, topics
#   2. Blocks public participation: Issues off, Projects off, Wiki off
#      (a workflow closes external PRs - GitHub has no setting for that)
#   3. Security: vulnerability alerts, Dependabot fixes, secret scanning with
#      push protection, private vulnerability reporting
#   4. Branch protection ruleset on the default branch:
#        - no force pushes, no deletion
#        - pull request with code-owner review required
#        - CI must pass
#        - repository admins may bypass, so the owner is not locked out
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
set -uo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

need gh
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || die "Not inside a GitHub repository."
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"

section "Target"
info "repository     : ${REPO}"
info "default branch : ${DEFAULT_BRANCH}"
info "authenticated  : $(gh api user -q .login)"
[ "$DRY_RUN" = "1" ] && warn "DRY RUN - nothing will be changed"

# apply <description> <command...>
# In dry-run it reports the command and changes nothing. Otherwise it runs the
# command and reports success or failure honestly - never "[ok]" for something
# that did not actually happen.
apply() {
  local desc="$1"; shift
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s would: %-52s%s %s\n' "$C_DIM" "$desc" "$C_RESET" "$*"
    return 0
  fi
  if "$@" >/dev/null 2>&1; then
    ok "$desc"
  else
    warn "${desc} - FAILED (continuing)"
    info "  command: $*"
    return 1
  fi
}

# --- 1. Metadata -------------------------------------------------------------
section "1/4  Repository metadata"
apply "Description and homepage set" gh repo edit "$REPO" \
  --description "A complete, reproducible Kubernetes lab toolkit: build a real multi-node kubeadm cluster across a Mac and a Windows machine, then practise rollouts, RBAC, etcd disaster recovery, upgrades and troubleshooting." \
  --homepage "https://github.com/${REPO}#readme"

# Topics drive GitHub search and the repository's sidebar.
apply "Topics set" gh repo edit "$REPO" \
  --add-topic kubernetes --add-topic kubeadm --add-topic k8s \
  --add-topic cka --add-topic homelab --add-topic etcd \
  --add-topic devops --add-topic bash --add-topic powershell \
  --add-topic containerd --add-topic calico --add-topic disaster-recovery \
  --add-topic learning --add-topic sre

# --- 2. Block public participation -------------------------------------------
section "2/4  Public participation"
# Issues and Projects have real settings. Pull requests do not - GitHub offers
# no way to disable them on a public repo - so .github/workflows/close-external-prs.yml
# closes them instead.
apply "Issues, Projects, Wiki and Discussions disabled" gh repo edit "$REPO" \
  --enable-issues=false \
  --enable-projects=false \
  --enable-wiki=false \
  --enable-discussions=false

if [ -f .github/workflows/close-external-prs.yml ]; then
  ok "External PRs are closed by .github/workflows/close-external-prs.yml"
else
  warn "close-external-prs.yml is missing - external PRs will stay open"
fi

# --- 3. Security features ----------------------------------------------------
section "3/4  Security features"
apply "Dependabot vulnerability alerts enabled" \
  gh api -X PUT "repos/${REPO}/vulnerability-alerts"

apply "Dependabot automated security fixes enabled" \
  gh api -X PUT "repos/${REPO}/automated-security-fixes"

# Free on public repositories. Push protection blocks a commit that contains a
# recognised credential before it ever reaches GitHub.
apply "Secret scanning and push protection enabled" \
  gh api -X PATCH "repos/${REPO}" \
  -F 'security_and_analysis[secret_scanning][status]=enabled' \
  -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled'

# Lets people report vulnerabilities privately, which is what SECURITY.md asks for.
apply "Private vulnerability reporting enabled" \
  gh api -X PUT "repos/${REPO}/private-vulnerability-reporting"

# --- 4. Branch protection ----------------------------------------------------
section "4/4  Branch protection ruleset on '${DEFAULT_BRANCH}'"

RULESET_JSON=$(cat <<JSON
{
  "name": "protect-default-branch",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] }
  },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["squash", "merge", "rebase"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "Shell scripts" },
          { "context": "Kubernetes manifests" },
          { "context": "Documentation" },
          { "context": "Secret scan" }
        ]
      }
    }
  ]
}
JSON
)

# bypass_actors actor_id 5 is the built-in "admin" repository role, so the owner
# can still push directly. Everyone else must go through a PR that passes CI.
EXISTING_ID="$(gh api "repos/${REPO}/rulesets" -q '.[] | select(.name=="protect-default-branch") | .id' 2>/dev/null | head -1)"

if [ -n "$EXISTING_ID" ]; then
  info "Updating existing ruleset ${EXISTING_ID}"
  if [ "$DRY_RUN" = "1" ]; then
    info "would PUT repos/${REPO}/rulesets/${EXISTING_ID}"
  else
    printf '%s' "$RULESET_JSON" | gh api -X PUT "repos/${REPO}/rulesets/${EXISTING_ID}" --input - --silent \
      && ok "Ruleset updated"
  fi
else
  if [ "$DRY_RUN" = "1" ]; then
    info "would POST repos/${REPO}/rulesets"
  else
    printf '%s' "$RULESET_JSON" | gh api -X POST "repos/${REPO}/rulesets" --input - --silent \
      && ok "Ruleset created"
  fi
fi

# --- Report ------------------------------------------------------------------
section "Result"
if [ "$DRY_RUN" = "1" ]; then
  info "Dry run complete - re-run without --dry-run to apply."
  exit 0
fi

gh repo view "$REPO" --json name,visibility,hasIssuesEnabled,hasProjectsEnabled,hasWikiEnabled,hasDiscussionsEnabled,licenseInfo,repositoryTopics \
  -q '"  visibility  : \(.visibility)
  issues      : \(.hasIssuesEnabled)
  projects    : \(.hasProjectsEnabled)
  wiki        : \(.hasWikiEnabled)
  discussions : \(.hasDiscussionsEnabled)
  license     : \(.licenseInfo.spdxId // "none detected yet")
  topics      : \([.repositoryTopics[].name] | join(", "))"'

echo
gh api "repos/${REPO}/rulesets" -q '.[] | "  ruleset     : \(.name) [\(.enforcement)]"'
echo
ok "Repository policy applied."
info "Verify in the browser: https://github.com/${REPO}/settings"

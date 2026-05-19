# kanidm-personal

Personal fork of [kanidm](https://github.com/kanidm/kanidm) with relaxed
password policy:

- Minimum password length: 8 (upstream hardcodes 10, wontfix)
- zxcvbn minimum score: Two (upstream hardcodes Four, wontfix)

## Branch/tag structure

| Ref | Contents |
|-----|----------|
| `main` | This branch: README, workflow, and patch script only |
| `patches/v1/password-policy` | Patch commits for Kanidm v1.x |
| `v1.10.2`, `v1.10.3`, … | Upstream release + patches merged in |

Release tags in this fork have the same names as upstream tags but point to
merge commits — they descend from the upstream release commit *and* from all
`patches/v1/*` branches.

## How it works

`scripts/patch-tags.sh` runs weekly (and on demand). For each upstream release
tag it:

1. Fetches all upstream release tags into `refs/upstream_tags/*`
2. Checks whether the local tag already descends from the upstream commit and
   all `patches/v1/*` branch tips (idempotent)
3. If not: creates a git worktree at the upstream commit, merges each patch
   branch with `--no-ff`, and tags the result
4. If a merge fails (upstream changed a patched line): records the failure and
   continues — a GitHub issue is opened/updated listing the affected tags

The script contains all logic; the workflow just drives it and handles GitHub
API calls (push, issue management).

## Packages

Built and published by
[kanidm-personal-ppa](https://github.com/FrancisRussell/kanidm-personal-ppa).


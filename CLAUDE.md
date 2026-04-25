# Claude Code Guidelines

## Git Push Workflow

Direct push to the default branch (`main`/`master`) is the established workflow for this repo. Recent history confirms it: features land on the default branch via direct push, not pull-request review.

If a permission/hook denies `git push origin <default-branch>`, **STOP and ask the user** — do NOT create a feature branch as a workaround. Branching is only appropriate when the user explicitly requests it.

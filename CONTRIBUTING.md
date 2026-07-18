# Contributing to OpenASO

Thanks for helping improve OpenASO. Keep each change focused, explain how it was validated, and make the pull request's review state unambiguous.

## Before You Start

- Search existing issues and pull requests for related work.
- Do not include credentials, session data, signing material, or other secrets in commits, fixtures, logs, or screenshots.
- Prefer one independently reviewable change per pull request. Separate refactors, features, and unrelated fixes when they can be reviewed and reverted independently.
- Use short, descriptive, prefix-free branch names. Maintainer roadmap branches use `NN-short-description`, such as `12-ranking-history`, and may add a suffix letter for a split item, as in `37a-contributor-workflow`. External contributors do not need access to the private roadmap numbering; a descriptive kebab-case name is enough. Do not add a personal, tool, or organization prefix.

## Development Workflow

1. Start from the latest `main` and create a focused branch.
2. Add or update tests for behavior changes.
3. Run the narrowest relevant tests while iterating, then run the full test suite before requesting review.
4. Describe the user-visible effect, implementation boundaries, validation, and any remaining manual checks in the pull request.

Use Conventional Commit format for commit messages and pull request titles:

```text
<type>(<optional-scope>): <short imperative summary>
```

Common types include `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, and `chore`. Examples:

```text
fix(mcp): reject non-mcp HTTP routes
perf(keywords): batch freshness lookups
docs: add contributor workflow
```

## Validation

Run the complete test suite from the repository root:

```sh
xcodebuild test \
  -project OpenASO.xcodeproj \
  -scheme OpenASO \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath Build \
  CODE_SIGNING_ALLOWED=NO
```

For a focused test class while iterating, run the same command with an `-only-testing` selector:

```sh
xcodebuild test \
  -project OpenASO.xcodeproj \
  -scheme OpenASO \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath Build \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:OpenASOTests/OpenASOMCPServerTests
```

Build and launch the app for a smoke check when the change can affect runtime behavior:

```sh
./script/build_and_run.sh --verify
```

This script terminates any running process named `OpenASO` before it builds and launches the development app. Save work in a running OpenASO instance before using it.

Before opening the pull request, check committed changes against the current base plus any staged or unstaged work for whitespace errors:

```sh
git fetch origin main
git diff --check origin/main...HEAD
git diff --cached --check
git diff --check
```

Document the exact commands and results in the pull request. If a command could not be run, say why and identify the remaining check. Changes involving credentials, Keychain state, Apple services, browser sessions, signing, or release behavior may also need a manual check with an appropriate local configuration; never publish the credentials or captured session data used for it.

## Draft and WIP Pull Requests

Open a draft pull request, or state `WIP` prominently in its title or description, when the work is not ready for formal review. Include what is complete, what remains, and whether early feedback is wanted.

Reviewers and maintainers must not submit a formal change-request review on an explicitly draft or WIP pull request unless the author asks for that review. If invited to give early feedback, keep it clearly advisory. Wait for the author to mark the pull request ready before treating feedback as blocking or merging it.

When the work is ready, remove the WIP label or wording, mark the pull request ready for review, and update its validation results.

## Authorship and Source Credit

Credit should describe how the submitted code was actually produced:

- Preserve commit authorship when accepting or cherry-picking a contributor's commits.
- Use a `Co-authored-by` trailer only when that person materially co-authored the code or content in that commit. Do not add someone as a co-author merely because they opened a related issue or pull request, suggested an idea, or implemented a similar change elsewhere.
- If you independently implement an idea after reviewing a fork, issue, pull request, or commit, link that source in the pull request description and state that the implementation is independent. Do not add a co-author trailer unless the submitted commit was actually co-authored with that person.
- If code from a fork is directly incorporated or adapted, identify the source clearly, preserve applicable authorship and license notices, and explain the relationship in the pull request. Use source links rather than a co-author trailer unless the person actually co-authored the submitted commit.

When a maintainer adds follow-up commits to a contributor's pull request, the original commits retain their authors and the maintainer's commits retain the maintainer as author. A co-author trailer is not needed unless a specific commit was genuinely written together.

## Pull Request Checklist

- The pull request has one clear purpose and a Conventional Commit title.
- Tests cover changed behavior and the validation section reports exact results.
- Runtime-impacting changes include a launch smoke check when practical.
- The review state is clear: draft/WIP or ready for review.
- External ideas or code are linked and credited according to their actual contribution.
- No secrets, private data, or generated build artifacts are included.

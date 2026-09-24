---
name: create-release
description: Create and publish a Scenery release. Use when asked to bump the version in index.xml, prepare that version's changelog, commit and tag the release, push it to GitHub, and create a GitHub release. Accepts an optional MAJOR.MINOR.PATCH version; without one, increments the patch number.
---

# Create Release

Create one release for the Scenery package in `index.xml`. The release changelog belongs only to the new version entry; do not maintain or rewrite a separate changelog file.

## Inputs and Versioning

- Accept an optional version argument in `MAJOR.MINOR.PATCH` format.
- If supplied, use that version exactly. Require valid SemVer numeric sections, require it to be greater than the current package version, and refuse if a git tag for it already exists.
- If omitted, read the current Scenery package version from `index.xml` and increment only its third section. For example, `0.3.4` becomes `0.3.5`.
- Use bare version tags, such as `0.3.5`, without a `v` prefix.

## Workflow

1. Confirm the repository is `infeasibler/reaperplugins`, the current branch is `main`, and `origin` points to `https://github.com/infeasibler/reaperplugins.git`.
2. Inspect `git status`. Stop if there are staged, modified, or untracked files before starting; do not include or overwrite pre-existing work. Parse `index.xml` as XML, confirm its current Scenery version has a matching git tag, and check both local tags and `git ls-remote --tags origin` for the requested tag. Stop if that tag already exists locally or remotely.
3. Read commits after the current version's tag through `HEAD`. Include only user-visible changes to the actual Scenery scripts listed as `<source>` files in `index.xml`. Exclude changes to tests, skills, documentation, and other non-script files; ignore commits that contain only those changes. Describe eligible changes as concise, factual bullets. Do not include this release-preparation commit in the changelog. Stop and report if there are no release-worthy script changes rather than publishing an empty release.
4. Update only the Scenery `<version name="...">` and its `<changelog>` content in `index.xml`. Keep the changelog specific to this version, in the existing plain bullet format, and do not change source entries or older release notes. Review the resulting diff and parse/validate the XML before proceeding.
5. Stage only `index.xml` and commit it with the existing convention: `chore(release): prepare scenery VERSION`, replacing `VERSION` with the release version.
6. Create the bare version tag at that commit, then push the current branch and that tag to `origin`.
7. Create a GitHub release for the same tag, titled `Scenery VERSION`, with the exact new `<changelog>` text as its release notes. Use the authenticated GitHub release integration if it supports release creation; otherwise use `gh release create` and verify `gh auth status` first. Do not create a second tag or release if one already exists.
8. Verify the branch and tag are on `origin` and the GitHub release exists. Report the version, commit, tag, release URL, and any validation performed.

## Safety and Recovery

- Never use broad staging such as `git add -A` or `git add -u`; the release-preparation commit must contain only `index.xml`.
- Do not force-push, move/delete tags, overwrite an existing GitHub release, or amend an existing commit.
- If pushing succeeds but GitHub release creation fails, leave the pushed commit and tag intact. Report the partial completion and retry only the release creation after resolving the cause.
- If any precondition, XML validation, commit, tag, or push step fails, stop before later publishing steps and report the exact state reached.
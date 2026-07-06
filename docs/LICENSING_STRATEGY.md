# Licensing Strategy

This is not legal advice. It is a practical engineering policy for reducing licensing risk while building a new product inspired by existing open-source desktop pet and AI usage tools.

## Core Principle

Do not ask a coding agent to rewrite, translate, merge, or optimize another repository's source code as a way to avoid the license.

If the implementation is derived from the original code, a rewrite, refactor, translation, merge, or optimization may still be treated as a derivative work. Adding new features does not automatically remove the original license obligations. Releasing the app for free also does not remove open-source license obligations.

The safer approach is to use reference repositories for product research, behavior ideas, architecture patterns, and feature comparison, then implement fresh code from an independently written specification.

## Recommended Policy

Use three categories:

1. Product inspiration
   - Allowed by default.
   - Examples: "desktop pet reacts to typing", "menu-bar quota meter", "burn-rate warning".
   - Do not copy code, assets, exact UI, text, or file formats unless license review allows it.

2. Permissive code reuse
   - Allowed only after license review.
   - Usually practical for MIT or Apache-2.0 projects if notices and attribution are preserved.
   - Still check whether assets, models, screenshots, and bundled media have separate licenses.

3. Copyleft code reuse
   - Avoid for MVP unless the project intentionally accepts the license obligations.
   - AGPL-licensed code is especially sensitive for redistributed or network-accessible modified software.
   - Treat AGPL projects as references only unless a legal review approves reuse.

## Clean-Room Workflow

Use this workflow when a reference project is valuable but direct reuse is undesirable:

1. Research pass
   - Review the public behavior, README, screenshots, issues, and architecture descriptions.
   - Produce a feature/spec document in original words.
   - Avoid copying implementation code.

2. Spec pass
   - Convert findings into requirements, interfaces, state machines, and acceptance criteria.
   - Keep the spec technology-agnostic where possible.
   - Record which ideas came from which references.

3. Implementation pass
   - Build from the spec only.
   - Do not provide the implementation agent with source files from restricted references.
   - Use standard platform APIs and original code.

4. Review pass
   - Check that no copied code, distinctive text, assets, or data files entered the repo.
   - Verify licenses for any third-party packages or assets.
   - Keep attribution where required.

## Coding Agent Instructions

When asking a coding agent to implement features, use wording like:

```text
Implement this feature from the product specification. Do not copy or translate code from the reference repositories. Use the references only as product inspiration. Write original code using platform APIs and libraries already approved for this project.
```

Avoid wording like:

```text
Rewrite this repo to avoid the license.
Optimize this repo and add new features.
Translate this AGPL project into Swift.
Use this repository as the base and change the UI.
```

Those requests can still create derivative work.

## Source and Asset Rules

- Do not copy pet sprites, Live2D models, icons, screenshots, sound effects, or animation frames without explicit asset permission.
- Keep third-party license notices in `THIRD_PARTY_NOTICES.md` if any dependencies or reusable code are added.
- Prefer original placeholder assets during MVP.
- For generated assets, record the generation prompt, date, model/tool, and usage rights.

## Reference Handling

For this project:

- Treat `usage` as product inspiration unless AGPL reuse is explicitly accepted.
- Treat MIT projects as possible implementation references, but still prefer original code unless reuse saves meaningful time.
- Treat all visual assets as separately licensed until proven otherwise.
- Keep provider parser logic original unless a reused parser has a reviewed compatible license.

## Decision Checklist

Before copying any third-party material, answer:

1. What exact file or snippet is being reused?
2. What license applies to the source code?
3. Are assets licensed separately?
4. Does the license require attribution, source disclosure, patent notice, or network-use obligations?
5. Can the same result be implemented from a clean spec instead?
6. Has the copied material been recorded in notices?

Default answer for MVP: build from scratch using references only as product inspiration.

## Current Project Decision

For the MVP, "merge all usage repos" means merge the product ideas, feature lists, data-source learnings, and UX patterns into this project's own specification. It does not mean merging source code, source directories, parser implementations, UI implementation, or assets.

The current intended approach is:

1. Use AGPL and other reference repos as feature references.
2. Extract their pros and shortcomings into original product docs.
3. Build the MVP from zero in this repository.
4. Keep implementation agents working from this repo's specs, not from copied reference source.

If source code is copied from any reference, the copied portion must go through license review first and be recorded in project notices.

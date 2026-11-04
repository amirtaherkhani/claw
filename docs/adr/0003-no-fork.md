# ADR-0003: Build new, do not fork Skill Forge

- **Status:** Accepted (2026-11-04)

## Context

Skill Forge (HayriCan/SkillForge, Tauri 2 + Svelte 5, MIT) was the closest open-source GUI. When checked on 2026-11-04 it had 4 commits, 0 stars and no releases, and documented enable/disable only for MCP servers. Its source was not reviewed.

## Decision

Build Claw from scratch (`TECHNICAL-DESIGN.md` section 2). With ADR-0001 the stacks no longer match anyway.

## Consequences

No upstream to rebase on and no license obligations from a fork. Ideas may still be borrowed with attribution if its MIT code is reused.

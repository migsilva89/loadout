---
title: Codex plugin discovery and consistent skill switches
version: 1.1
date_created: 2026-09-12
owner: Miguel Silva
tags: [plugins, codex, skills, state, macos]
---

# Introduction

Implementation plan and delivery record for installed Codex plugins and their skills in Loadout, with consistent and reversible plugin and skill switches.

Implemented on 2026-09-12: native local protocol discovery and configuration editing, provider-scoped identities, preserved individual choices, parent-off guards and navigation, diagnostics, configuration watching, and isolated regression checks. Codex workspace-managed parent switches and plugin removal remain in Codex with an explicit explanation; a local user setting cannot override those managed states.

Validation: all 326 Swift tests passed. The assembled debug app passed its 135 existing application checks and all 16 native Codex integration checks, including an installed-version update, backup failure, and malformed configuration. The local build is at `dist/Loadout.app`; it has not been installed over the user's app or published as a release.

## 1. Purpose & Scope

Include Codex plugins in the global inventory, Everything view, assistant filters and plugin details. Preserve Claude behavior and existing individual off choices. Make every skill switch reflect whether its parent plugin permits it to run.

Do not install plugins, publish a release, change personal skill sharing, or build a general MCP manager as part of this fix. Plugins without skills should still appear with an accurate empty skills list.

## 2. Definitions

- **Individual choice:** whether the user has enabled a particular skill.
- **Effective state:** individual choice AND parent plugin enabled, subject to applicable configuration overrides.
- **Provider:** the assistant owning an installation, such as Claude or Codex.
- **Native key:** the identifier used by the provider configuration, typically plugin@marketplace.
- **Installation identity:** provider plus native key and any necessary installation scope; independent of a cached version directory.

## 3. Requirements, Constraints & Guidelines

- **REQ-001:** Discover actual Codex installations, including disabled ones. Cached directories alone do not prove installation or identify the active version. Ignore staging and obsolete versions.
- **REQ-002:** Read skills from the plugin manifest's supported skill locations; do not assume every plugin uses the same directory layout. Associate each item with its provider and installation identity.
- **REQ-003:** Keep identical names in Claude and Codex independent. Do not merge plugin items with personal skills by display name. Avoid double inventory for a manifest supporting both ecosystems in one installation.
- **REQ-004:** Display the effective state in the main skills list, detail header, plugin contents, On/Off filters and state counts. Preserve the individual choice separately.
- **REQ-005:** Turning off a plugin makes all its child switches appear off and unavailable, with a reason and a route to its plugin. It must not rewrite every child's individual choice.
- **REQ-006:** Turning the plugin on restores previous individual choices. A skill explicitly disabled before the plugin was disabled remains off.
- **REQ-007:** Users can re-enable the parent in Plugins, then change any individual skill. Do not implicitly enable a whole plugin when clicking one child, because that would enable its other children too.
- **REQ-008:** Route writes through the owning provider. A Codex operation must never change Claude settings or its off records.
- **REQ-009:** Observe external configuration and installation changes and refresh all affected views. State shown is configured availability; do not claim to unload skills already present in an existing assistant session.
- **REQ-010:** Preserve individual choices across plugin updates by stable identity and skill-relative identity. Apply any path-based override to the newly resolved active path.
- **CON-001:** Every write requires the existing backup protection. Invalid or unsupported configuration must produce an actionable error, never an empty replacement configuration.
- **CON-002:** Respect project or managed overrides. Explain why a switch is unavailable where a user-level write would have no effect.
- **CON-003:** Add guards at the action layer as well as disabling UI controls, so alternate invocation paths cannot bypass the parent state.

## 4. Interfaces & Data Contracts

Extend the plugin model with provider, native configuration key, stable installation identity, state source and mutation capability. Keep internal identity separate from the key written to provider settings.

Extract provider-specific discovery and enable/disable operations behind a small interface. Retain the current Claude reader and writer as one implementation; add Codex separately. Return inventory diagnostics alongside valid installations, rather than silently returning an empty list for unreadable data.

Codex's local configuration observed on this machine uses a plugins table keyed by plugin@marketplace with an enabled boolean. The official reference documents that switch and per-skill path overrides; effective settings can include project or managed decisions. These facts do not establish which cached version is active or prove all managed plugins use the same write mechanism. [Official configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

For individual Codex skills, prefer the documented per-skill configuration override, after verifying it against plugin skills in an isolated fixture. Do not assume Claude's folder-moving method works for Codex. A provider-native implementation is required before enabling that control.

Existing Claude off records use native keys without a provider. Preserve compatibility by reading those as Claude records; new Codex records use a separate namespace. Keep old identities readable during migration and test that no prior choice is lost.

## 5. Acceptance Criteria

| Parent | Individual choice | Skill switch | Can change skill here? |
|---|---|---|---|
| On | On | On | Yes |
| On | Off | Off | Yes |
| Off | On | Off; reason identifies parent | No; open parent to enable |
| Off | Off | Off; reason identifies parent | No; open parent to enable |

- **AC-001:** Given a Codex-only installation with skills, scanning includes one plugin and its skills under Codex, including when no Claude registry exists.
- **AC-002:** Given the same plugin key in both providers, disabling either affects only that provider's installation.
- **AC-003:** Given skills A on and B off, disabling and enabling the parent produces A on and B off in every view, including after app restart.
- **AC-004:** Given a disabled parent, its children remain discoverable under Off; direct action invocation cannot change them as if the parent were on.
- **AC-005:** Given an updated active version, old cached copies do not duplicate rows and prior off choices remain effective.
- **AC-006:** Given an external install, removal or configuration change, the open UI refreshes without a manual restart.
- **AC-007:** Given a malformed configuration, failed backup, conflicting destination or overriding policy, the operation explains the problem and preserves data.
- **AC-008:** Given a plugin with no skills, it remains visible without invented skill rows.
- **AC-009:** Given nondefault manifest skill paths and repeated skill display names, discovery finds the right files and operations target the right installation.

## 6. Test Automation Strategy

Use existing Swift XCTest fixtures with temporary home and support directories. Add provider fixtures containing anonymized plugin metadata, settings, multiple cached versions and manifests. Never toggle real user plugins during automated tests.

Cover discovery, identity collisions, configuration round trips, individual skill overrides, parent restoration, update reconciliation, invalid data and backup failure. Extend application self-checks to cover all switch surfaces and changing assistant filters. Verify watcher-driven refresh in the assembled app using fixture data.

Run targeted tests during implementation, then the full `swift test` suite to verify core behavior and `LoadoutApp --self-check` to validate app integration. Check configured availability through a fresh isolated Codex session or supported discovery endpoint before claiming the Codex switches work.

## 7. Rationale & Context

Confirmed by source inspection:

- `Sources/LoadoutCore/Paths.swift`, which defines inventory locations, points plugin registry and cache access at Claude only.
- `Sources/LoadoutCore/InventoryScanner.swift`, which builds the inventory, only reads that registry and does not assign provider membership to plugin child items.
- `Sources/LoadoutCore/Mutations.swift`, which changes plugin enablement, always writes Claude local settings.
- `Sources/LoadoutCore/Filtering.swift`, which derives visible state, already calculates individual choice AND parent enabled.
- The main row, item detail and plugin detail already use that effective state and disable child controls when the parent is off. This is existing intended behavior, not a confirmed new UI regression.
- `Tests/LoadoutCoreTests/FilterCompositionTests.swift`, which verifies filter behavior, includes a parent-off test that preserves individual choices. Its scope does not prove the app's UI or Codex integration works.
- `Sources/LoadoutApp/AppModel.swift`, which handles user actions and file watching, does not watch Codex plugin/configuration locations and does not guard child plugin mutations against a disabled parent at every action entry point.

Local evidence includes a Codex plugin manifest with a skills directory and matching configuration entry. The friend's exact plugin and installed Loadout version are unknown; reproduce that exact case if those details become available. The source-level missing provider support is independently established.

## 8. Dependencies & External Integrations

Use the current Swift core, SwiftUI app, backup facility, off records and file watcher. Establish Codex's authoritative local installation/version source before implementing discovery. Inspect a supported local listing interface or installation metadata; avoid relying on a lexical maximum cache version.

The implementation uses the installed Codex app-server: `plugin/installed` identifies installed versions, `skills/list` supplies runtime paths and state, and `config/read`, `config/value/write` and `skills/config/write` read and edit configuration. Native editing preserves unrelated values and comments without an additional TOML dependency. Disabled local-plugin children are read from the manifest in the version identified by Codex. Protocol compatibility failures are reported instead of guessing from cache. No AI conversation is started.

## 9. Examples & Edge Cases

A plugin supplies ten skills, of which two are individually off. Turning the plugin off shows ten off switches. Turning it back on restores eight on and two off. Turning either remaining skill on then changes just that skill.

A personal skill with the same name remains independent. A Codex plugin and a Claude plugin with the same marketplace key remain independent. A plugin version left in cache after uninstall must not reappear as installed. A configured plugin missing its files should show a diagnostic rather than a working toggle over nonexistent content.

## 10. Validation Criteria & Implementation Order

1. **Confirm Codex contracts:** identify the authoritative installed/active-version source, configuration precedence and supported plugin-skill override behavior. Capture temporary fixtures and record any managed-plugin limitations.
2. **Model provider ownership:** separate internal identity from native keys; make off-record compatibility explicit.
3. **Implement discovery:** combine provider inventories, read manifest skill paths, annotate assistant membership and expose diagnostics.
4. **Implement writes:** provider-specific parent and individual controls, backups, configuration preservation and update reconciliation.
5. **Unify behavior:** reuse effective state everywhere; add action guards, parent navigation and external-change watching. Preserve existing project override semantics.
6. **Verify:** run regression and app checks, including parent off/on, individually off skills, same-name providers and plugin updates. Reproduce the friend's case when its identity is available.
7. **Document:** update the main specification and help text to describe actual supported providers and the off/on behavior.

Done means installed Codex plugin skills appear and can be managed reversibly with verified provider behavior, all visible states agree, prior Claude choices survive, and required checks pass. A list populated merely from cache is not completion.

## 11. Related Specifications / Further Reading

- [Application specification](../docs/SPEC.md), especially AC2.8 and AC3.14, defines parent-off behavior.
- [Existing skill enable/disable flow](spec-flow-enable-disable-skills.md) defines persistent individual choices.
- [Official configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference) documents Codex plugin and skill overrides.

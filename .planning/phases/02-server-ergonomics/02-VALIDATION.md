---
phase: 2
slug: server-ergonomics
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-30
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | cargo test (Rust integration tests) |
| **Config file** | Cargo.toml (workspace) |
| **Quick run command** | `cargo build --workspace` |
| **Full suite command** | `cargo test --workspace` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cargo build --workspace`
- **After every plan wave:** Run `cargo test --workspace`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 60 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 02-01-01 | 01 | 1 | SCALE-01 | — | N/A | build | `cargo build -p server` | ✅ | ⬜ pending |
| 02-02-01 | 02 | 1 | SCALE-02 | — | N/A | build | `cargo build -p server` | ✅ | ⬜ pending |
| 02-03-01 | 03 | 1 | SCALE-03 | — | N/A | build | `cargo build -p server` | ✅ | ⬜ pending |
| 02-04-01 | 04 | 2 | PERF-05 | — | N/A | build | `cargo build -p server` | ✅ | ⬜ pending |
| 02-05-01 | 05 | 2 | DX-03 | — | N/A | build | `cargo build -p server` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- Existing `cargo build` infrastructure covers all phase requirements.

*Existing infrastructure covers all phase requirements.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Pool metadata served from moka cache on repeat requests (TTL 60s) | PERF-05 | Requires running server + repeated HTTP calls | Start server, hit `/get_pools` twice within 60s, confirm second response is faster / no DB query logged |
| Ticker response served from moka cache on repeat requests (TTL 10s) | PERF-05 | Requires running server + repeated HTTP calls | Start server, hit `/ticker` twice within 10s, confirm second response is cached |
| Invalid wallet address rejected at extractor layer | DX-03 | Requires integration test with running server | POST `/portfolio/invalid-wallet`, expect 400 before reaching reader.rs |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending

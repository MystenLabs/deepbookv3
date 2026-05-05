---
phase: 03-openapi-docs
type: validation
created: 2026-05-01
---

# Phase 3: OpenAPI Docs — Validation Strategy

## Test Framework

| Property | Value |
|----------|-------|
| Framework | Rust built-in `#[test]` + `cargo test` |
| Config file | none (standard cargo test discovery) |
| Quick run command | `cargo build -p deepbook-server` |
| Full suite command | `cargo build -p deepbook-server && cargo test -p deepbook-server` |

## Phase Requirements -> Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| DX-01 | `/swagger-ui/` returns HTML with status 200 | smoke (integration) | `curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/swagger-ui/` | No (manual) |
| DX-01 | `/api-docs/openapi.json` returns valid JSON | smoke (integration) | `curl -s http://localhost:8080/api-docs/openapi.json \| python3 -m json.tool` | No (manual) |
| DX-01 | `ApiDoc::openapi().to_json()` compiles without error | unit (compile) | `cargo build -p deepbook-server` | No (Wave 0) |
| DX-01 | OpenAPI JSON validates against OpenAPI 3.0 schema | lint/external | `npx @stoplight/spectral-cli lint /api-docs/openapi.json` | No (manual) |
| DX-01 | All 48 endpoint paths appear in spec | unit | `cargo test -p deepbook-server -- openapi_paths` | No (Wave 0) |

## Sampling Rate

- **Per task commit:** `cargo build -p deepbook-server` (compile check confirms no ToSchema/path errors)
- **Per wave merge:** `cargo build -p deepbook-server && cargo test -p deepbook-server`
- **Phase gate:** Manual verification of Swagger UI + JSON validation before `/gsd-verify-work`

## Wave 0 Gaps

- [ ] No existing Swagger UI test; manual curl verification suffices for this phase
- [ ] Optional: add `tests/openapi_spec.rs` with a test that calls `ApiDoc::openapi()` and asserts specific paths are present
- [ ] `utoipa`, `utoipa-swagger-ui` not yet in Cargo.toml — must be added in Wave 1

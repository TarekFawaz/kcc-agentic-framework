---
title: Scripting Lua Dialect
tags: [kcc/kernel, dialects, scripting, lua, luajit]
created: 2026-10-16
updated: 2026-10-16
version: 0.6.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Scripting Lua Dialect

Use for Lua 5.4 and LuaJIT code: game scripting (engines and modding), Neovim plugins, OpenResty/nginx modules, and Lua embedded in a host application.

## Coding
- Target one runtime per project and record it in the plan: Lua 5.4, LuaJIT 2.1 (5.1 semantics plus extensions), or the host's embedded version (Neovim is LuaJIT; Roblox, Defold, and others ship their own). Do not use 5.4-only features (integers, `<const>`, `goto` differences) on LuaJIT targets.
- No globals: every module returns a table, `local` everywhere, and the strict-globals check from luacheck is enforced.
- Modules under `lua/<project>/` (or `src/<project>/`) following `require` paths; one public module per file, private helpers local to the file.
- Errors: use `error()` with tables or structured messages for programmatic errors, `pcall`/`xpcall` with a traceback handler at boundaries; never swallow errors.
- Performance: avoid table allocation in hot loops, cache `require`d modules and frequently used functions in locals, use `table.concat` for string building; on LuaJIT keep hot paths FFI-safe and avoid NYI operations.
- Host integration follows the host's API conventions (Neovim `vim.api` and `vim.fn`, OpenResty `ngx.*` with cosockets, engine APIs); never block the event loop in Neovim or OpenResty.

## Sandboxing and untrusted scripts
- Any script authored by users, mods, or third parties runs in a sandbox: a fresh environment table with an explicit allowlist of functions, no `os`, `io`, `debug`, `load` with bytecode, `require`, or `package` access, and `string.dump` removed.
- Enforce resource limits: instruction count via `debug.sethook`, memory via `collectgarbage("count")` checks or host allocator limits, wall-clock timeouts from the host.
- Never load untrusted bytecode (`load(..., "t")` text mode only); validate chunk names; treat script output as untrusted data.
- The sandbox design (allowlist, limits, escape tests) is an ADR and has its own tests.

## C API boundaries
- Keep the C side thin: marshal data, check the stack with `luaL_checkstack`, validate every argument with `luaL_check*`, balance the stack on every return path, and never hold `lua_State` or stack references across calls that can trigger GC or yield.
- Use userdata with metatables for native handles, `__gc` for cleanup, and `__close` (5.4) or explicit `close()` for deterministic release. On LuaJIT prefer FFI with `ffi.gc` and `ffi.metatype`, with FFI declarations in one module.
- Every exported C function needs a test that exercises error paths (wrong types, nil, out-of-range) from Lua.

## Review
- Check for accidental globals, stack balance in C bindings, blocking calls in coroutine or event-loop hosts, missing `pcall` at boundaries, sandbox escapes (metatables on strings, `getmetatable`, `rawset` on shared tables), runtime-specific features on the wrong target, and tests for every public module function.

## Bug Fix
- Reproduce with a failing busted spec, patch the narrowest module function, run `luacheck .` and `busted`, and re-run inside the host (Neovim headless, OpenResty test harness, or the engine) when the bug involves host APIs.

## Testing
- `busted` for unit and integration specs under `spec/`; `luassert` matchers and `busted` mocks or `luassert.spy`; host-specific harnesses (`plenary.nvim` for Neovim, `Test::Nginx` for OpenResty, the engine's test runner for games).
- Coverage with `luacov`; threshold from the quality gate. Sandbox tests include escape attempts that must fail.

## Docs
- README must include the target Lua runtime and version, install steps (LuaRocks rockspec or host-specific), module layout and public API, run/test/lint commands, and sandbox guarantees for untrusted scripts.

## Toolchain
- `lua` (5.4) or `luajit`, LuaRocks with a committed `*.rockspec` (and `luarocks.lock` where the project uses it), `luacheck` with a committed `.luacheckrc`, `busted`, `luacov`, optional `stylua` for formatting, and the host binaries (`nvim`, `openresty`, engine) for integration runs.
- CI runs `luacheck .`, `busted --coverage`, and the host harness for the integration suite.

## Project Structure
- `lua/<project>/` or `src/<project>/` modules, `spec/` tests mirroring the module tree, `rockspecs/` or a root `<project>-dev-1.rockspec`, `.luacheckrc`, `.busted`, optional `csrc/` for C bindings, `plugin/` for Neovim entry points.
- For greenfield KCC projects the Lua code lives under `src/` unless the host dictates a layout (Neovim `lua/` and `plugin/`).

## API & Architecture defaults
- When Lua exposes an HTTP API (OpenResty), follow [[api-standards]]: ship an OpenAPI 3.x document + served Swagger UI (default `/docs`) + verifier-checked route conformance. Waivable only with an ADR.
- Architecture style per [[architecture-styles]]: scripts and plugins are usually trivial or small and may opt down with an ADR; services (OpenResty) follow Clean Architecture layering with host APIs kept in the infrastructure layer.

## Complexity
- low: junior-safe single-module script, config, or command.
- medium: mid-level plugin or module set with host integration and specs.
- high: senior sandboxing, coroutine scheduling, LuaJIT FFI, or performance-critical paths.
- extra-high: principal-expert embedding design, custom allocators, or C API surfaces for a host application.

## Escalate
- Escalate to the architect for sandbox policy, C API or FFI surfaces, runtime target changes, and host-integration patterns; escalate to a human when untrusted scripts gain any new capability.

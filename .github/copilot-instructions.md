# Repository Instructions

## Unit Tests

- For every code change, consider whether a focused unit test can cover the behavior or prevent a regression. Add one when practical, following the repository's existing test conventions; do not test implementation details that do not affect behavior.
- When adding or changing tests, ensure the repository documents how to run them. Report the exact test command and its result when completing the work. If tests cannot be run, state why.
- Run the narrowest relevant test command after a change, then run the full suite when practical.
- Run the Scenery library suite with Lua 5.4:
  `lua tests/scenery_lib_test.lua`
- If Lua is unavailable, run it with Node.js/npm and Fengari:
  `npx --yes --package=fengari-node-cli fengari tests/scenery_lib_test.lua`
- Fake REAPER API tests verify Scenery's logic, not REAPER's host behavior. Use REAPER integration checks for behavior that depends on the actual host.
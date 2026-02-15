# Claude Code Instructions

## WHATWG Spec Compliance

WHATWG spec compliance is the top priority — above passing tests. Never assume previously written code is correct just because it makes tests pass. If code violates the WHATWG spec, correcting it is an immediate priority, even if it causes test regressions that need to be resolved separately. If a test passes while the implementation is non-compliant, make it pass by being compliant instead. Sometimes spec-compliant changes may cause regressions — keep the compliant code and make the tests pass by improving existing code elsewhere.

## Code Style

- Always fix compile warnings as soon as they appear
- Favor vertical pipelines over horizontal ones

## Before Committing

Always run `mix format` and `mix credo --strict` before committing changes.

## Running HTML5lib Tree Construction Tests

The test suite includes ~1500 html5lib tree construction tests. Use these filters to run specific tests efficiently:

```bash
# Run a single specific test (fastest for debugging)
mix test test/pure_html/html5lib_tree_construction_test.exs --only "test_id:webkit02:12"

# Run all tests from one test file (~8 seconds vs ~68 for full suite)
mix test test/pure_html/html5lib_tree_construction_test.exs --only test_file:webkit02

# Run all tests with a specific number across files
mix test test/pure_html/html5lib_tree_construction_test.exs --only test_num:12
```

Available test files: `tests1` through `tests26`, `webkit01`, `webkit02`, `template`, `adoption01`, etc.

## Test File Format

Tests are defined in `.dat` files under `test/html5lib-tests/tree-construction/`. Each test has:

- `#data`: HTML input
- `#document`: Expected tree output
- Optional `#document-fragment`: Context element for fragment parsing
- Optional `#script-off`/`#script-on`: Scripting mode

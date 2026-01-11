# Claude Code Instructions

## Code Style

- Always fix compile warnings as soon as they appear
- Favor vertical pipelines over horizontal ones

## Before Committing

Always run `mix format` before committing changes.

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

## Tracking Test Failures

**IMPORTANT:** When running the full test suite, you MUST:
1. Always pipe output through `tee` to cache results in `/tmp/test_failures.txt`
2. Always update `TEST_FAILURES.md` with current failure counts after the run completes

```bash
# REQUIRED: Always run the full suite this way to cache output
mix test test/pure_html/html5lib_tree_construction_test.exs 2>&1 | tee /tmp/test_failures.txt

# Then count failures by file and update TEST_FAILURES.md
cat /tmp/test_failures.txt | grep "^\s*[0-9]*) test" | sed 's/.*test \([^ ]*\) #.*/\1/' | sort | uniq -c | sort -rn
```

## Current Status

Working on HTML5 tree construction algorithm compliance. Main areas:
- Adoption agency algorithm (complex formatting element handling)
- Foreign content (SVG/MathML) with attribute/tag adjustments
- Select element special handling

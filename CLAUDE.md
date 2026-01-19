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

## html5lib Test Coverage

| Category          | Tests | Running |
| ----------------- | ----- | ------- |
| Tokenizer         | 7,036 | 7,036   |
| Tree construction | 1,695 | 1,476   |
| Encoding          | 82    | 82      |
| Serializer        | 230   | 40      |
| **Total**         | **9,043** | **8,634** |

**Skipped tests:**
- Tree construction: 192 fragment parsing + 27 script-off = 219 skipped
- Serializer: 181 optionaltags + 9 injectmeta = 190 skipped (require optional tag omission)

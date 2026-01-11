# Test Failures Analysis

**Total: 196 failures out of 1476 tests**

*Last updated: 2026-01-11 after in_head and text mode extraction (was 198 failures)*

## By Test File

| File | Count | Notes |
|------|-------|-------|
| tests1 | 24 | Adoption agency, foster parenting |
| webkit01 | 20 | Various edge cases |
| tests10 | 19 | Table foster parenting |
| template | 19 | Template mode edge cases |
| webkit02 | 14 | Various edge cases |
| tests7 | 13 | Formatting elements |
| tests19 | 13 | Various edge cases |
| tests3 | 10 | Various edge cases |
| tests17 | 7 | Various edge cases |
| tests20 | 6 | Various edge cases |
| tests2 | 6 | Various edge cases |
| tests26 | 5 | Various edge cases |
| tests18 | 5 | Various edge cases |
| Others | ~35 | Various edge cases |

## By Category

| Category | Count | Notes |
|----------|-------|-------|
| Template | 14 | Template mode switching, remaining edge cases |
| Table | ~20 | Foster parenting, form in table |
| Math/SVG foreign content | ~15 | Integration points, breakout |
| Adoption agency / formatting | ~15 | Complex cases with tables |
| Frameset | ~10 | After frameset, noframes |
| Select | ~8 | Button in select, nested select |
| Body/HTML edge cases | ~5 | Second body attrs, after </html> |

## Sample Failures by Category

### Adoption agency / formatting (remaining)
```
<!DOCTYPE html><body><b><nobr>1<table><nobr></b><i><nobr>2
<i>A<b>B<p></i>C</b>D
<DIV> abc <B> def <I> ghi <P> jkl </B> mno </I> pqr </DIV>
```

### Template (remaining)
```
<body><template><col><div>  (div after col not added)
<body><template><div><tr></tr></div></template>
<frameset><template><frame></frame>  (frameset+template interaction)
<template><a><table><a>
```

### Table foster parenting
```
<!doctype html><table><form><form>
<p><table></table>
<!doctype html><table><input type=hidDEN>
<table><li><li></table>
```

### Frameset
```
<!doctype html><frameset></frameset></html>
<input type="hidden"><frameset>
<!doctype html><frameset></frameset><plaintext>
```

### Select
```
<select><button><selectedcontent></button>
<select><b><option><select><option></b>
<!doctype html><select><tfoot>
```

### Math/SVG foreign content
```
<math><mi><div><object><div><span></span>
<math><annotation-xml><svg><foreignObject>
<svg><foreignObject></foreignObject><title>
```

## Priority Fixes

1. **Table foster parenting** (~20) - Edge cases with forms, inputs
2. **Template** (17) - Remaining template edge cases
3. **Foreign content** (~15) - Integration points, breakout tags
4. **Remaining adoption agency** (~15) - Complex cases with tables

## Recent Fixes

- **In head and text mode extraction** (2026-01-11): Extracted `in_head` insertion mode to `lib/pure_html/tree_builder/modes/in_head.ex` and created `text` mode for RAWTEXT/RCDATA content (script, style, title). Fixed head element handling in after_head mode to properly reopen head for head elements. Fixed template handling to check if body is in stack before using body-mode rules. Fixed 2 tests (198 → 196 total).

- **After frameset mode extraction** (2026-01-10): Extracted after_frameset insertion mode to `lib/pure_html/tree_builder/modes/after_frameset.ex`. Handles whitespace, comments, and ignores other tokens per spec. Fixed 8 tests (206 → 198 total).

- **After body mode extraction** (2026-01-10): Extracted after_body insertion mode to `lib/pure_html/tree_builder/modes/after_body.ex`. Switches to after_body mode when `</body>` seen in in_body mode. Handles comments by closing elements to html first, then inserting comment. Fixed `ensure_body_final` to check for body in html.children. No net change in failures (206 → 206).

- **After head mode extraction** (2026-01-10): Extracted after_head insertion mode to `lib/pure_html/tree_builder/modes/after_head.ex`. Fixed `maybe_reopen_head/1` to check if head is on stack rather than checking mode. Added proper handling of whitespace (insert as child of html) and comments (insert as child of html) per spec. Fixed 1 test (207 → 206 total).

- **Initial mode module extraction** (2026-01-10): Started refactoring insertion modes into separate modules. Extracted Initial mode to `lib/pure_html/tree_builder/modes/initial.ex` with proper whitespace handling and reprocess signaling. Added `:before_html` mode support to transition_to. Fixed 3 tests in tests2/tests7 (213 → 210 total).

- **Template insertion modes** (2026-01-10): Implemented mode switching for table elements in template content. Table structure elements (tbody, thead, etc.) are now added directly when first in template, and ignored when following other table elements without proper table context. Fixed tests 2, 27, 29, 89 and 2 tests1 failures (219 → 213 total).

- **Adoption agency algorithm** (2026-01-10): Fixed basic "no furthest block" case to only remove target element from AF, not all formatting elements above it. Fixed reconstruction order after adoption agency for `<nobr>` and `<a>` tags. Fixed all 17 adoption01 tests plus 10 additional tests (231 → 219 total).

- **CDATA sections** (2026-01-10): Implemented tree builder feedback for proper CDATA handling in SVG/MathML vs HTML content. Fixed all 21 tests21 failures (252 → 231 total).

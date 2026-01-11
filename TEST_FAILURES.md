# Test Failures Analysis

**Total: 179 failures out of 1476 tests**

*Last updated: 2026-01-11 after in_table mode extraction (was 178 failures)*

## By Test File

| File | Before | After |
|------|--------|-------|
| tests1 | 23 | 23 |
| tests10 | 19 | 20 |
| webkit01 | 16 | 16 |
| webkit02 | 13 | 13 |
| template | 12 | 12 |
| tests19 | 11 | 14 |
| tests7 | 11 | 7 |
| tests3 | 10 | 10 |
| tests18 | 5 | 8 |
| tests20 | 5 | 4 |
| tricky01 | 4 | 4 |
| tests5 | 4 | 4 |
| tests6 | 0 | 4 |
| tests17 | 3 | 3 |
| tests2 | 3 | 3 |
| tests26 | 3 | 3 |
| quirks01 | 3 | 3 |
| tables01 | 2 | 2 |
| **Total** | **178** | **179** |

## By Category

| Category | Count | Notes |
|----------|-------|-------|
| Template | 12 | Template mode switching, remaining edge cases |
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
2. **Foreign content** (~15) - Integration points, breakout tags
3. **Remaining adoption agency** (~15) - Complex cases with tables
4. **Template** (12) - Remaining template edge cases

## Recent Fixes

- **In table mode extraction** (2026-01-11): Extracted `in_table` insertion mode to `lib/pure_html/tree_builder/modes/in_table.ex`. Handles table-specific token processing including foster parenting for non-table elements, table structure elements (caption, colgroup, tbody, thead, tfoot, tr, td, th), and SVG/math foreign content. Key changes: (1) Added foreign content delegation - when top of stack is svg/math, delegates to InBody for proper handling. (2) All foster parenting logic now in InTable instead of scattered in InBody and tree_builder.ex. (3) Fixed InCell's cell-closing end tags to check if target tag is in table scope before closing cell. (4) Fixed input handling - non-hidden inputs are now foster-parented. Some tests improved (tests7: 11→7), some regressed (tests19: 11→14). Net +1 regression (178 → 179 total).

- **In template mode extraction** (2026-01-11): Extracted `in_template` insertion mode to `lib/pure_html/tree_builder/modes/in_template.ex`. Handles template-specific token processing including nested templates, head elements (base, link, meta, script, style, title), and table structure elements. Fixed mode switching for non-table start tags to properly switch to `:in_body` mode so end tags close elements correctly. Added O(1) `template_mode_stack` check for html start tag handling instead of O(n) stack traversal. Fixed 2 tests (180 → 178 total).

- **In select mode extraction** (2026-01-11): Extracted `in_select` insertion mode to `lib/pure_html/tree_builder/modes/in_select.ex`. Properly handles option/optgroup opening and closing, table structure elements (close select and reprocess), svg/math elements with namespaces, and ignores table elements per spec. Fixed 7 tests (187 → 180 total).

- **In frameset mode extraction** (2026-01-11): Extracted `in_frameset` insertion mode to `lib/pure_html/tree_builder/modes/in_frameset.ex`. Fixed end tag handling to properly pop frameset element and switch to after_frameset mode when current node is no longer a frameset (was incorrectly staying in in_frameset mode). Fixed 7 tests (194 → 187 total).

- **In body mode extraction** (2026-01-11): Extracted `in_body` insertion mode to `lib/pure_html/tree_builder/modes/in_body.ex` (~1700 LOC). Moved all start tag handling, end tag handling, character processing, foreign content, adoption agency algorithm, active formatting elements, foster parenting, and implicit closing logic. Fixed end tag handling in foreign content to properly break out of SVG/MathML before processing `</p>` and `</br>`. Fixed 2 tests (196 → 194 total).

- **In head and text mode extraction** (2026-01-11): Extracted `in_head` insertion mode to `lib/pure_html/tree_builder/modes/in_head.ex` and created `text` mode for RAWTEXT/RCDATA content (script, style, title). Fixed head element handling in after_head mode to properly reopen head for head elements. Fixed template handling to check if body is in stack before using body-mode rules. Fixed 2 tests (198 → 196 total).

- **After frameset mode extraction** (2026-01-10): Extracted after_frameset insertion mode to `lib/pure_html/tree_builder/modes/after_frameset.ex`. Handles whitespace, comments, and ignores other tokens per spec. Fixed 8 tests (206 → 198 total).

- **After body mode extraction** (2026-01-10): Extracted after_body insertion mode to `lib/pure_html/tree_builder/modes/after_body.ex`. Switches to after_body mode when `</body>` seen in in_body mode. Handles comments by closing elements to html first, then inserting comment. Fixed `ensure_body_final` to check for body in html.children. No net change in failures (206 → 206).

- **After head mode extraction** (2026-01-10): Extracted after_head insertion mode to `lib/pure_html/tree_builder/modes/after_head.ex`. Fixed `maybe_reopen_head/1` to check if head is on stack rather than checking mode. Added proper handling of whitespace (insert as child of html) and comments (insert as child of html) per spec. Fixed 1 test (207 → 206 total).

- **Initial mode module extraction** (2026-01-10): Started refactoring insertion modes into separate modules. Extracted Initial mode to `lib/pure_html/tree_builder/modes/initial.ex` with proper whitespace handling and reprocess signaling. Added `:before_html` mode support to transition_to. Fixed 3 tests in tests2/tests7 (213 → 210 total).

- **Template insertion modes** (2026-01-10): Implemented mode switching for table elements in template content. Table structure elements (tbody, thead, etc.) are now added directly when first in template, and ignored when following other table elements without proper table context. Fixed tests 2, 27, 29, 89 and 2 tests1 failures (219 → 213 total).

- **Adoption agency algorithm** (2026-01-10): Fixed basic "no furthest block" case to only remove target element from AF, not all formatting elements above it. Fixed reconstruction order after adoption agency for `<nobr>` and `<a>` tags. Fixed all 17 adoption01 tests plus 10 additional tests (231 → 219 total).

- **CDATA sections** (2026-01-10): Implemented tree builder feedback for proper CDATA handling in SVG/MathML vs HTML content. Fixed all 21 tests21 failures (252 → 231 total).

# Test Failures Analysis

**Total: 187 failures out of 1476 tests**

*Last updated: 2026-01-11 after in_frameset mode extraction (was 194 failures)*

## By Test File

| File | Before | After |
|------|--------|-------|
| tests1 | 24 | 23 |
| tests10 | 19 | 18 |
| webkit01 | 17 | 17 |
| template | 16 | 15 |
| webkit02 | 14 | 14 |
| tests7 | 12 | 12 |
| tests19 | 12 | 11 |
| tests3 | 10 | 10 |
| tests17 | 7 | 7 |
| tests20 | 5 | 5 |
| tests2 | 5 | 5 |
| tests26 | 3 | 3 |
| tests18 | 5 | 4 |
| **Total** | **194** | **187** |

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

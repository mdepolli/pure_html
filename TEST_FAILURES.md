# Test Failures Analysis

**Total: 210 failures out of 1476 tests**

*Last updated: 2026-01-10 after initial mode extraction (was 213 failures)*

## By Test File

| File | Before | After | Change |
|------|--------|-------|--------|
| tests1 | 25 | 23 | **-2** |
| tests10 | 20 | 20 | - |
| webkit01 | 17 | 17 | - |
| template | 21 | 17 | **-4** |
| webkit02 | 14 | 14 | - |
| tests19 | 14 | 14 | - |
| tests3 | 12 | 12 | - |
| tests7 | 11 | 10 | **-1** |
| tests18 | 10 | 10 | - |
| tests2 | 8 | 5 | **-3** |
| tricky01 | 7 | 7 | - |
| tests6 | 7 | 7 | - |
| tests17 | 7 | 7 | - |
| tests15 | 6 | 6 | - |
| tests26 | 5 | 5 | - |
| tests20 | 5 | 5 | - |
| Others | ~15 | ~12 | - |

## By Category

| Category | Count | Notes |
|----------|-------|-------|
| Template | 17 | Template mode switching, remaining edge cases |
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

- **Initial mode module extraction** (2026-01-10): Started refactoring insertion modes into separate modules. Extracted Initial mode to `lib/pure_html/tree_builder/modes/initial.ex` with proper whitespace handling and reprocess signaling. Added `:before_html` mode support to transition_to. Fixed 3 tests in tests2/tests7 (213 → 210 total).

- **Template insertion modes** (2026-01-10): Implemented mode switching for table elements in template content. Table structure elements (tbody, thead, etc.) are now added directly when first in template, and ignored when following other table elements without proper table context. Fixed tests 2, 27, 29, 89 and 2 tests1 failures (219 → 213 total).

- **Adoption agency algorithm** (2026-01-10): Fixed basic "no furthest block" case to only remove target element from AF, not all formatting elements above it. Fixed reconstruction order after adoption agency for `<nobr>` and `<a>` tags. Fixed all 17 adoption01 tests plus 10 additional tests (231 → 219 total).

- **CDATA sections** (2026-01-10): Implemented tree builder feedback for proper CDATA handling in SVG/MathML vs HTML content. Fixed all 21 tests21 failures (252 → 231 total).

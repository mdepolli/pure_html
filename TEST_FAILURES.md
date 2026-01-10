# Test Failures Analysis

**Total: 219 failures out of 1476 tests**

*Last updated: 2026-01-10 after adoption agency fixes (was 231 failures)*

## By Test File

| File | Before | After | Change |
|------|--------|-------|--------|
| tests1 | 27 | 25 | **-2** |
| template | 21 | 21 | - |
| tests10 | 20 | 20 | - |
| webkit01 | 17 | 17 | - |
| webkit02 | 14 | 14 | - |
| tests19 | 14 | 14 | - |
| tests3 | 12 | 12 | - |
| tests26 | 12 | 5 | **-7** |
| tests7 | 11 | 11 | - |
| tests18 | 10 | 10 | - |
| tests2 | 8 | 8 | - |
| tricky01 | 8 | 7 | **-1** |
| tests6 | 7 | 7 | - |
| tests17 | 7 | 7 | - |
| tests15 | 6 | 6 | - |
| tests20 | 5 | 5 | - |
| adoption01 | 17 | 0 | **-17** |
| Others | ~15 | ~15 | - |

## By Category

| Category | Count | Notes |
|----------|-------|-------|
| Adoption agency / formatting | ~15 | Reduced from ~30, still complex cases |
| Template | 21 | Template content handling |
| Table | ~20 | Foster parenting, form in table |
| Math/SVG foreign content | ~15 | Integration points, breakout |
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

### Template
```
<template></template><div></div>
<body><template><div><tr></tr></div></template>
<template><template><col>
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

1. **Template** (21) - Template content model handling
2. **Table foster parenting** (~20) - Edge cases with forms, inputs
3. **Foreign content** (~15) - Integration points, breakout tags
4. **Remaining adoption agency** (~15) - Complex cases with tables

## Recent Fixes

- **Adoption agency algorithm** (2026-01-10): Fixed basic "no furthest block" case to only remove target element from AF, not all formatting elements above it. Fixed reconstruction order after adoption agency for `<nobr>` and `<a>` tags. Fixed all 17 adoption01 tests plus 10 additional tests (231 → 219 total).

- **CDATA sections** (2026-01-10): Implemented tree builder feedback for proper CDATA handling in SVG/MathML vs HTML content. Fixed all 21 tests21 failures (252 → 231 total).

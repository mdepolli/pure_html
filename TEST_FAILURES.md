# Test Failures Analysis

**Total: 252 failures out of 1476 tests**

## By Category

| Category | Count | Notes |
|----------|-------|-------|
| Math/SVG foreign content | 21 | CDATA, integration points, breakout |
| Adoption agency / formatting | 16 | `<b>`, `<i>`, `<nobr>`, `<a>` nesting |
| Table | 16 | Foster parenting, form in table |
| Template | 13 | Template content handling |
| Select | 9 | Button in select, nested select |
| Frameset | 8 | After frameset, noframes |
| CDATA in SVG | 6 | `<![CDATA[...]]>` parsing |
| Body attributes | 2 | Second body tag attribute merging |
| DOCTYPE edge cases | 1 | Internal subset parsing |

## By Test File

| File | Failures |
|------|----------|
| tests1 | 10 |
| template | 9 |
| webkit02 | 8 |
| tests21 | 8 |
| tests7 | 6 |
| webkit01 | 5 |
| tests17 | 5 |
| tests10 | 5 |
| tests26 | 4 |
| tests2 | 4 |
| tests3 | 3 |
| tests19 | 3 |
| tests18 | 3 |
| tests16 | 3 |
| tests15 | 3 |
| tricky01 | 2 |
| tests8 | 2 |
| tests6 | 2 |
| tests20 | 2 |
| adoption01 | 2 |
| Others | 8 |

## Sample Failures by Category

### CDATA/SVG (6)
```
<svg><![CDATA[<svg>a
<svg><![CDATA[<svg>]]>
<svg><![CDATA[<svg>]]></path>
<svg><![CDATA[foo]]>
<!DOCTYPE html><svg><![CDATA[foo]]]>
```

### Template (13)
```
<body><template><col><div>
<template><template><tbody><select>
<body><template></div><div>Foo</div><template>
<html a=b><template><frame></frame><html>
<html><head></head><template></template>
```

### Frameset (8)
```
<!DOCTYPE html><frameset></frameset><math>
<!doctype html><frameset></frameset></html>
<frameset><div>
<input type="hidden"><frameset>
<!doctype html><html><frameset></frameset>
```

### Adoption agency / formatting (16)
```
<i>A<b>B<p></i>C</b>D
<b><em><foo><foo><aside></b>
<!DOCTYPE html><body><b><nobr>1<ins><nobr>
<!DOCTYPE html><p><b></p><menuitem>
<!DOCTYPE html><body><b>1<nobr></b><i><nobr>
```

### Table (16)
```
<!doctype html><table><form><form>
<p><table></table>
<!doctype html><table><input type=hidDEN>
<!DOCTYPE html><table><tr><td></p></table>
<a><table><td><a><table></table><a></tr>
```

### Select (9)
```
<template><template><tbody><select>
<select><option>A<select><option>B<select>
<select><button><selectedcontent></button>
<select><b><option><select><option></b>
<!doctype html><select><tfoot>
```

### Math/SVG foreign (21)
```
<svg><![CDATA[<svg>a
<!DOCTYPE html><p><svg><title><p>
<svg><![CDATA[<svg>]]>
<math><mi><div><object><div><span></span>
<math><annotation-xml><svg><foreignObject>
```

## Priority Fixes

1. **SVG/Math foreign content** (21) - CDATA sections, integration points
2. **Adoption agency** (16) - Complex formatting element reparenting
3. **Table foster parenting** (16) - Edge cases with forms, inputs
4. **Template** (13) - Content model handling

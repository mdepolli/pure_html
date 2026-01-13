# Test Failures Analysis

**Total: 87 failures out of 1476 tests**

*Last updated: 2026-01-13*

## By Test File

| File | Phase 5 | Phase 6 | Current |
|------|---------|---------|---------|
| template | 12 | 45 | 9 |
| webkit02 | 13 | 23 | 10 |
| tests1 | 23 | 41 | 10 |
| tests10 | 20 | 33 | 9 |
| tests19 | 13 | 31 | 7 |
| webkit01 | 16 | 23 | 5 |
| tricky01 | 4 | 9 | 3 |
| tests9 | 3 | 14 | 3 |
| tests26 | 3 | 18 | 3 |
| tests17 | 3 | 6 | 0 |
| quirks01 | 3 | 3 | 3 |
| tests7 | 7 | 15 | 2 |
| tests6 | 3 | 13 | 2 |
| tests3 | 10 | 12 | 2 |
| tests20 | 4 | 7 | 2 |
| tests2 | 2 | 10 | 2 |
| tests16 | 3 | 3 | 2 |
| tables01 | 2 | 17 | 2 |
| tests5 | 4 | 4 | 1 |
| tests18 | 8 | 17 | 1 |
| ruby | 1 | 16 | 1 |
| tests8 | 2 | 6 | 1 |
| tests24 | 1 | 1 | 1 |
| tests23 | 1 | 5 | 1 |
| tests22 | 1 | 5 | 1 |
| tests15 | 3 | 11 | 1 |
| tests14 | 1 | 1 | 1 |
| namespace-sensitivity | 1 | 1 | 1 |
| doctype01 | 1 | 1 | 1 |
| tests11 | 3 | 3 | 0 |
| adoption01 | 2 | 16 | 0 |
| adoption02 | 0 | 2 | 0 |
| html5test-com | 1 | 2 | 0 |
| main-element | 0 | 1 | 0 |
| tests12 | 0 | 2 | 0 |
| menuitem-element | 2 | 2 | 0 |
| search-element | 1 | 2 | 0 |
| pending-spec-changes | 1 | 2 | 0 |
| **Total** | **177** | **423** | **87** |

## Status

All 23 HTML5 insertion modes are now implemented (including after_after_body and after_after_frameset). The architecture uses:
- Stack holds only refs: `[ref, ref, ref]`
- Elements map holds all data: `ref => %{tag, attrs, children, parent_ref}`

All failures are assertion failures (tree structure mismatches) rather than crashes. Remaining work focuses on edge cases in adoption agency, foster parenting, and foreign content handling.

## By Category

| Category | Count | Notes |
|----------|-------|-------|
| Template | ~45 | Template mode switching, nested templates |
| Table | ~50 | Foster parenting, form in table |
| Adoption agency / formatting | ~40 | Complex cases need full spec compliance |
| Math/SVG foreign content | ~20 | Integration points, breakout |
| Select | ~15 | Nested select, table in select |
| Body/HTML edge cases | ~10 | Second body attrs, after </html> |

## Priority Fixes

1. **Adoption agency algorithm** (~40) - Need full spec compliance for complex cases
2. **Table foster parenting** (~50) - Edge cases with forms, inputs
3. **Template handling** (~45) - Mode stack switching
4. **Foreign content** (~20) - Integration points, breakout tags

## Recent Fixes

- **Select element table context detection** (2026-01-13): Fixed `<select>` to use `in_select_in_table` mode when opened inside table context. Previously, select always used `in_select` mode regardless of table ancestry. Added `has_table_ancestor?` check when processing select start tag to determine correct mode. This ensures table elements like `<td>`, `<th>`, `<tr>` properly close the select and reprocess when inside table context. Fixed 7 tests (94 → 87 total). tests17: 3 → 0. template: 13 → 9.

- **End tag special elements and input fixes** (2026-01-13): Four fixes: (1) Added `<search>` to `@closes_p` list - search element now properly closes open p elements. (2) Split generic start tag handler to reconstruct active formatting for inline elements but not for block-level elements (in `@closes_p`). (3) Fixed "any other end tag" to check for special category elements per HTML5 spec - end tags now stop at special elements instead of popping through them. Added separate `close_block_end_tag` for block-level end tags that generates implied end tags first. (4) Hidden inputs no longer set frameset_ok to false, allowing frameset to still replace body. Consolidated `@special_elements` into Helpers module. Fixed 9 tests (103 → 94 total). menuitem-element: 2 → 0. search-element: 1 → 0. pending-spec-changes: 1 → 0. tests1: 13 → 10. webkit01: 8 → 5.

- **Multiple tree builder fixes** (2026-01-13): (1) Original mode preservation: style/script in table context now preserves `original_mode` to return to table context after text mode. Applied to in_select for script, after_frameset/after_after_frameset for noframes. (2) Added after_after_frameset insertion mode (23rd mode). (3) Fixed col in template to use in_column_group mode. (4) Added SVG attribute case adjustments. (5) Fixed in_head whitespace handling to split mixed whitespace/non-whitespace and insert whitespace before closing head. (6) Added `:reprocess_with` dispatch for reprocessing with a different token. (7) Removed incorrect `reconstruct_active_formatting()` call from generic start tag handler - AF should not be reconstructed for block-level elements. Fixed 17 tests (120 → 103 total). tests11: 3 → 0. tests18: 7 → 1. template: 11 → 9. tests5: 4 → 1. tests1: 15 → 13.

- **Body/form/after-html fixes** (2026-01-12): Three fixes: (1) Second `<body>` now merges missing attributes onto existing body element (per HTML5 spec, attrs not already on body are added). (2) Nested `<form>` is now ignored when form_element pointer is set and no template on stack. (3) Added `after_after_body` insertion mode for proper handling of content after `</html>` - comments after closing html tag are now placed as siblings of html at document root level. Added `post_html_nodes` to State to track these. Fixed 9 tests (134 → 125 total). webkit01: 15 → 10. tests6: 3 → 2. tests20: 4 → 2.

- **Implement in_select_in_table mode** (2026-01-12): Added the final HTML5 insertion mode. This mode handles select elements opened inside table context. Per spec, table element end tags (caption, table, tbody, tfoot, thead, tr, td, th) close the select and reprocess. Delegates all other processing to InSelect. All 21 HTML5 insertion modes are now complete. No test changes (137 total).

- **Scope and foster parenting fixes** (2026-01-12): Three fixes: (1) `</li>` now only closes if li is in "list item scope" (ul/ol are barriers). Added `close_li_in_list_scope` with proper scope checking. (2) `<head>` in in_body is now properly ignored (parse error per spec). (3) In table context, `</br>` is now foster-parented as `<br>` instead of delegating to InBody. Also fixed `</select>` in table context to not call `pop_mode()` which was incorrectly changing mode to in_body. Fixed 7 tests (144 → 137 total). tests1: 18 → 16. tests15: 3 → 2.

- **MathML mglyph/malignmark namespace fix** (2026-01-12): Elements `mglyph` and `malignmark` should remain in the MathML namespace even when inside MathML text integration points (mi, mo, mn, ms, mtext). Added `mathml_text_integration_point?` helper and special-case handling in start tag processing. Fixed 10 tests (154 → 144 total). tests10: 20 → 10 failures.

- **Leading newline stripping for pre/textarea/listing** (2026-01-12): Per HTML5 spec, a single newline immediately following the start tag of a pre, listing, or textarea element is ignored. Added `maybe_skip_leading_newline` helper that checks if current element is one of these tags with no children yet, then strips the leading newline. Fixed 9 tests (163 → 154 total). tests3: 10 → 2 failures. tests7: 7 → 6 failures.

- **TreeBuilder code simplification** (2026-01-12): Simplified TreeBuilder and all submodules for improved readability and reduced cyclomatic complexity. Key changes: pattern matching in function heads instead of nested conditionals, pipeline usage with `then/2`, extracted reusable helpers (`find_html_ref_in_elements`, `remove_child_from_parent`, `foster_foreign_element`, `close_if_current_tag`, `pop_head_if_current`, `pop_noscript_if_current`), removed unnecessary `do_` wrapper functions, consolidated duplicate code. No test changes - all 163 failures remain unchanged.

- **Foreign content breakout and heading nesting fixes** (2026-01-12): Fixed two issues: (1) `pop_foreign_elements` was returning `elements[ref].parent_ref` but should return `ref` itself - when breaking out of SVG/MathML, new elements should be children of the first non-foreign element (body), not its parent (html). (2) Headings no longer use the general `@implicit_closes` map. Added `maybe_close_current_heading` which only closes a heading if the current node is a heading (per spec). Added `close_any_heading` for heading end tags which close any open heading in scope. Fixed 28 tests (191 → 163 total). tests26: 11 → 3 failures. tests10: 25 → 20. tests19: 12 → 9.

- **Ruby element implicit closing fix** (2026-01-12): Fixed `pop_to_implicit_close_all_ref` to return the top of stack as `current_parent_ref` instead of its parent. After closing all matching ruby elements (rb, rt, rtc, rp), new elements should be children of the remaining top element (e.g., ruby). Fixed 19 tests (210 → 191 total). ruby tests: 16 → 1 failure. tests19: 16 → 12 failures.

- **Frameset handling fixes** (2026-01-12): Fixed two frameset issues: (1) `close_body_for_frameset` now removes body from html's children in the DOM, not just from the stack. This ensures body and its content are properly removed when frameset replaces it. (2) Added frameset/frame handlers in InTable to ignore them (parse error per spec, since table sets frameset_ok to false). Fixed 13 tests (223 → 210 total). tests19 down from 23 to 16 failures.

- **pop_until_one_of current_parent_ref fix** (2026-01-12): Fixed `pop_until_one_of` to set `current_parent_ref` to the boundary element itself, not its parent. This was causing elements inside templates (and other table context boundaries) to be inserted at the wrong level. When clearing to a boundary like template/tr/html, new elements should become children of that boundary element. Fixed 92 tests (315 → 223 total). Template tests down from 39 to 10 failures. adoption01 now passes completely (0 failures).

- **Unified foster parenting API** (2026-01-12): Consolidated four separate foster_* functions into a single `foster_parent/2` function with tagged tuple API: `{:text, text}`, `{:element, tuple}`, `{:push, tag, attrs}`, `{:push_foreign, ns, tag, attrs, self_closing}`. No test changes, just code cleanup.

- **Foster parenting insertion order** (2026-01-12): Fixed foster parenting to insert content BEFORE the table element in the parent's children list (per HTML5 spec). Previously content was appended. Added `insert_ref_before_in_parent`, `insert_child_before_in_elements`, `insert_text_before_in_elements` functions. Fixed adoption agency to use `foster_parent_ref` for common ancestor when FE was foster parented. Added active formatting reconstruction during foster parenting of text in `in_table_text` mode. Added `:in_cell`, `:in_row`, `:in_caption`, `:in_table_body` to `@body_modes` so delegating to InBody doesn't change mode. Fixed 40 tests (355 → 315 total). adoption01 down to 2 failures (table structure nesting issue).

- **Adoption agency algorithm fixes** (2026-01-12): Fixed critical bug in `find_in_stack_by_ref` that expected `%{ref: ref}` but stack now contains bare refs (adoption agency never ran). Fixed `reconstruct_active_formatting` to use ref-only stack architecture - was pushing full element maps instead of refs, and not adding elements to elements map or setting parent/child relationships. Implemented full HTML5 adoption agency inner loop. Fixed 68 tests (423 → 355 total). adoption02 now passes completely.

- **Stack/DOM separation Phase 6** (2026-01-12): Completed migration to ref-only stack architecture. Updated all mode modules (after_body, in_body, in_column_group, in_frameset, in_head_noscript, in_select, in_template) to use refs instead of full elements. Added `is_map_key` guard clauses for nil-safety. Removed unused legacy functions from tree_builder.ex. Code compiles with zero warnings. All failures are now assertion failures (no crashes). Regression from 177 → 423 failures expected during architectural migration.

- **Stack/DOM separation Phase 5** (2026-01-11): Refactored tree builder architecture to separate parsing context (stack) from DOM structure (elements map). Added `current_parent_ref` to State for O(1) parent tracking. Elements now store explicit `parent_ref` relationships. Foster parenting now uses explicit `foster_parent_ref` markers instead of tag-based heuristics in finalization. Pop operations track element-to-element children in elements map. Replaced heuristic-based `foster_aware_add_child` with `add_to_parent` that uses explicit refs. Fixed 1 test (178 → 177 total).

- **In table text and in head noscript modes** (2026-01-11): Added two new insertion modes. `in_table_text` properly collects and batches character tokens in table context before deciding whether to insert normally (whitespace only) or foster parent (non-whitespace). `in_head_noscript` handles content inside `<noscript>` within `<head>` when scripting is disabled. Also fixed `in_caption` to set mode to `:in_table` when closing caption for reprocessing. Fixed 1 test (179 → 178 total).

- **In table mode extraction** (2026-01-11): Extracted `in_table` insertion mode to `lib/pure_html/tree_builder/modes/in_table.ex`. Handles table-specific token processing including foster parenting for non-table elements, table structure elements (caption, colgroup, tbody, thead, tfoot, tr, td, th), and SVG/math foreign content. Key changes: (1) Added foreign content delegation - when top of stack is svg/math, delegates to InBody for proper handling. (2) All foster parenting logic now in InTable instead of scattered in InBody and tree_builder.ex. (3) Fixed InCell's cell-closing end tags to check if target tag is in table scope before closing cell. (4) Fixed input handling - non-hidden inputs are now foster-parented. Some tests improved (tests7: 11→7), some regressed (tests19: 11→14). Net +1 regression (178 → 179 total).

- **In template mode extraction** (2026-01-11): Extracted `in_template` insertion mode to `lib/pure_html/tree_builder/modes/in_template.ex`. Handles template-specific token processing including nested templates, head elements (base, link, meta, script, style, title), and table structure elements. Fixed mode switching for non-table start tags to properly switch to `:in_body` mode so end tags close elements correctly. Added O(1) `template_mode_stack` check for html start tag handling instead of O(n) stack traversal. Fixed 2 tests (180 → 178 total).

- **In select mode extraction** (2026-01-11): Extracted `in_select` insertion mode to `lib/pure_html/tree_builder/modes/in_select.ex`. Properly handles option/optgroup opening and closing, table structure elements (close select and reprocess), svg/math elements with namespaces, and ignores table elements per spec. Fixed 7 tests (187 → 180 total).

- **In frameset mode extraction** (2026-01-11): Extracted `in_frameset` insertion mode to `lib/pure_html/tree_builder/modes/in_frameset.ex`. Fixed end tag handling to properly pop frameset element and switch to after_frameset mode when current node is no longer a frameset (was incorrectly staying in in_frameset mode). Fixed 7 tests (194 → 187 total).

- **In body mode extraction** (2026-01-11): Extracted `in_body` insertion mode to `lib/pure_html/tree_builder/modes/in_body.ex` (~1700 LOC). Moved all start tag handling, end tag handling, character processing, foreign content, adoption agency algorithm, active formatting elements, foster parenting, and implicit closing logic. Fixed end tag handling in foreign content to properly break out of SVG/MathML before processing `</p>` and `</br>`. Fixed 2 tests (196 → 194 total).

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `PureHTML.Serializer.void_element?/1`
- The html5lib runners list fixtures recursively under relative names (`scripted/webkit01`), run the three `unsafe` tree-construction files, and report fixtures they cannot pass as skipped tests with the reason: `scripted/` fixtures need script execution, the four `unicodeCharsProblematic` tokenizer cases hold a lone surrogate that only a script API can put in the input stream, and the html5lib serializer cases test html5lib's token serializer rather than the fragment algorithm, each classified from the case itself (options, PUBLIC/SYSTEM doctype, an end tag with no open element, an unclosed start tag, or an omitted end tag), with no file skipped by name
- The html5lib serializer suite builds a tree from each token stream and serializes it through `PureHTML.Serializer` instead of a copy of the serializer
- The html5lib tree-construction runner asserts `error_count == length(#errors)` as well as the tree. `webkit02:44-48` and `adoption02:2` get the living standard's errors from `test/fixtures/corrections/` (`#spec` citation, `text:` lines) where the fixtures contradict it
- `{:pi, target, data}` processing-instruction nodes. `<?php …?>` is a PI; `<?xml …>` and `<?xml-stylesheet …>` stay comments. html5lib `<?` tokenizer and tree fixtures that still expect the old bogus-comment path are corrected from `test/fixtures/corrections/`

### Changed

- Parse properties generate raw bytes, UTF-8, NUL, NBSP, PIs, foreign elements, and template contents instead of printable strings, and assert node shape, `to_html/2` UTF-8, and `text/2` on every run
- The html5lib fixtures are vendored byte for byte under `test/fixtures/html5lib/` from html5lib-tests `9329e64` instead of a git submodule. Cases that contradict the living standard are corrected by the runners from keyed blocks in `test/fixtures/corrections/`, each with a citation and a snapshot of the upstream expectation so a case upstream changes fails by name. `mix html5lib.sync` lists every file that differs from upstream at the per-directory pins in `UPSTREAM`; `mix html5lib.sync <commit>` moves the pin of each directory the commit still has and leaves the others where they are, so tree-construction stays at `9329e64`
- `PureHTML.to_html/2` serializes a doctype as `<!DOCTYPE name>` per the HTML fragment serialization algorithm; public and system identifiers are no longer written, and a missing name keeps the space (`<!DOCTYPE >`)
- Query results come in document order: a selector list such as `"p, span"` returns matches in the order they appear in the tree, `query_one/2` returns the first of them, identical sibling elements are distinct matches, and elements inside `<template>` content are found. `query_one/2` stops at the first match
- The `xmlns` attribute on a foreign element is stored as `{{:xmlns, "xmlns"}, value}`, matching the adjust-foreign-attributes table

### Fixed

- Numeric character references in RCDATA (`<title>&#65;</title>`) no longer raise
- Invalid UTF-8 in the input is replaced with U+FFFD before tokenizing, so markup with stray bytes no longer raises
- Foreign attributes with a namespace prefix (`xlink:href`, `xml:lang`, `xmlns:xlink`) serialize with their prefix instead of raising
- Input stream parse errors for control characters and noncharacters are counted
- Named character references stay linear before a long run of ASCII
- U+0000 is ignored in body and in table text with a parse error, and replaced with U+FFFD in foreign content; the first character token in a table is reprocessed through the in-table-text rules
- The character after `<` in the script data escaped state keeps its case in the emitted text
- In column group inserts leading whitespace once and reprocesses only the rest of the token
- ASCII whitespace, not Unicode whitespace, is what the insertion modes test for, so U+00A0 is a character before the first tag, in a table, in noscript, and for frameset-ok
- The quirks mode decision encodes the WHATWG public-identifier lists, so HTML 4.01 Strict and XHTML 1.0 Strict are no-quirks and a table closes an open `p`
- An `<html>` start tag in before head, after head, after body, and after after body is processed with the in-body rules in place: attributes merge, no head or body is implied, and the mode stays, so a following comment lands on the html element or the document
- In template follows its start-tag list as written: html, head, body, and noscript move the template to in body, and a stray `tr` after non-table content is ignored by in body's rules
- HTML breakout inside foreign content stops at a MathML text integration point
- A table start tag at an HTML integration point is inserted there rather than foster-parented past the foreign content; in body's unreachable table-structure arms are gone
- A button start tag closes an open button in default scope with implied end tags, then reconstructs the active formatting elements before inserting
- In table: a non-hidden `<input>` and `</br>` go through the in-body rules with foster parenting; a form is inserted despite an open form when parsing template contents; `td`, `th`, and `tr` always get a `tbody`
- `</frameset>` in a frameset fragment does not switch to after frameset; whitespace in after body, after after body, and after after frameset reconstructs the active formatting elements
- Reset the insertion mode respects the last flag for head, td, and th, so a head- or td-context fragment resets to in body; the noscript step that the algorithm does not have is gone
- CDATA sections are recognized only when the adjusted current node is in the SVG or MathML namespace; an HTML fragment context yields a bogus comment
- `param`, `source`, and `track` insert without reconstructing the active formatting elements; `</br>` sets frameset-ok to "not ok"; the any-other-end-tag walk matches HTML elements only; a line feed after `<pre>`, `<listing>`, or `<textarea>` is ignored only when it is the very next token
- The `selectedcontent` replay follows the forms chapter: the first selectedcontent descendant, no clone with `multiple` or a display size other than 1, options found through optgroup, the last selected option wins, disabled options are skipped, and a text node before the button no longer crashes it

## [0.4.0] - 2026-09-13

### Added

- `PureHTML.parse_with_errors/2`: parses like `parse/2` and returns `{nodes, error_count}`, where the count follows the WHATWG parse errors emitted by the tokenizer and tree builder
- `scripting:` option for `PureHTML.parse/2` (default: `true`)
  - When `false`, `<noscript>` content is parsed as HTML instead of raw text
  - Per WHATWG spec, affects `in_head`, `in_body`, and `in_template` insertion modes: `<noscript>` content is raw text only when scripting is on
- html5lib tree construction tests now run in both scripting modes per the test README
  - Tests without `#script-off`/`#script-on` run in both modes
  - `#script-off` tests are no longer skipped
  - Filter with `--only scripting:on` or `--only scripting:off`

### Fixed

- Fragment parsing: form element pointer now set when context element is `<form>` (WHATWG spec step 13)
- Parse error counts now follow the WHATWG rules
  - Tokenizer: end tags with attributes, trailing solidus on non-void start tags, C1 control and unknown named character references, EOF inside script comment-like text
  - Foreign content: HTML and `<body>` start tags inside foreign content, mismatched foreign end tags; no error at HTML integration points
  - Tables: ignored `<tr>` and table-structure start tags, mismatched cell end tags, foster-parented characters and end tags (including `</p>`, which now foster-parents through the in-body rules), an implied cell when the current node is not a cell, `<frameset>` and `<frame>` inside a table, and end tags in a nested table, which no longer bypass the in-table rules
  - Column groups and templates: `<col>` outside a colgroup, `<colgroup>` in body or inside a template, SVG and HTML breakout inside a colgroup, `<tr>` after non-table template content, foster-parented tags in a template row, `<html>` and `<a>` inside template table content, mismatched `</template>`, and characters and EOF in frameset, column group, and template contexts
  - Elsewhere: `<rp>`/`<rt>` outside `ruby`, `<frame>` outside a frameset, `</html>` and `</frameset>` on a fragment root, `</frameset>` in body, caption-closing tokens and mismatched caption end tags, and `</form>` whose form element is out of scope (the form now stays open, as specified)
- EOF is dispatched through the insertion modes per the spec instead of being handled once at the end
- Closing a caption now generates implied end tags first and clears the active formatting list to its marker, so formatting elements opened before the table are reconstructed after it
- `xmp`, `iframe`, and `noembed` in body now switch to the text insertion mode, so EOF inside them is counted once for the raw text element and once for other open elements
- Duplicate `<a>` start tags follow the spec: the adoption agency runs, then the old element is removed from the active formatting list and the stack even when a table put it out of scope; `<nobr>` uses its own scope-based rule
- Reconstructed formatting elements are foster-parented when foster parenting applies
- `<frameset>` in caption, cell, and table contexts is a parse error and is ignored; it is no longer silently accepted, nor inserted in fragments with no body
- Query: redundant clauses for namespaced elements removed
- `select` is a scope boundary, as in the current standard, so an end tag for an element opened outside a select is ignored inside it
- `<select>` inside a table is foster-parented like any other in-body element; `<input>` in a select-context fragment is ignored; a nested `<select>` closes the open select; `option`, `optgroup`, and `hr` inside a select generate implied end tags per spec
- `td` and `th` start tags in body are a parse error and ignored; `<col>` in a table switches to "in column group"; `<svg>` and `<math>` in a table go through the in-body rules with foster parenting; the adoption agency uses the shared scope walk
- Foreign content follows the tree construction dispatcher and the foreign content rules as written: a token at an integration point is processed with the current insertion mode; an HTML breakout start tag, and `</br>`/`</p>`, pop out of foreign content and are reprocessed with the current mode; the end-tag walk returns at the topmost node in a fragment; a foreign end tag that reaches in body is any other end tag; the scope walk covers the stack of open elements only
- A start tag whose self-closing flag is never acknowledged is a parse error for every non-void HTML element, not only those on the generic path; `</td>` and `</th>` in body are any other end tag
- Serializer: `<` and `>` are escaped in attribute values, per the spec's "escaping a string" algorithm; the `:escape_lt_in_attrs` option is removed since the escaping is no longer optional
- Tokenizer: `>` right after `<!DOCTYPE` is only the missing-doctype-name error; an ampersand followed by a name that matches no character reference is an error only when a semicolon ends the name (the ambiguous ampersand state)
- Table text is collected when the current node is a `template`; a cell end tag generates implied end tags before checking the current node; character and comment tokens in a row are processed with the in-table rules for that token, so the row is the mode that resumes
- Head elements (`base`, `link`, `meta`, `title`, `style`, `script`, `noframes`, `template`, and `noscript` with scripting on) are processed with the in-head rules from every mode that delegates to them, and the text insertion mode returns to the mode that opened the element; in body no longer inserts them itself or treats characters under them as raw text by checking the current tag
- Opening a template pushes "in template" onto the stack of template insertion modes; its end tag pops that entry and resets the insertion mode appropriately, which yields "after head" for the html node once the head element pointer is set
- `li`, `dd`, and `dt` start tags close an open item by walking the stack as specified: an item of the same kind is closed with implied end tags except itself, and a special element other than `address`, `div`, or `p` ends the walk; `menuitem` is no longer in the special category
- `rb`, `rtc`, `rp`, and `rt` have their own in-body entries: implied end tags (except `rtc` for `rp`/`rt`) with a ruby element in scope, then a parse error unless the current node is what the text names; they no longer close a `p`
- A formatting end tag with no entry in the active formatting list is handled by the any-other-end-tag step without an error of its own, on any iteration of the adoption agency's outer loop
- `textarea` follows the generic RCDATA algorithm (text insertion mode, a leading line feed dropped there); `plaintext` switches the tokenizer without leaving the current mode, so a `<plaintext>` ignored in frameset leaves the tokenizer alone
- "Close a p element" runs the text's three steps (implied end tags except `p`, then the current-node check, then the pop), so a `p` closed over an open `option` is not an error
- Frameset-ok is set to "not ok" only by the start tags the text lists; `form`, `noembed`, `noframes`, `plaintext`, `rb`, and `rtc` no longer block a later `<frameset>`
- In head's "anything else" pops the current node unconditionally, and EOF in head noscript takes that path too, so a `<head>` fragment or an open `<noscript>` at EOF no longer ends up holding the body
- The active formatting elements are reconstructed from the last marker or still-open entry forward, as specified; popping an element no longer strips its entry from the list
- Non-whitespace table text is reprocessed through in table's "anything else" entry (parse error, foster parenting, in body rules) instead of a private reconstruction
- The body start tag follows the text: parse error, ignored with a template on the stack or when the second element of the stack is not a body, otherwise frameset-ok "not ok" and merged attributes
- Closing a table (or a nested table start tag) pops through the table and resets the insertion mode appropriately, where a template node yields the current template insertion mode
- The adoption agency follows the text step by step: the early exit for a current node not in the list, the formatting element search bounded by the last marker, lastNode inserted at the appropriate place for the common ancestor (foster parented when foster parenting is on), and the any-other-end-tag step for a missing entry on any iteration
- A CDATA section is recognized whenever the adjusted current node is not in the HTML namespace, including inside an SVG or MathML integration point such as `<svg><title>`; it was a bogus comment there
- The in-body `<svg>` and `<math>` entries reconstruct the active formatting elements before inserting the element, as their text says

### Removed

- The "in select" and "in select in table" insertion modes, and "select scope". The standard removed them; select content is parsed with the in-body rules (`select`, `option`, `optgroup`, `hr`, and `input` entries, and `</select>` as a generic block end tag)

### Changed

- Tree builder internals: insertion modes are unary state pipelines; foster parenting is enabled for one token and settled by the tree builder; the in-table "anything else" rules delegate to the in-body rules instead of a second implementation; scope walks take the scope type and state; implied end tags and the in-body delegation helpers live in `Helpers`
- The tree builder switches the tokenizer state (RCDATA, RAWTEXT, script data, PLAINTEXT) as the text describes; the tokenizer no longer switches on its own when it emits a start tag, and no longer takes a `scripting` option
- Every "process the token using the rules for X" is a plain delegation: the template end tag lives in in head, EOF and `<html>` in the table-family, column group, frameset, and after head modes go to in body or in head without switching modes, and the in-table delegation no longer saves and restores the caller's mode
- The insertion parent is the top of the stack of open elements; the separately stored parent pointer is gone
- The stack of template insertion modes holds only template insertion modes; the table return-mode push/pop is gone
- In body no longer creates html, head, or body elements on the fly for other modes, and finalize no longer patches a missing head or body in; the insertion modes' EOF rules produce them
- In body's start tag entries take the token, and the adoption agency works on element refs with one function per step of the text; elements no longer carry a foster-parent marker
- The `selectedcontent` mirroring of the customizable select is replayed by `PureHTML.TreeBuilder.SelectedContent` after parsing, documented as the forms chapter's "update a select's selectedcontent" rather than a tree construction step
- Foreign content has its own module, `PureHTML.TreeBuilder.ForeignContent`, mirroring the text's section: the dispatcher decision, the rules for parsing tokens in foreign content, the tokenizer's CDATA test, element insertion with the SVG tag and foreign attribute adjustments, the integration point tests, and breaking out
- html5lib-tests submodule pinned at `9329e64` (2026-06-22), the last upstream commit with the tree-construction fixtures before they moved to web-platform-tests; it adds the `void-in-phrasing` fixtures, an adoption case, and corrects `<input><option>` in a select-context fragment
- html5lib tree-construction tests count `#errors` lines only; `#new-errors` are renamed tokenizer codes, not extra errors
- html5lib tokenizer and tree-construction suites run one test per fixture file, looping over the cases at run time; the full suite drops from about 68 seconds to under one, since compiling the generated per-case test functions was the cost. `HTML5LIB_CASE=file:index` runs a single case
- Tool versions: Erlang 28.4.2 and Elixir 1.20.4; dev dependencies grouped and upgraded

## [0.3.0] - 2026-02-15

### Added

- Fragment parsing via `PureHTML.parse/2` with `context:` option
  - Implements the WHATWG "parsing HTML fragments" algorithm (used by `innerHTML`)
  - Context format matches html5lib tests: `"div"`, `"body"`, `"svg path"`, `"math mtext"`
  - Returns children directly (no `<html>/<head>/<body>` wrappers)
- Tree construction dispatcher per WHATWG spec
  - Centralized foreign content routing replaces per-mode ad-hoc checks
  - Adjusted current node handling for fragment parsing contexts
  - Integration point exceptions for MathML text and HTML integration points

### Fixed

- Compile warnings in Query module: grouped `apply_combinators/3` clauses and removed duplicate `adjacent_sibling_matches/3`
- `in_table_body` delegation now calls `InTable.process` directly instead of switching modes, preserving tree construction dispatcher context for foreign content
- Foster-parented elements no longer incorrectly removed from active formatting list during `pop_until_tag`
- Table structure elements (tbody/thead/tfoot/caption/colgroup) handled correctly at foreign integration points in all table-related modes
- Fragment tokenizer no longer sets `last_start_tag`, so end tags in escaped script/rawtext/rcdata contexts are correctly treated as character tokens

## [0.2.0] - 2026-01-20

### Added

- Text extraction with `text/2` function
  - Options: `:deep`, `:separator`, `:strip`, `:include_script`, `:include_style`, `:include_inputs`
- Attribute extraction functions
  - `attr/2` - get attribute from single node
  - `attribute/2` - extract attribute from list of nodes
  - `attribute/3` - query and extract attribute in one step
- `query_one/2` for finding first matching element
- CSS combinator support in selectors
  - Descendant combinator (space): `div p`
  - Child combinator: `div > p`
  - Adjacent sibling combinator: `h1 + p`
  - General sibling combinator: `h1 ~ p`

## [0.1.0] - 2026-01-19

### Added

- CSS selector querying with `query/2` and `children/2` functions
  - Tag selectors: `div`, `p`, `a`
  - Universal selector: `*`
  - Class selectors: `.class`, `.foo.bar`
  - ID selectors: `#id`
  - Attribute selectors: `[attr]`, `[attr=val]`, `[attr^=prefix]`, `[attr$=suffix]`, `[attr*=substring]`
  - Compound selectors: `div.class#id[attr]`
  - Selector lists: `.a, .b`
- `get_attr/3` helper for retrieving attribute values from lists
- `merge_attr_lists/2` helper for merging attribute lists (preserves existing values)
- Serializer options for customizable HTML output (`:print_attributes`, `:escape_comment`, `:escape_empty`)
- `xml_violation_mode` for XML infoset coercion in tokenizer
- All tokenizer initial states enabled in test harness
- All 23 HTML5 insertion modes implemented:
  - `initial`, `before_html`, `before_head`, `in_head`, `in_head_noscript`
  - `after_head`, `in_body`, `text`, `in_table`, `in_table_text`
  - `in_caption`, `in_column_group`, `in_table_body`, `in_row`, `in_cell`
  - `in_select`, `in_select_in_table`, `in_template`, `after_body`
  - `in_frameset`, `after_frameset`, `after_after_body`, `after_after_frameset`
- HTML5lib tree construction test suite integration (1476 tests)
- Adoption agency algorithm for proper formatting element handling
- Active formatting elements list reconstruction
- Foster parenting for misplaced table content
- Foreign content support (SVG and MathML namespaces)
- SVG attribute case adjustments (e.g., `viewbox` -> `viewBox`)
- Template element handling with template mode stack
- Implicit tag closing per HTML5 specification
- Leading newline stripping for `pre`, `textarea`, and `listing` elements
- Ruby element implicit closing (`rb`, `rt`, `rtc`, `rp`)
- Second `<body>` tag attribute merging
- Nested `<form>` handling (ignored when form pointer is set)
- Post-`</html>` content handling (comments as document siblings)
- HTML serializer with html5lib-compliant tree output format
- DOCTYPE quirks mode detection per HTML5 specification

### Changed

- **BREAKING**: Attributes now use list of tuples instead of maps for Floki compatibility
  - Before: `{"p", %{"class" => "foo"}, ["Hi"]}`
  - After: `{"p", [{"class", "foo"}], ["Hi"]}`
  - Attributes are sorted alphabetically for deterministic output
- Simplified `in_table.ex` with guard clauses and reduced helpers
- Consolidated `foreign_namespace` helper in helpers.ex
- Refactored tree builder to ref-only stack architecture
  - Stack holds only refs: `[ref, ref, ref]`
  - Elements map holds all data: `ref => %{tag, attrs, children, parent_ref}`
- Consolidated foster parenting into unified `foster_parent/2` API with tagged tuples
- Extracted all insertion modes to separate modules under `lib/pure_html/tree_builder/modes/`
- Multi-byte scanning optimization in tokenizer for faster parsing
  - `chars_until_null`, `chars_until_comment`, `chars_until_cdata`
  - Entity reference fast path detection

### Fixed

- Active formatting reconstruction before foster-parenting formatting elements in table context
- Frameset/noframes mode transitions
- Ruby nesting edge cases
- Table handling in `foreignObject`
- Multiple tree construction edge cases
- Original mode preservation for style/script in table context
- `</li>` now only closes when `li` is in list item scope (ul/ol are barriers)
- `<head>` in body mode is now properly ignored
- `</br>` in table context is foster-parented as `<br>`
- MathML `mglyph`/`malignmark` namespace preservation in text integration points
- Foreign content breakout for HTML elements inside SVG/MathML
- Heading nesting (h1-h6 now properly close previous headings)
- Frameset handling (body removal from DOM when replaced by frameset)
- `pop_until_one_of` boundary element handling for template context
- `</svg>` and `</math>` now properly close all foreign children
- Foreign content scope boundaries for `in_scope?` checks (SVG: desc, foreignObject, title; MathML: annotation-xml, mi, mn, mo, ms, mtext)
- Select mode end tag handling to close pushed HTML elements
- Void elements (img, br, etc.) treated as self-closing in select mode
- `<selectedcontent>` population with first/selected option content
- Adoption agency for formatting elements inside select mode
- Active formatting reconstruction before text insertion in select mode
- `</p>` handling in table context with foster parenting
- Option closing when new option/optgroup starts
- `<li>` in table context handling
- HTML5 whitespace handling in various contexts
- Table/anchor active formatting handling and scope checks
- Form element pointer handling and nested form detection
- Row mode bogus `<tr>` detection
- `current_parent_ref` handling in foster parenting contexts
  - Fixed `close_tag_ref`, `close_block_end_tag`, `close_foreign_root` to use stack top
  - Fixed adoption agency to use stack top after popping elements
- Active formatting reconstruction for void elements in table context
- Row mode foster parenting with in_body rules delegation

[Unreleased]: https://github.com/mdepolli/pure_html/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/mdepolli/pure_html/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/mdepolli/pure_html/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mdepolli/pure_html/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mdepolli/pure_html/releases/tag/v0.1.0

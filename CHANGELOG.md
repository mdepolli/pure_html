# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

### Current Status

- **All 8,634 html5lib tests passing (100%)**
  - Tokenizer: 7,036 tests
  - Tree construction: 1,476 tests
  - Encoding: 82 tests
  - Serializer: 40 tests

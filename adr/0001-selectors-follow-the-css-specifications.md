# 1. Selectors follow the CSS specifications, and browser engines on identifiers

Date: 2026-10-14

## Status

Accepted

## Context

`PureHTML.query/2`, `query!/2`, `query_one/2`, `query_one!/2`, and
`attribute/3` take a CSS selector string and match it against a parsed
tree. No browser is involved, so the library has to define which strings
are selectors and what they match. It supports type and universal
selectors, classes, IDs, attribute presence and the `=`, `^=`, `$=`, and
`*=` operators, the four combinators, and selector lists.

These texts define selector syntax and matching:

- CSS Syntax Module Level 3, Editor's Draft of 12 October 2026, defines
  the tokens: identifiers, escapes, strings, comments, and the non-ASCII
  code points an identifier may hold. Its section 3 says that user agents
  "must either act as described below when encountering such problems, or
  must abort processing at the first error". At the end of the input,
  "consume a string token" says "This is a parse error. Return the
  <string-token>", "consume a simple block" returns the block, and a
  comment still open runs to the end.
- Selectors Level 4, Editor's Draft of 18 September 2026, defines the
  grammar and the matching. "Attribute values must be <ident-token>s or
  <string-token>s", and "in <id-selector>, the <hash-token>'s value must be
  an identifier". Its section 3.9 says "An invalid selector represents,
  and therefore matches, nothing", "a simple selector containing an
  undeclared namespace prefix is invalid", and "a selector list containing
  an invalid selector is invalid". A note there adds that "UAs must treat
  as invalid any pseudo-classes, pseudo-elements, combinators, or other
  syntactic constructs for which they have no usable level of support". In
  a quirks-mode document, IDs and class names compare ASCII
  case-insensitively.
- The HTML Living Standard of 14 October 2026, "Case-sensitivity of
  selectors", lowercases type selectors and attribute names for HTML
  elements, lists 46 attributes whose values compare ASCII
  case-insensitively, and relays the quirks-mode rule for IDs and classes.
  Its "initial" insertion mode puts a document parsed without a doctype in
  quirks mode, unless it is an iframe srcdoc document. A fragment takes the
  mode of its context document.
- DOM, Living Standard of 9 October 2026, "scope-match a selectors
  string": "If selector is failure, then throw a "SyntaxError"
  DOMException." This is what `querySelectorAll` does with an invalid
  selector. It matches against the node's root, with the node as the
  scoping root. Its section 1.3 says "Support for namespaces within
  selectors is not planned and will not be added."

PureHTML's tree builder computes the document mode while it parses. The
result of `PureHTML.parse/2` is a list of Floki-shaped nodes. It starts
with a `{:doctype, name, public_id, system_id}` node when the input has a
doctype, and keeps neither the mode nor the doctype's force-quirks flag.
On an HTML element, a colon in an attribute name is part of the name, as
in `x-on:click`. On an SVG or MathML element, a namespaced attribute is a
tuple such as `{:xlink, "href"}`. A query from a node matches that node
and its descendants, template contents included.

The texts and the browser engines disagree on the non-ASCII ident code
points. CSS Syntax 3 limits them to a list of ranges, which leaves out
U+0080 to U+00B6, U+00D7, U+200B, and U+FFFF, among others. The engines
accept any code point from U+0080 up:

- Blink's `IsNameStartCodePoint` is `IsAsciiAlpha(c) || c == '_' ||
  !IsAscii(c)`, in
  `third_party/blink/renderer/core/css/parser/css_parser_idioms.h`, and
  WebKit's `isNameStartCodePoint` in `CSSParserIdioms.h` is the same test,
  both read on their main branches on 14 October 2026. Headless Chrome
  155.0.8059.41 accepts `.a`, U+00A0, `b` as one class selector.
- rust-cssparser 0.38.0 has `is_ident_start` accept any non-ASCII byte
  (`src/tokenizer.rs`). Firefox 158.0, released on 13 October 2026,
  vendors it at git rev `ddccc070`.
- In web-platform-tests, `dom/nodes/ParentNode-querySelector-escapes.html`
  (last changed in `306b7ef277`, 7 April 2020) asserts that `#` followed
  by U+2003 or U+00A0 matches an element with that ID. Both are outside
  the ranges. On wpt.fyi on 14 October 2026, Chrome 155.0.8059.79,
  Firefox 157.0, and Safari 27.0 pass all 68 of its subtests.
- `css/css-syntax/non-ascii-codepoints.html` (`ff463bea68`, 23 May 2023)
  was written to assert the ranges, on `animation-name` identifiers. A
  missing comma in its list of ranges makes it throw before its first
  rejection check. wpt.fyi reports a harness error, and the 15 subtests
  that run, which all three browsers pass, only check code points the
  ranges allow.
- CSSWG issue #7129 (https://github.com/w3c/csswg-drafts/issues/7129),
  "[css-syntax] custom property names too permissive, require namespacing
  rules", was open on 14 October 2026, labeled Agenda+, Needs Testcase
  (WPT), css-syntax-3, cssom-1, and i18n-needs-resolution. On 12 October
  2026 the CSS Syntax editor wrote that the group "resolved in 2022 to
  match HTML's custom element/attribute name rules", that "in 2025 HTML
  relaxed the rules significantly", and asked whether to switch back to
  allowing any non-ASCII code point or keep the ranges.

Under the ranges, an escape still spells any non-ASCII code point:
`.a\a0 b` is a valid class selector for `a`, U+00A0, `b`.

Version 0.5.0 read selectors by rules of its own. Reproduced at the
`v0.5.0` tag on Elixir 1.20.4 and OTP 28.4.2:

- `[href$=.pdf]`, `[data-n=1]`, `.1foo`, and `#1foo` were accepted and
  matched.
- A colon in an attribute name was part of the name. `[x-on:click]`
  matched `x-on:click` on an HTML element, and `[xlink:href]` matched
  nothing on an SVG element and raised nothing.
- `#a#b` matched `<p id=b>`, and `[title="\41"]` matched `title="41"`.
- `.a`, U+00A0, `b` was accepted and matched.
- On an invalid selector, `query/2` returned `[]` and `query!/2` raised.
  `[title="a` raised "unterminated string", `div /* c */ p` raised
  "unexpected character", and so did `li:first-child`.

Floki 0.38.4, the library whose result shapes PureHTML follows, raises
`FunctionClauseError` on `[href$=.pdf]`, matches `.1foo`, `p:first-child`,
and `[title="a`, and returns `[]` for `.a`, U+00A0, `b`.

The question is what defines a valid selector and what it matches.

## Decision

A selector is invalid when the texts make it invalid, or when it uses a
feature PureHTML does not support. Otherwise it is valid, and it matches
what Selectors 4 and the HTML standard's case-sensitivity rules say it
matches. Two exceptions:

- On the non-ASCII ident code points, the browser engines decide: any code
  point from U+0080 up is an ident code point.
- IDs and classes compare exactly in every document, quirks-mode
  documents included.

Within those rules:

- Where CSS Syntax 3 lets a user agent recover from a parse error or
  abort, PureHTML recovers. The end of the selector closes an open quoted
  value, attribute selector, or comment, and what it closed must still
  parse.
- On an invalid selector, `query/2` and `attribute/3` return `[]`,
  `query_one/2` returns `nil`, and `query!/2` and `query_one!/2` raise
  `ArgumentError`.
- An unsupported feature's error names it: pseudo-classes,
  pseudo-elements (`:before` among them), the column combinator, the `~=`
  and `|=` operators, attribute selector flags, and the `*|` and `|`
  namespace forms. PureHTML never drops the feature or matches part of the
  selector.
- A named namespace prefix, as in `svg|a`, is undeclared, and its error
  says so.
- The error names the fix for an unquoted value that is not an
  identifier, a name that starts with a digit or with a hyphen and a
  digit, and a colon in an attribute name: quote the value, escape the
  digit, or escape the colon.

## Rationale

Read on 14 October 2026: the texts above, Blink and WebKit on their main
branches, rust-cssparser 0.38.0, Firefox 158.0's `Cargo.lock`, #7129, and
both WPT files with their latest stable wpt.fyi results, which come from
wpt.fyi's own browser builds. Run once each on 14 October 2026: headless
Chrome 155.0.8059.41 and Floki 0.38.4 on the selectors in the table
below, and each earlier behavior at `v0.5.0`. Firefox and Safari were not
run on selectors.

**The texts give every case an answer that can be checked.** Each behavior
in the Decision was settled by reading the section that governs it, and is
pinned by a test through the public API. The rules of 0.5.0 had no
reference to check against, and their failures were silent: `[xlink:href]`
matched nothing on an SVG element without an error, and `#a#b` matched an
element whose ID is not `a`.

**The texts keep selectors portable.** For a query from the document, in a
no-quirks document and outside template contents, a selector that uses
only supported features is valid here exactly when it is valid in
`querySelectorAll`, and it matches the same elements. The rules of 0.5.0
broke this both ways: `[href$=.pdf]` worked here and is a `SyntaxError` in
a browser, and `[title="a` and `div /* c */ p`, which browsers accept,
raised in `query!/2`.

| Selector | Floki 0.38.4 | Chrome 155 | v0.5.0 | Now |
| --- | --- | --- | --- | --- |
| `[href$=.pdf]` | `FunctionClauseError` | `SyntaxError` | matches | invalid; the error says to quote |
| `.1foo` | matches | `SyntaxError` | matches | invalid; the error says to escape |
| `[title="a` | matches | matches | invalid | matches |
| `.a`, U+00A0, `b` | `[]` | matches | matches | matches |
| `p:first-child` | matches | matches | invalid | invalid; the error names pseudo-classes |

**Recovering at the end of the selector follows the browsers.** CSS
Syntax 3 allows either recovery or abort, and Chrome 155 and Floki 0.38.4
both match `[title="a`.

**On the non-ASCII ident code points, the engines decide, because a
selector that works in every browser should work here.** All three engines
accept any non-ASCII code point, and have not adopted the ranges since the
2022 resolution. The WPT test that queries U+00A0 passes in all three
browsers; the one written for the ranges never runs a rejection. The
editor has asked the group whether to drop the ranges. This departs from
treating the text as the definition and implementations as evidence, so it
is limited to this one rule.

**PureHTML's own reading rules.** They would break no selector that 0.5.0
accepted. They were ruled out by the silent wrong results above, and
because every new case would need a decision with no text to settle it.

**The texts, except where a change would break a selector that already
worked.** This would keep `[href$=.pdf]` and `.1foo` working. It was ruled
out because both are a `SyntaxError` in a browser, and the line between
what is kept and what changes would follow history instead of a text.

**The ranges CSS Syntax 3 lists.** They would reject `.a`, U+00A0, `b`,
which Chrome 155 and 0.5.0 match, and leave only the escaped `.a\a0 b`.
Unlike `.1foo`, which fails in browsers too, that selector would fail
here alone. They were ruled out because all three engines accept it
unescaped, and the WPT test that queries U+00A0 passes in each browser.

**Browser engines as the definition for every rule.** On the selectors in
the table, Chrome agrees with the text except on the ident code points, so
this would change nothing there. It was ruled out because only Chrome was
run, an engine's answer changes from release to release, and the text can
be read and cited.

**Aborting at the first parse error.** It would keep rejecting
`[title="a`, as 0.5.0 did. It was ruled out because Chrome and Floki both
recover, so aborting would reject selectors that work there.

**Recording the document mode in the tree.** It would apply the
quirks-mode rule, which needs the mode at match time. It was ruled out for
now because the result of `parse/2` is a list of nodes with no place for
document-level data, and a new result shape is a decision of its own.

**Deriving the document mode from the doctype node.** It would need no new
result shape. It was ruled out because the node does not keep the
force-quirks flag, a fragment takes its mode from its context document,
and a query on a subtree does not see the node.

**`query/2` raising on an invalid selector, as `querySelectorAll` does.**
It would make every newly invalid selector loud after an upgrade. It was
ruled out because the texts define both outcomes, matching nothing and
throwing, and PureHTML offers both: `query/2` matches nothing, and the bang
forms raise.

**A `lenient:` option that keeps the rules of 0.5.0.** It would let
callers keep `[href$=.pdf]`. It was ruled out because it keeps a second
grammar that no text defines, for selectors that each have a valid
spelling.

**A release that warns on the earlier forms, then rejects them.** It would
give callers a release to find them. It was ruled out because PureHTML is
at 0.5.0 and takes breaking changes without a deprecation release.

**One "unexpected character" error for every unsupported feature.** It
needs no list of features. It was ruled out because a user cannot tell from
it whether `p:first-child` is malformed or unsupported.

## Consequences

- Selectors 0.5.0 accepted are invalid: an unquoted value that is not an
  identifier; a class, ID, or type selector that starts with a digit, or
  with a hyphen and a digit; an unescaped newline in a quoted value; and a
  colon in an attribute name. For all but the newline, the error names the
  fix.
- An escaped colon, as in `[x-on\:click]`, reaches an HTML element's
  attribute. Nothing reaches a namespaced attribute on an SVG or MathML
  element, such as `{:xlink, "href"}`, until the `*|` form is supported.
- `#a#b` and `[title="\41"]` stay valid and change meaning without an
  error: the first matches nothing, the second matches `title="A"`.
- After an upgrade, `query/2`, `query_one/2`, and `attribute/3` return
  `[]` or `nil` for a newly invalid selector, with no error. Only the bang
  forms show the change.
- `[title="a` and `div /* c */ p` now match, where `query!/2` raised.
- A document parsed without a doctype is in quirks mode, so on such a
  document a browser matches `#A` to `id=a` and PureHTML does not.
- A query from a node matches that node and looks at no ancestor, while
  `querySelectorAll` matches only descendants and lets a selector reach
  ancestors. PureHTML also matches inside template contents, which a
  browser does not. Validity does not depend on either.
- `svg|a` and `[xlink|href]` stay invalid, since a query declares no
  namespace prefixes and DOM will not add them.
- A selector feature added later follows the same rules: its syntax and
  meaning come from the texts, an unsupported part of it stays invalid,
  and the error names it.
- Untested: Firefox and Safari on selectors, whose behavior is read from
  rust-cssparser 0.38.0, WebKit, and wpt.fyi; and Chrome beyond the
  selectors in the table.
- Reopens the identifier exception: Blink, WebKit, and rust-cssparser no
  longer agreeing, as when one ships the ranges. A resolution of #7129
  alone does not. Reopens the quirks-mode exception: a result shape that
  carries the document mode. Reopens the rest: a change to a cited text.
  The dates in Context are the versions this was checked against.

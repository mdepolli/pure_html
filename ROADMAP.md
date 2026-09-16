# Roadmap

Work deferred past the current release on purpose. Each entry says why it is a deferral rather than a gap, and what doing it entails, so it stays a task and not a wish. Items for the release in progress live in the changelog once done.

## Byte decoding

`PureHTML.parse/2` takes decoded text, and `PureHTML.Encoding.sniff/2` returns an encoding label the library cannot act on for its own default, windows-1252. Left out to focus on the parser.

Entails: documenting that `parse/2` wants text and showing sniff, decode, parse; a decoder the library owns for the encodings the sniffer resolves without a meta label (UTF-8, UTF-16 in both byte orders, windows-1252) with the Encoding Standard's U+FFFD replacement; and a byte-level entry point that chains the three, passing `transport_encoding` through. The rest of the Encoding Standard (Big5, GBK, Shift_JIS, EUC-JP, EUC-KR, ISO-2022-JP, the single-byte legacy set) is a separate decision; until then, unsupported labels stay explicit errors, never silent windows-1252.

## Lone surrogates in the input

Four html5lib tokenizer cases (`unicodeCharsProblematic:0` to `:3`) hold a lone surrogate in the input and expect a character token holding it. Strings here are UTF-8 binaries, which cannot encode a surrogate, so the cases are reported as skipped with the reason "deferred". The text notes such input never arises from bytes, only from script APIs such as `document.write()`.

Entails: a text representation for input and tree that admits lone surrogates (code point lists, or a WTF-8 style binary the serializer and query layer understand). A design decision, not an impossibility.

## Tree-construction fixtures from web-platform-tests

The tree-construction fixtures are pinned at html5lib-tests `9329e64`, the last commit before upstream moved them to web-platform-tests (`html/syntax/parsing/resources/`), where they are maintained in the same `.dat` format and already include `processing-instructions.dat`.

Entails: a second source in `test/fixtures/html5lib/UPSTREAM` and in `mix html5lib.sync`, fetched with a sparse partial clone since the WPT repository is large; then re-walking the corrections in `test/fixtures/corrections/tree-construction/` against the new files, dropping those upstream has since made.

## Send the error-count corrections upstream

Six tree-construction cases (`webkit02:44` to `:48`, `adoption02:2`) list error counts that contradict the living standard by hand walk, recorded in `test/fixtures/corrections/` with the walk in the project notes. They are candidates for web-platform-tests, so they stop being ours to carry.

Entails: a WPT pull request per disagreement with the walk as the justification; on merge, the correction drops off.

## Structured parse errors

`PureHTML.parse_with_errors/2` returns the number of parse errors. The living standard names every error, and the html5lib fixtures carry a code with a line and column for each, so the information exists at the point where the count is taken.

Entails: a position carried through the tokenizer and tree builder, an error list of `{code, line, column}` alongside the count, and the tokenizer runner asserting codes as well as counts.

## Selector pseudo-classes

`PureHTML.query/2` supports type, universal, class, id, and attribute selectors, selector lists, and the four combinators. Pseudo-classes are not parsed; a selector using one is invalid and matches nothing.

Entails: `:first-child`, `:last-child`, `:nth-child(n)`, and `:not(selector)` in the selector tokenizer and parser, sibling-position matching in the matcher, and the same invalid-selector rule for pseudo-classes still unsupported. Pseudo-elements do not apply to a static tree.

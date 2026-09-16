# html5lib fixtures

The `tree-construction`, `tokenizer`, `encoding`, and `serializer` directories are copied from [html5lib-tests](https://github.com/html5lib/html5lib-tests), each at the commit `UPSTREAM` pins for it, byte for byte, under the license in `LICENSE`. All are pinned at `9329e64`, the last upstream commit with the tree-construction fixtures; upstream deleted those on 2026-06-26 when they moved to web-platform-tests, so that directory can never move past its pin.

Never edit these files. `mix html5lib.sync` fetches upstream and lists every file that differs from it at the directory's pin; the list should be empty. `mix html5lib.sync <commit>` moves every directory the commit still has to that commit and replaces its files; a directory absent there keeps its pin and its files.

## Why corrections exist

Three commitments collide on a few cases:

- The parser follows the WHATWG living standard, not the fixtures.
- The runners assert everything a fixture states: tree, tokens, and error count, with no exceptions.
- The fixtures are frozen at a commit that contradicts the text in a few places, by hand walk of the algorithm.

For those cases the parser is right and the fixture is wrong, so the assertion fails as written. Skipping the case drops the assertion; waiving part of it hides a regression. The remaining choice is to assert what the text says, which needs the text's expectation recorded where the suite enforces it. That record is a correction: "the fixture is wrong here, this is the walk, this is what the text gives". Corrections should shrink, not grow: a case upstream fixes drops off, and a disagreement worth keeping is a candidate to send upstream.

## Corrections files

`test/fixtures/corrections/` mirrors this directory. A corrections file has the same name and format as the fixture it corrects and holds one block per corrected case:

- Tree-construction blocks (`.dat`) are keyed by `#data`. `#spec` cites the section anchors and the walk in `WALKS.md`; `#upstream-errors` (and `#upstream-document` when the tree changes) snapshot what upstream lists; `#errors` (and `#document`) give the text's expectation, one `text:` line per error.
- Tokenizer entries (`.json`, under `"corrections"`) are keyed by `description` and `input`. `spec` cites the walk in `WALKS.md`; `upstream` snapshots upstream's `output` and `errors`; `output` and `errors` give the text's tokens, with processing instructions as `["ProcessingInstruction", target, data]`.

The runners apply corrections when they parse a fixture. A block that matches no case, or more than one, or whose upstream snapshot no longer matches the fixture, raises with the case named: upstream moved, and the disagreement needs a fresh walk rather than blind reuse. `test/pure_html/html5lib_dat_parser_test.exs` pins that every corrections file names an existing fixture and that every block landed.

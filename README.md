# PureHTML

[![Hex.pm](https://img.shields.io/hexpm/v/pure_html.svg)](https://hex.pm/packages/pure_html)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/pure_html)

A pure Elixir HTML5 parser. No NIFs. No native dependencies. Just Elixir.

## Why PureHTML?

### Pure Elixir

PureHTML has **zero dependencies**. It's pure Elixir code all the way down.

- **Just install**: No C extensions or system libraries required. Works anywhere Elixir runs.
- **Debuggable**: Step through the parser with IEx to understand exactly how your HTML is being parsed.
- **Floki-compatible output**: Returns `{tag, attrs, children}` tuples with attributes as lists, matching [Floki](https://hex.pm/packages/floki)'s format.

### Correct

PureHTML implements the [WHATWG HTML5 specification](https://html.spec.whatwg.org/multipage/parsing.html). It handles all the complex error-recovery rules that browsers use.

- **Spec compliant**: Implements the full HTML5 tree construction algorithm including adoption agency, foster parenting, and foreign content (SVG/MathML).
- **100% html5lib compliance**: Passes all 8,602 tree-construction and tokenizer cases of the official [html5lib-tests](https://github.com/html5lib/html5lib-tests) suite used by browser vendors, the tree-construction cases in both scripting modes.
- **Parse errors**: `parse_with_errors/2` reports the number of parse errors the WHATWG tokenizer and tree builder define, so you can tell well-formed input from recovered input.

### Fast Enough

For raw speed, use a NIF-based parser. But for most use cases, PureHTML is fast enough while giving you the benefits of pure Elixir.

## Installation

Add `pure_html` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pure_html, "~> 0.4.0"}
  ]
end
```

## Quick Example

```elixir
# Parse HTML into a document tree
PureHTML.parse("<p class='intro'>Hello!</p>")
# => [{"html", [], [{"head", [], []}, {"body", [], [{"p", [{"class", "intro"}], ["Hello!"]}]}]}]

# Works with malformed HTML just like browsers do
PureHTML.parse("<p>One<p>Two")
# => [{"html", [], [{"head", [], []}, {"body", [], [{"p", [], ["One"]}, {"p", [], ["Two"]}]}]}]

# Convert back to HTML
PureHTML.parse("<p>Hello</p>") |> PureHTML.to_html()
# => "<html><head></head><body><p>Hello</p></body></html>"

# Count the parse errors the WHATWG rules report (here: no doctype)
PureHTML.parse_with_errors("<p>Hello</p>")
# => {[{"html", [], [{"head", [], []}, {"body", [], [{"p", [], ["Hello"]}]}]}], 1}

# Parse as if scripting were disabled (affects <noscript>)
PureHTML.parse("<noscript><p>Hi</p></noscript>", scripting: false)
```

## Querying

Find elements using CSS selectors.

```elixir
html = PureHTML.parse("<div><p class='intro'>Hello</p><p>World</p></div>")

# Find by tag
PureHTML.query(html, "p")
# => [{"p", [{"class", "intro"}], ["Hello"]}, {"p", [], ["World"]}]

# Find by class
PureHTML.query(html, ".intro")
# => [{"p", [{"class", "intro"}], ["Hello"]}]

# Compound selectors
PureHTML.query(html, "p.intro")
# => [{"p", [{"class", "intro"}], ["Hello"]}]

# Combinators
PureHTML.query(html, "div > p")      # Direct children
PureHTML.query(html, "div p")        # All descendants

# Extract text content
PureHTML.text(html)
# => "HelloWorld"

# Extract attributes
PureHTML.attribute(html, "p", "class")
# => ["intro"]
```

Supported selectors: `tag`, `*`, `.class`, `#id`, `[attr]`, `[attr=val]`, `[attr^=prefix]`, `[attr$=suffix]`, `[attr*=substring]`, selector lists (`.a, .b`), combinators (`div p`, `div > p`, `h1 + p`, `h1 ~ p`).

See the [Querying Guide](guides/querying.md) for complete documentation.

## Development

The test suite runs the [html5lib-tests](https://github.com/html5lib/html5lib-tests) fixtures, vendored byte for byte under `test/fixtures/html5lib/` at the commits pinned in its `UPSTREAM` file. Cases that contradict the WHATWG living standard are corrected from `test/fixtures/corrections/`, never by editing the fixtures; `test/fixtures/html5lib/README.md` explains why and how.

```bash
mix test                      # the suite, html5lib fixtures included
mix html5lib.sync             # check the vendored fixtures against upstream; fails on any difference
mix html5lib.sync <commit>    # move the pins to an upstream commit
```

The sync task keeps a clone of upstream under `_build`. Pins are per directory: a move updates each directory the target commit still has and leaves the others at their current pin. Upstream deleted the tree-construction fixtures after `9329e64`, so that directory stays at `9329e64` whatever commit the rest moves to.

## Roadmap

Work deferred past the current release, with what each item entails, is in [ROADMAP.md](ROADMAP.md).

## License

Copyright 2026 (c) Marcelo De Polli.

PureHTML source code is released under MIT License.

Check [LICENSE](https://github.com/mdepolli/pure_html/blob/master/LICENSE) file for more information.

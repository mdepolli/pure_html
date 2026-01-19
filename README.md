# PureHTML

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
- **100% html5lib compliance**: Passes all 8,634 tests from the official [html5lib-tests](https://github.com/html5lib/html5lib-tests) suite used by browser vendors.

### Fast Enough

For raw speed, use a NIF-based parser. But for most use cases, PureHTML is fast enough while giving you the benefits of pure Elixir.

## Installation

Add `pure_html` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pure_html, "~> 0.1.0"}
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

# Attribute selectors
html = PureHTML.parse("<a href='https://example.com'>Link</a>")
PureHTML.query(html, "[href^=https]")
# => [{"a", [{"href", "https://example.com"}], ["Link"]}]
```

Supported: `tag`, `*`, `.class`, `#id`, `[attr]`, `[attr=val]`, `[attr^=prefix]`, `[attr$=suffix]`, `[attr*=substring]`, selector lists (`.a, .b`).

See the [Querying Guide](guides/querying.md) for complete documentation.

## License

Copyright 2026 (c) Marcelo De Polli.

PureHTML source code is released under MIT License.

Check [LICENSE](https://github.com/mdepolli/pure_html/blob/master/LICENSE) file for more information.

# PureHTML

A pure Elixir HTML5 parser. No NIFs. No native dependencies. Just Elixir.

## Why PureHTML?

### Pure Elixir

PureHTML has **zero dependencies**. It's pure Elixir code all the way down.

- **Just install**: No C extensions or system libraries required. Works anywhere Elixir runs.
- **Debuggable**: Step through the parser with IEx to understand exactly how your HTML is being parsed.
- **Familiar output**: Returns `{tag, attrs, children}` tuples similar to other Elixir HTML libraries.

### Correct

PureHTML implements the [WHATWG HTML5 specification](https://html.spec.whatwg.org/multipage/parsing.html). It handles all the complex error-recovery rules that browsers use.

- **Spec compliant**: Implements the full HTML5 tree construction algorithm including adoption agency, foster parenting, and foreign content (SVG/MathML).
- **Tested against html5lib**: Validated against the official [html5lib-tests](https://github.com/html5lib/html5lib-tests) suite used by browser vendors.

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
# => {nil, [{"html", %{}, [{"head", %{}, []}, {"body", %{}, [{"p", %{"class" => "intro"}, ["Hello!"]}]}]}]}

# Works with malformed HTML just like browsers do
PureHTML.parse("<p>One<p>Two")
# => {nil, [{"html", %{}, [{"head", %{}, []}, {"body", %{}, [{"p", %{}, ["One"]}, {"p", %{}, ["Two"]}]}]}]}
```

## License

Copyright 2026 (c) Marcelo De Polli.

PureHTML source code is released under MIT License.

Check [LICENSE](https://github.com/mdepolli/pure_html/blob/master/LICENSE) file for more information.

# Querying HTML

PureHTML provides a CSS selector-based querying API for finding and traversing HTML nodes. The API is designed to be familiar to users of [Floki](https://hex.pm/packages/floki).

## Basic Usage

```elixir
# Parse HTML and query for elements
html = PureHTML.parse("""
<div class="container">
  <h1 id="title">Welcome</h1>
  <p class="intro">Hello, world!</p>
  <p>Another paragraph</p>
</div>
""")

# Find all paragraphs
PureHTML.query(html, "p")
#=> [{"p", [{"class", "intro"}], ["Hello, world!"]}, {"p", [], ["Another paragraph"]}]

# Find by class
PureHTML.query(html, ".intro")
#=> [{"p", [{"class", "intro"}], ["Hello, world!"]}]

# Find by ID
PureHTML.query(html, "#title")
#=> [{"h1", [{"id", "title"}], ["Welcome"]}]
```

## Supported Selectors

### Tag Selector

Match elements by tag name.

```elixir
PureHTML.query(html, "div")      # All <div> elements
PureHTML.query(html, "p")        # All <p> elements
PureHTML.query(html, "a")        # All <a> elements
```

### Universal Selector

Match all elements.

```elixir
PureHTML.query(html, "*")        # All elements
```

### Class Selector

Match elements by class name. Multiple classes can be specified.

```elixir
PureHTML.query(html, ".intro")           # Elements with class "intro"
PureHTML.query(html, ".btn.primary")     # Elements with both "btn" AND "primary" classes
```

### ID Selector

Match elements by ID.

```elixir
PureHTML.query(html, "#title")           # Element with id="title"
PureHTML.query(html, "#nav")             # Element with id="nav"
```

### Attribute Selectors

Match elements by attribute presence or value.

```elixir
# Attribute existence
PureHTML.query(html, "[href]")           # Elements with href attribute

# Exact match
PureHTML.query(html, "[type=text]")      # Elements where type="text"
PureHTML.query(html, "[type='text']")    # Same, with quotes

# Prefix match (^=)
PureHTML.query(html, "[href^=https]")    # href starts with "https"

# Suffix match ($=)
PureHTML.query(html, "[href$=.pdf]")     # href ends with ".pdf"

# Substring match (*=)
PureHTML.query(html, "[href*=example]")  # href contains "example"
```

### Compound Selectors

Combine multiple selectors to match elements that satisfy all conditions.

```elixir
PureHTML.query(html, "p.intro")          # <p> elements with class "intro"
PureHTML.query(html, "input#email")      # <input> with id="email"
PureHTML.query(html, "a.btn.primary")    # <a> with both classes
PureHTML.query(html, "input[type=text]") # <input> with type="text"
PureHTML.query(html, "a.external[href^=https]")  # <a> with class and attribute
```

### Selector Lists

Match elements that satisfy any of the selectors (OR logic).

```elixir
PureHTML.query(html, "h1, h2, h3")       # All h1, h2, or h3 elements
PureHTML.query(html, ".error, .warning") # Elements with either class
PureHTML.query(html, "input, textarea")  # All input or textarea elements
```

## Traversing Children

Use `children/2` to get the immediate children of an element.

```elixir
html = PureHTML.parse("<ul><li>One</li><li>Two</li></ul>")
[ul] = PureHTML.query(html, "ul")

PureHTML.children(ul)
#=> [{"li", [], ["One"]}, {"li", [], ["Two"]}]
```

### Filtering Text Nodes

By default, `children/2` includes text nodes. Use `include_text: false` to exclude them.

```elixir
html = PureHTML.parse("<div><p>Hello</p> Some text <span>World</span></div>")
[div] = PureHTML.query(html, "div")

# Include text nodes (default)
PureHTML.children(div)
#=> [{"p", [], ["Hello"]}, " Some text ", {"span", [], ["World"]}]

# Exclude text nodes
PureHTML.children(div, include_text: false)
#=> [{"p", [], ["Hello"]}, {"span", [], ["World"]}]
```

### Non-Element Nodes

`children/2` returns `nil` for non-element nodes like text or comments.

```elixir
PureHTML.children("text node")           #=> nil
PureHTML.children({:comment, "comment"}) #=> nil
```

## Working with Results

Query results are lists of nodes in the same format as `PureHTML.parse/1` output.

### Chaining Queries

You can query within query results.

```elixir
html = PureHTML.parse("""
<div class="sidebar">
  <a href="/home">Home</a>
</div>
<div class="content">
  <a href="/about">About</a>
  <a href="/contact">Contact</a>
</div>
""")

# Find links only within .content
[content] = PureHTML.query(html, ".content")
PureHTML.query(content, "a")
#=> [{"a", [{"href", "/about"}], ["About"]}, {"a", [{"href", "/contact"}], ["Contact"]}]
```

### Extracting Data

Common patterns for extracting data from query results.

```elixir
html = PureHTML.parse("""
<ul>
  <li><a href="/one">One</a></li>
  <li><a href="/two">Two</a></li>
</ul>
""")

# Get all link hrefs
html
|> PureHTML.query("a")
|> Enum.map(fn {_, attrs, _} ->
  List.keyfind(attrs, "href", 0) |> elem(1)
end)
#=> ["/one", "/two"]

# Get all link texts
html
|> PureHTML.query("a")
|> Enum.map(fn {_, _, [text]} -> text end)
#=> ["One", "Two"]
```

### Converting Back to HTML

Use `to_html/1` to convert query results back to HTML strings.

```elixir
html = PureHTML.parse("<div><p class='keep'>Keep</p><p>Remove</p></div>")

html
|> PureHTML.query(".keep")
|> PureHTML.to_html()
#=> "<p class=keep>Keep</p>"
```

## Selectors Not Yet Supported

The following CSS selectors are planned for future versions:

- **Combinators**: `div p` (descendant), `div > p` (child), `h1 + p` (adjacent sibling), `h1 ~ p` (general sibling)
- **Pseudo-classes**: `:first-child`, `:last-child`, `:nth-child(n)`, `:not(selector)`
- **Pseudo-elements**: `::before`, `::after` (not applicable to static HTML)

## API Reference

### `PureHTML.query/2`

```elixir
@spec query(html_tree | html_node, String.t()) :: [html_node]
```

Finds all nodes matching the CSS selector. Returns an empty list if no matches.

### `PureHTML.children/2`

```elixir
@spec children(html_node, keyword()) :: [html_node] | nil
```

Returns the immediate children of a node. Options:

- `:include_text` - Include text nodes (default: `true`)

Returns `nil` for non-element nodes.

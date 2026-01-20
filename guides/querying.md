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

### Combinators

Combinators express relationships between elements.

```elixir
html = PureHTML.parse("""
<article>
  <section>
    <h2>Title</h2>
    <p class="intro">First paragraph</p>
    <p>Second paragraph</p>
  </section>
</article>
""")

# Descendant combinator (space) - matches anywhere inside
PureHTML.query(html, "article p")
#=> [{"p", [{"class", "intro"}], ["First paragraph"]}, {"p", [], ["Second paragraph"]}]

# Child combinator (>) - matches direct children only
PureHTML.query(html, "article > p")
#=> []  # No <p> directly inside <article>

PureHTML.query(html, "section > p")
#=> [{"p", [{"class", "intro"}], ["First paragraph"]}, {"p", [], ["Second paragraph"]}]

# Adjacent sibling (+) - matches the next sibling
PureHTML.query(html, "h2 + p")
#=> [{"p", [{"class", "intro"}], ["First paragraph"]}]

# General sibling (~) - matches any following sibling
PureHTML.query(html, "h2 ~ p")
#=> [{"p", [{"class", "intro"}], ["First paragraph"]}, {"p", [], ["Second paragraph"]}]
```

Combinators can be chained:

```elixir
# Find links inside list items inside nav
PureHTML.query(html, "nav ul li a")

# Find paragraphs that are direct children of articles
PureHTML.query(html, "article > section > p")

# Mix combinators as needed
PureHTML.query(html, "article section > h2 + p")
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

## Extracting Text

Use `text/2` to extract text content from nodes.

```elixir
html = PureHTML.parse("<p>Hello <strong>World</strong>!</p>")

# Extract all text (deep by default)
PureHTML.text(html)
#=> "Hello World!"

# With a separator between text segments
PureHTML.text(html, separator: " ")
#=> "Hello World !"
```

### Text Options

```elixir
html = PureHTML.parse("""
<div>
  <p>  Paragraph one  </p>
  <p>  Paragraph two  </p>
</div>
""")

# Strip whitespace and remove empty segments
PureHTML.text(html, strip: true, separator: ", ")
#=> "Paragraph one, Paragraph two"

# Shallow extraction (direct text children only)
html = PureHTML.parse("<div>Direct <span>nested</span> text</div>")
[div] = PureHTML.query(html, "div")
PureHTML.text(div, deep: false)
#=> "Direct  text"
```

### Script and Style Content

By default, `<script>` and `<style>` content is excluded:

```elixir
html = PureHTML.parse("<div>Hello<script>alert('x')</script></div>")
PureHTML.text(html)
#=> "Hello"

# Include script content
PureHTML.text(html, include_script: true)
#=> "Helloalert('x')"
```

### Form Input Values

Extract values from form inputs:

```elixir
html = PureHTML.parse("<input type='text' value='Hello'>")
PureHTML.text(html, include_inputs: true)
#=> "Hello"
```

## Extracting Attributes

### Single Node

Use `attr/2` to get an attribute from a single node:

```elixir
html = PureHTML.parse("<a href='/home' class='nav-link'>Home</a>")
[link] = PureHTML.query(html, "a")

PureHTML.attr(link, "href")
#=> "/home"

PureHTML.attr(link, "title")
#=> nil
```

### Multiple Nodes

Use `attribute/2` to extract an attribute from a list of nodes:

```elixir
html = PureHTML.parse("""
<nav>
  <a href="/home">Home</a>
  <a href="/about">About</a>
  <a href="/contact">Contact</a>
</nav>
""")

html
|> PureHTML.query("a")
|> PureHTML.attribute("href")
#=> ["/home", "/about", "/contact"]
```

### Query and Extract

Use `attribute/3` to query and extract in one step:

```elixir
html
|> PureHTML.attribute("a", "href")
#=> ["/home", "/about", "/contact"]

# Equivalent to:
html
|> PureHTML.query("a")
|> PureHTML.attribute("href")
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

- **Pseudo-classes**: `:first-child`, `:last-child`, `:nth-child(n)`, `:not(selector)`
- **Pseudo-elements**: `::before`, `::after` (not applicable to static HTML)

## API Reference

### `PureHTML.query/2`

```elixir
@spec query(html_tree | html_node, String.t()) :: [html_node]
```

Finds all nodes matching the CSS selector. Returns an empty list if no matches.

### `PureHTML.query_one/2`

```elixir
@spec query_one(html_tree | html_node, String.t()) :: html_node | nil
```

Finds the first node matching the CSS selector. Returns `nil` if no match.

### `PureHTML.text/2`

```elixir
@spec text(html_tree | html_node, keyword()) :: String.t()
```

Extracts text content from an HTML tree or node. Options:

- `:deep` - Traverse all descendants (default: `true`)
- `:separator` - String between text segments (default: `""`)
- `:strip` - Strip whitespace from segments, remove empty (default: `false`)
- `:include_script` - Include `<script>` content (default: `false`)
- `:include_style` - Include `<style>` content (default: `false`)
- `:include_inputs` - Include `<input>` and `<textarea>` values (default: `false`)

### `PureHTML.attr/2`

```elixir
@spec attr(html_node, String.t()) :: String.t() | nil
```

Gets an attribute value from a single node. Returns `nil` if not found.

### `PureHTML.attribute/2`

```elixir
@spec attribute(html_tree | html_node, String.t()) :: [String.t()]
```

Extracts an attribute from a list of nodes. Skips nodes without the attribute.

### `PureHTML.attribute/3`

```elixir
@spec attribute(html_tree | html_node, String.t(), String.t()) :: [String.t()]
```

Finds elements matching a selector and extracts an attribute. Combines `query/2` and `attribute/2`.

### `PureHTML.children/2`

```elixir
@spec children(html_node, keyword()) :: [html_node] | nil
```

Returns the immediate children of a node. Options:

- `:include_text` - Include text nodes (default: `true`)

Returns `nil` for non-element nodes.

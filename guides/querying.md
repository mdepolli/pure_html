# Querying HTML

PureHTML provides a CSS selector-based querying API for finding and traversing HTML nodes. Its functions are shaped like [Floki](https://hex.pm/packages/floki)'s, and its selectors follow the CSS Syntax and Selectors specifications.

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
PureHTML.query(html, ~s([href$=".pdf"])) # href ends with ".pdf"

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

### Selector Syntax

An unquoted attribute value must be a CSS identifier: it cannot start with a digit, or with a hyphen and a digit, and it cannot hold punctuation such as `.`, `/`, or `:`. Quote any other value. `[href$=.pdf]` is an invalid selector, and the error says to quote it. An empty value after `^=`, `$=`, or `*=` matches nothing, while `[href=""]` matches an empty attribute.

Any non-ASCII character can appear unescaped in a class, an ID, or another identifier, as in browsers. A class or ID that starts with a digit, or holds punctuation, needs an escape, and so does a colon in an attribute name. A backslash and one to six hex digits name a code point, and one whitespace character after them ends the escape. A backslash before any other character makes it literal, except before a newline, where it ends an identifier, and inside a quoted value joins the two lines.

```elixir
PureHTML.query(html, ~S(.md\:flex))      # class="md:flex"
PureHTML.query(html, ~S([x-on\:click]))  # the x-on:click attribute
PureHTML.query(html, ~S(#\31 0))         # id="10"
PureHTML.query(html, ~s([id="10"]))      # the same element
```

Comments (`/* ... */`) are allowed and are not whitespace, so `div /* c */ p` is a descendant selector and `div/**/p` is invalid. A quoted value or an attribute selector left open at the end of the selector is closed there, as CSS does: `[title="a` means `[title="a"]`.

### Case Sensitivity

Matching follows the HTML standard's [case-sensitivity of selectors](https://html.spec.whatwg.org/multipage/semantics-other.html#case-sensitivity-of-selectors):

- A type selector and an attribute name are ASCII lowercased before they are compared to an HTML element, so `DIV` matches `<div>` and `[HREF]` matches `href`. On SVG and MathML elements they keep their case: `foreignObject` matches, `foreignobject` does not.
- Attribute values are case-sensitive, except for the attributes the standard lists, such as `type`, on HTML elements: `[type=text]` matches `type="TEXT"`.
- IDs and classes are always compared exactly. A browser folds their case in a quirks-mode document, such as one with no doctype; supporting that is on the [roadmap](../ROADMAP.md).

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

### Template Contents

A `<template>` element's contents sit in a `{:content, nodes}` wrapper, its only child. `children/2` returns the wrapper, the query functions search inside it as if the nodes were the template's children, and `text/2` skips it.

```elixir
html = PureHTML.parse("<template><p>x</p></template>")
[template] = PureHTML.query(html, "template")

PureHTML.children(template)
#=> [{:content, [{"p", [], ["x"]}]}]

PureHTML.query(html, "template > p")
#=> [{"p", [], ["x"]}]

PureHTML.text(html)
#=> ""
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

A query searches the nodes it is given and their descendants, and sees nothing outside them:

- The given nodes can match themselves: `PureHTML.query(content, "div")` returns `[content]`.
- Combinators cannot reach their ancestors: `PureHTML.query(content, "body a")` returns `[]`.
- A list of nodes is searched as siblings, in order, so `div + div` can match two results that were never siblings in the document.
- A node inside two of the given nodes is found once for each. Querying `"p"` in the results of `"div"` on `<div><div><p>x</p></div></div>` returns the `p` twice.

## Extracting Text

Use `text/2` to extract text content from nodes.

```elixir
html = PureHTML.parse("<p>Hello <strong>World</strong>!</p>")

# Extract all text (deep by default)
PureHTML.text(html)
#=> "Hello World!"

# With a separator between text segments; each segment keeps its own whitespace
PureHTML.text(html, separator: " ")
#=> "Hello  World !"
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
#=> "<p class=\"keep\">Keep</p>"
```

## Unsupported Selectors

These are on the [roadmap](../ROADMAP.md). A selector using one is invalid today: `query/2` matches nothing, and `query!/2` raises with an error that names the feature.

- Pseudo-classes such as `:first-child`, `:last-child`, `:nth-child(n)`, and `:not(selector)`.
- The `~=` and `|=` attribute operators, and the `i` and `s` case flags.
- The any-namespace and no-namespace forms (`*|a`, `[*|href]`, `[|href]`). Without them, a namespaced attribute on an SVG or MathML element, such as `xlink:href`, cannot be selected.

These are invalid too, and are not planned:

- The column combinator (`||`). Its error names it.
- Pseudo-elements (`::before`, and the older `:before`), which do not apply to a static tree. Their error names them.
- A named namespace prefix, as in `svg|a` or `[xlink|href]`. A query declares no namespace prefixes, so the error says the prefix is undeclared.

## API Reference

### `PureHTML.query/2`

```elixir
@spec query(html_tree | html_node, String.t()) :: [html_node]
```

Finds all nodes matching the CSS selector, in document order. Returns an empty list if no matches. An invalid selector represents, and therefore matches, nothing, so it also returns an empty list; `PureHTML.query!/2` raises `ArgumentError` instead.

### `PureHTML.query_one/2`

```elixir
@spec query_one(html_tree | html_node, String.t()) :: html_node | nil
```

Finds the first node matching the CSS selector, in document order, and stops there. Returns `nil` if no match, and `nil` for an invalid selector; `PureHTML.query_one!/2` raises `ArgumentError` instead.

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

# Fragment Parsing Support

## Goal

Implement the WHATWG HTML5 fragment parsing algorithm to pass all 192 html5lib
fragment tree construction tests. This is the algorithm browsers use for
`innerHTML`.

## API

Single option on existing `parse/1`:

```elixir
PureHTML.parse("<p>Hello</p>", context: "body")
# → [{"p", [], ["Hello"]}]

PureHTML.parse("<font color></font>X", context: "svg path")
# → [{"font", [{"color", ""}], []}, "X"]
```

The `context` string matches the html5lib test format: `"div"`, `"body"`,
`"svg path"`, `"math mtext"`, etc.

Return value is the children of the `html` element (no `<html>/<head>/<body>`
wrappers).

## Implementation Steps

### Step 1: Move `reset_insertion_mode` to Helpers

The existing `reset_insertion_mode/1` and `determine_mode_from_stack/2` are
private in `in_body.ex`. Fragment setup needs to call the same logic to
determine the initial insertion mode from the context element.

Move these functions to `PureHTML.TreeBuilder.Helpers` and make them
accessible. Update `in_body.ex` to call the moved functions.

### Step 2: Add context element to State

Add a `context_element` field to `PureHTML.TreeBuilder.State`:

```elixir
# Fragment parsing context element - {namespace, tag} or nil
context_element: nil
```

Update `reset_insertion_mode` to consult `context_element` when it reaches the
bottom of the stack (the "if last is true, set node to the context element"
step from the spec).

### Step 3: Implement `build_fragment/3` in TreeBuilder

New public function that implements the spec's fragment parsing algorithm:

1. **Determine tokenizer state** — already handled by caller via
   `Tokenizer.new/2` options.

2. **Create html element, push onto stack** — Manually create an `html`
   element with `make_ref()`, add to elements map, push ref onto stack.

3. **Handle template context** — If context tag is `"template"`, push
   `:in_template` onto the template mode stack.

4. **Store context** — Set `state.context_element` to `{namespace, tag}`.

5. **Reset insertion mode** — Call the moved `reset_insertion_mode` to
   determine initial mode from context element.

6. **Run `build_loop`** — Reuse existing token processing loop.

7. **Finalize** — Return children of the `html` element (not the full
   document structure). Skip `ensure_head`, `ensure_body`,
   `populate_selectedcontent`, doctype handling, and pre/post html comments.

### Step 4: Update `parse/1` in PureHTML

Add context option handling:

```elixir
def parse(html, opts \\ []) when is_binary(html) do
  case Keyword.get(opts, :context) do
    nil ->
      html |> Tokenizer.new() |> TreeBuilder.build()

    context ->
      {ns, tag} = parse_context(context)
      tokenizer_opts = fragment_tokenizer_opts(tag)
      html |> Tokenizer.new(tokenizer_opts) |> TreeBuilder.build_fragment(ns, tag)
  end
end
```

Context parsing: `"svg path"` → `{:svg, "path"}`, `"div"` → `{nil, "div"}`.

Tokenizer initial state mapping:
- `title`, `textarea` → `:rcdata`
- `style`, `xmp`, `iframe`, `noembed`, `noframes` → `:rawtext`
- `script` → `:script_data`
- `noscript` (scripting enabled) → `:rawtext`
- `plaintext` → `:plaintext`
- everything else → `:data`

### Step 5: Update tree construction tests

Remove the `document_fragment == nil` filter. For fragment tests, pass the
context to `PureHTML.parse/2` and compare against the expected tree output
(which in fragment tests has no `<html>` wrapper — children are at depth 0).

### Step 6: Update serializer in test support

The test support `serialize_document/1` currently expects a full document. For
fragment results (a flat list of children), it should serialize each node at
depth 0 — which it already does since it maps over the list. Verify this works
and adjust if needed.

## Files Changed

- `lib/pure_html.ex` — `parse/2`, context parsing, tokenizer state mapping
- `lib/pure_html/tree_builder.ex` — `build_fragment/3`, fragment finalization
- `lib/pure_html/tree_builder/helpers.ex` — receive `reset_insertion_mode`
- `lib/pure_html/tree_builder/modes/in_body.ex` — delegate to helpers
- `lib/pure_html/tree_builder.ex` (State) — `context_element` field
- `test/pure_html/html5lib_tree_construction_test.exs` — enable fragment tests

## Not In Scope

- `form_element` pointer from ancestor walk (no ancestors in our API — context
  is always a bare element name, not a DOM node with parents)
- New public functions — just an option on `parse/1`
- Script-off tests — remain filtered out (separate concern)

# Scripting Flag Support

## Goal

Support the WHATWG scripting flag as a user-facing option, enabling dual-mode
test coverage per the html5lib test README.

## Public API

Add a `scripting:` option to `PureHTML.parse/2`. Default: `true` (enabled).

```elixir
PureHTML.parse(html)                      # scripting enabled (default)
PureHTML.parse(html, scripting: false)     # scripting disabled
PureHTML.parse(html, context: "noscript", scripting: false)  # fragment + disabled
```

## Parser Changes

Thread the `scripting` boolean from `PureHTML.parse/2` through the tokenizer
and tree builder. Use pattern matching on `%{scripting: true/false}` in
function heads wherever the behavior diverges.

### Where scripting affects behavior

**1. `in_head.ex` — `<noscript>` start tag**

Remove `"noscript"` from `@raw_text_elements`. Add two clauses:

- `%{scripting: true}`: push element, switch to text mode (RAWTEXT)
- `%{scripting: false}`: push element, switch to `in_head_noscript` mode

**2. `in_body.ex` — `<noscript>` start tag**

Remove `"noscript"` from `@head_elements`. Add two clauses:

- `%{scripting: true}`: process using "in head" rules (RAWTEXT)
- `%{scripting: false}`: reconstruct active formatting, push element (content
  parsed as HTML)

**3. `helpers.ex` — `determine_mode_from_stack`**

The "reset insertion mode" algorithm says: if the node is `noscript` and
scripting is enabled, return `:in_head`. This requires passing the scripting
flag through. Two options:

- Add `scripting` as an additional parameter
- Pattern match on a `noscript`-specific clause before the general map lookup

**4. `pure_html.ex` — fragment tokenizer opts for `noscript`**

- Scripting enabled: use RAWTEXT initial state
- Scripting disabled: use data state (default, no special opts)

**5. `tree_builder.ex` — `build/2` and `build_fragment/4`**

Accept a `scripting` parameter and set it on `State`.

## Test Changes

**Dual-mode generation:** Tests without `#script-off` or `#script-on` produce
two ExUnit tests — one with `scripting: true`, one with `scripting: false`.

**`#script-off` tests:** No longer skipped. Run with `scripting: false`.

**`#script-on` tests:** Run with `scripting: true`.

**Tags:** Each test tagged `scripting: :on` or `scripting: :off` for filtering:
```bash
mix test test/pure_html/html5lib_tree_construction_test.exs --only scripting:on
mix test test/pure_html/html5lib_tree_construction_test.exs --only scripting:off
```

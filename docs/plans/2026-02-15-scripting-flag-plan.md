# Scripting Flag Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `scripting:` option to `PureHTML.parse/2` and run html5lib tests in both scripting modes.

**Architecture:** Thread a boolean through `parse/2` → `TreeBuilder.build/2` / `build_fragment/5` → `State.scripting`. Use pattern matching on `%{scripting: true/false}` in function heads where behavior diverges (`in_head.ex`, `in_body.ex`, `helpers.ex`). Dual-mode test generation for unmarked tests.

**Tech Stack:** Elixir, ExUnit, html5lib tree construction tests

**Design doc:** `docs/plans/2026-02-15-scripting-flag-design.md`

---

### Task 1: Thread scripting flag through public API and tree builder

**Files:**
- Modify: `lib/pure_html.ex:59-72`
- Modify: `lib/pure_html/tree_builder.ex:239-242, 265-266`

**Step 1: Modify `PureHTML.parse/2` to read `scripting:` option and pass it through**

In `lib/pure_html.ex`, update `parse/2` to extract the scripting flag and pass
it to the tree builder:

```elixir
def parse(html, opts \\ []) when is_binary(html) do
  scripting = Keyword.get(opts, :scripting, true)

  case Keyword.get(opts, :context) do
    nil ->
      html
      |> Tokenizer.new()
      |> TreeBuilder.build(scripting)

    context ->
      {ns, tag} = parse_context(context)

      html
      |> Tokenizer.new(fragment_tokenizer_opts(ns, tag, scripting))
      |> TreeBuilder.build_fragment(ns, tag, scripting)
  end
end
```

Also update `fragment_tokenizer_opts` to accept and use the scripting flag:

```elixir
defp fragment_tokenizer_opts(ns, _tag, _scripting) when ns in [:svg, :math], do: []

defp fragment_tokenizer_opts(_ns, tag, _scripting) when tag in @rcdata_elements do
  [initial_state: :rcdata]
end

defp fragment_tokenizer_opts(_ns, "script", _scripting) do
  [initial_state: :script_data]
end

defp fragment_tokenizer_opts(_ns, "plaintext", _scripting) do
  [initial_state: :plaintext]
end

defp fragment_tokenizer_opts(_ns, "noscript", true = _scripting) do
  [initial_state: :rawtext]
end

defp fragment_tokenizer_opts(_ns, tag, _scripting) when tag in @raw_text_elements do
  [initial_state: :rawtext]
end

defp fragment_tokenizer_opts(_ns, _tag, _scripting), do: []
```

Remove `"noscript"` from `@raw_text_elements` (line 272) since it now has its
own clause:

```elixir
@raw_text_elements ~w(style xmp iframe noembed noframes)
```

**Step 2: Update `TreeBuilder.build/1` → `build/2`**

In `lib/pure_html/tree_builder.ex`, add a `scripting` parameter:

```elixir
@spec build(Tokenizer.t(), boolean()) :: [document_node()]
def build(%Tokenizer{} = tokenizer, scripting \\ true) do
  {doctype, state, pre_html_comments} =
    build_loop(tokenizer, {nil, %State{scripting: scripting}, []})
  # ... rest unchanged
end
```

**Step 3: Update `TreeBuilder.build_fragment/3` → `build_fragment/4`**

Add `scripting` parameter, set it on state:

```elixir
@spec build_fragment(Tokenizer.t(), atom() | nil, String.t(), boolean()) :: [document_node()]
def build_fragment(%Tokenizer{} = tokenizer, namespace, tag, scripting \\ true) do
  # ... existing code ...
  state = %State{
    stack: stack,
    elements: elements,
    current_parent_ref: html_ref,
    context_element: context,
    template_mode_stack: template_mode_stack,
    scripting: scripting
  }
  # ... rest unchanged
end
```

**Step 4: Compile and run existing tests**

Run: `mix compile --warnings-as-errors && mix test test/pure_html/html5lib_tree_construction_test.exs`

Expected: All 1668 tests pass (no behavior change yet — default is `true`).

**Step 5: Commit**

```
feat: thread scripting flag through parse API and tree builder
```

---

### Task 2: Handle `<noscript>` in `in_head.ex` based on scripting flag

**Files:**
- Modify: `lib/pure_html/tree_builder/modes/in_head.ex:41, 93-97`

**Step 1: Remove "noscript" from `@raw_text_elements` and add two clauses**

In `lib/pure_html/tree_builder/modes/in_head.ex`:

Change line 41:
```elixir
@raw_text_elements ~w(noframes style)
```

Add two new clauses **before** the `@raw_text_elements` clause (line 93):

```elixir
# <noscript> with scripting enabled: treat as RAWTEXT (content is raw text)
def process({:start_tag, "noscript", attrs, _self_closing}, %{scripting: true} = state) do
  {:ok, switch_to_text_mode(state, "noscript", attrs)}
end

# <noscript> with scripting disabled: push element, enter in_head_noscript mode
def process({:start_tag, "noscript", attrs, _self_closing}, state) do
  state =
    state
    |> push_element("noscript", attrs)
    |> Map.put(:mode, :in_head_noscript)

  {:ok, state}
end
```

**Step 2: Compile and run existing tests**

Run: `mix compile --warnings-as-errors && mix test test/pure_html/html5lib_tree_construction_test.exs`

Expected: All 1668 tests pass (existing tests all use scripting enabled).

**Step 3: Commit**

```
feat: handle noscript in in_head based on scripting flag
```

---

### Task 3: Handle `<noscript>` in `in_body.ex` based on scripting flag

**Files:**
- Modify: `lib/pure_html/tree_builder/modes/in_body.ex:51, 491-503, 515-525`

**Step 1: Remove "noscript" from `@head_elements`**

Change line 51:
```elixir
@head_elements ~w(base basefont bgsound link meta noframes script style template title)
```

**Step 2: Add noscript clause to `do_process_html_start_tag`**

Add a new clause **before** the existing `@head_elements` clauses (before
line 491). When scripting is enabled, noscript uses the head-element path.
When disabled, it reconstructs AF and pushes the element normally:

```elixir
# <noscript> with scripting enabled: process using "in head" rules (RAWTEXT)
defp do_process_html_start_tag("noscript", attrs, self_closing, %{scripting: true, mode: mode} = state)
     when mode in [:in_template, :in_body, :in_table, :in_select, :in_select_in_table] do
  if find_ref(state, "body") || mode == :in_template do
    process_start_tag(state, "noscript", attrs, self_closing)
  else
    state
    |> ensure_html()
    |> ensure_head()
    |> maybe_reopen_head()
    |> process_start_tag("noscript", attrs, self_closing)
  end
end

defp do_process_html_start_tag("noscript", attrs, self_closing, %{scripting: true} = state) do
  if find_ref(state, "body") do
    process_start_tag(state, "noscript", attrs, self_closing)
  else
    state
    |> ensure_html()
    |> ensure_head()
    |> maybe_reopen_head()
    |> process_start_tag("noscript", attrs, self_closing)
  end
end

# <noscript> with scripting disabled: reconstruct AF, push element (parsed as HTML)
defp do_process_html_start_tag("noscript", attrs, _, state) do
  state
  |> in_body()
  |> reconstruct_active_formatting()
  |> push_element("noscript", attrs)
end
```

**Step 3: Compile and run existing tests**

Run: `mix compile --warnings-as-errors && mix test test/pure_html/html5lib_tree_construction_test.exs`

Expected: All 1668 tests pass.

**Step 4: Commit**

```
feat: handle noscript in in_body based on scripting flag
```

---

### Task 4: Update `determine_mode_from_stack` for scripting flag

**Files:**
- Modify: `lib/pure_html/tree_builder/helpers.ex:887-925`
- Modify: `lib/pure_html/tree_builder.ex:298` (call site)

**Step 1: Add scripting parameter to `determine_mode_from_stack`**

The function currently takes `(stack, elements, context)`. Add a 4th param
`scripting` (boolean). Add a clause that checks for `"noscript"` before the
general map lookup:

```elixir
def determine_mode_from_stack([], _elements, nil, _scripting), do: :in_body

def determine_mode_from_stack([], _elements, {_ns, tag}, scripting) do
  determine_mode_for_tag(tag, scripting)
end

def determine_mode_from_stack([_ref], _elements, {_ns, _tag} = context, scripting) do
  determine_mode_from_stack([], nil, context, scripting)
end

def determine_mode_from_stack([ref | rest], elements, context_element, scripting) do
  tag = elements[ref].tag

  case determine_mode_for_tag(tag, scripting) do
    nil ->
      determine_mode_from_stack(rest, elements, context_element, scripting)

    :in_select ->
      if has_table_ancestor?(rest, elements),
        do: :in_select_in_table,
        else: :in_select

    mode ->
      mode
  end
end

defp determine_mode_for_tag("noscript", true), do: :in_head
defp determine_mode_for_tag(tag, _scripting), do: Map.get(@tag_to_mode, tag)
```

**Step 2: Update call site in `tree_builder.ex`**

In `lib/pure_html/tree_builder.ex` line 298:

```elixir
mode = determine_mode_from_stack(state.stack, state.elements, context, scripting)
```

Also update the import to match new arity:

```elixir
import PureHTML.TreeBuilder.Helpers,
  only: [
    add_child_to_stack: 2,
    determine_mode_from_stack: 4
  ]
```

**Step 3: Check for other call sites of `determine_mode_from_stack`**

Search for other callers — if helpers.ex calls it internally (e.g., reset
insertion mode), those need updating too.

**Step 4: Compile and run existing tests**

Run: `mix compile --warnings-as-errors && mix test test/pure_html/html5lib_tree_construction_test.exs`

Expected: All 1668 tests pass.

**Step 5: Commit**

```
feat: pass scripting flag through determine_mode_from_stack
```

---

### Task 5: Update test infrastructure for dual scripting modes

**Files:**
- Modify: `test/pure_html/html5lib_tree_construction_test.exs`

**Step 1: Rewrite test generation for dual-mode support**

Replace the current test generation with logic that:
- `#script-off` tests: run once with `scripting: false`, tagged `scripting: :off`
- `#script-on` tests: run once with `scripting: true`, tagged `scripting: :on`
- Neither: run twice — once per mode, each with appropriate tag

```elixir
defmodule PureHTML.Html5libTreeConstructionTest do
  use ExUnit.Case, async: true

  alias PureHTML.Test.Html5libTreeConstructionTests, as: H5

  for path <- H5.list_test_files() do
    filename = Path.basename(path, ".dat")

    describe filename do
      for {test, index} <- Enum.with_index(H5.parse_file(path)) do
        scripting_modes =
          cond do
            test.script_off -> [{false, "off"}]
            test.script_on -> [{true, "on"}]
            true -> [{true, "on"}, {false, "off"}]
          end

        for {scripting, label} <- scripting_modes do
          @tag :html5lib
          @tag :tree_construction
          @tag test_file: filename
          @tag test_num: index
          @tag test_id: "#{filename}:#{index}"
          @tag scripting: String.to_atom(label)
          test "##{index} [script-#{label}]: #{String.slice(test.data, 0, 40)}" do
            test = unquote(Macro.escape(test))
            scripting = unquote(scripting)

            document =
              case test.document_fragment do
                nil ->
                  PureHTML.parse(test.data, scripting: scripting)

                context ->
                  PureHTML.parse(test.data, context: context, scripting: scripting)
              end

            actual = H5.serialize_document(document) |> String.trim_trailing("\n")
            expected = test.document |> String.trim_trailing("\n")

            assert actual == expected
          end
        end
      end
    end
  end
end
```

**Step 2: Run the full test suite**

Run: `mix test test/pure_html/html5lib_tree_construction_test.exs`

Expected: ~3300+ tests. The script-on tests and unmarked-with-scripting-on
tests should all pass (same as before). Script-off tests and
unmarked-with-scripting-off tests may have failures to investigate.

**Step 3: Commit passing state**

```
feat: run html5lib tests in both scripting modes
```

---

### Task 6: Fix failures from scripting-disabled mode

**Files:** TBD based on failures

**Step 1: Run only scripting-off tests to see failures**

Run: `mix test test/pure_html/html5lib_tree_construction_test.exs --only scripting:off`

**Step 2: Categorize and fix failures**

Most failures will likely be in `noscript01.dat` tests where `<noscript>`
content should be parsed as HTML instead of raw text. The fixes from Tasks 2-4
should handle these. Any remaining failures likely indicate edge cases in the
`in_head_noscript` mode or body noscript handling.

**Step 3: Iterate until all tests pass**

Run: `mix test test/pure_html/html5lib_tree_construction_test.exs`

Expected: All ~3300+ tests pass.

**Step 4: Run full suite**

Run: `mix test`

Expected: All tests pass.

**Step 5: Run format and credo**

Run: `mix format && mix credo --strict`

**Step 6: Commit**

```
fix: resolve scripting-disabled test failures
```

---

### Task 7: Final verification and cleanup

**Step 1: Run full test suite**

Run: `mix test`

Expected: All tests pass (9000+ including property tests).

**Step 2: Verify filtering works**

Run: `mix test test/pure_html/html5lib_tree_construction_test.exs --only scripting:on`
Run: `mix test test/pure_html/html5lib_tree_construction_test.exs --only scripting:off`

Both should pass independently.

**Step 3: Run format and credo**

Run: `mix format && mix credo --strict`

**Step 4: Commit any remaining cleanup**

```
chore: final cleanup for scripting flag support
```

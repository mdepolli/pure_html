# EOF Token Dispatch — Full WHATWG Spec Compliance

## Context

The WHATWG spec treats EOF as a real token emitted by the tokenizer that flows through the tree construction dispatcher to insertion modes. PureHTML's tokenizer currently returns `nil` on EOF and `build_loop` just stops — never dispatching EOF to insertion modes. This means modes that need cleanup on EOF (popping unclosed elements, clearing template stacks) never get triggered.

Two modes (`text.ex:38`, `in_head_noscript.ex:95`) already have `:eof` handlers that are dead code. The insertion mode type (`insertion_mode.ex:20`) already includes `:eof`. The foreign content bypass (`tree_builder.ex:510`) already has an `:eof` guard (though using wrong form `{:eof}` instead of `:eof`).

This plan also includes "generate implied end tags thoroughly" (Compliance Report finding #5) since it's required for correct EOF handling in `in_body`.

## Step 1: Add `generate_implied_end_tags_thoroughly` to `in_body.ex`

**File**: `lib/pure_html/tree_builder/modes/in_body.ex`

Add a new attribute alongside the existing `@implied_end_tag_tags` (line 1639):

```elixir
@implied_end_tag_tags_thorough ~w(
  caption colgroup dd dt li optgroup option p rb rp rt rtc
  tbody td tfoot th thead tr
)
```

Add `generate_implied_end_tags_thoroughly/1` — same algorithm as `generate_implied_end_tags/1` (lines 1791-1803) but uses the expanded list.

**Run tests** to confirm no regressions.

## Step 2: Add `:eof` handlers to all modes that need them

Each handler is small (1-5 lines). Add them **above** any catch-all `_token` clause so they match first.

### Modes that need new handlers:

| File | Handler |
|---|---|
| `modes/in_body.ex` | `generate_implied_end_tags_thoroughly(state)`, return `{:ok, state}` |
| `modes/in_template.ex` | If `template_mode_stack == []`, return `{:ok, state}`. Else: `pop_until_tag(state, "template")`, `clear_af_to_marker`, pop template mode stack, `determine_mode_from_stack`, `{:reprocess, state}` |
| `modes/in_column_group.ex` | Reuse `close_colgroup_or_ignore(state)` — pops colgroup if current, switches to in_table, reprocesses; otherwise stops |
| `modes/in_table.ex` | Add to `process_in_table`: `{:reprocess, %{state \| mode: :in_body}}` |
| `modes/in_caption.ex` | `{:reprocess, %{state \| mode: :in_body}}` |
| `modes/in_table_body.ex` | `{:reprocess, %{state \| mode: :in_body}}` |
| `modes/in_row.ex` | `{:reprocess, %{state \| mode: :in_body}}` |
| `modes/in_cell.ex` | `{:reprocess, %{state \| mode: :in_body}}` |
| `modes/after_body.ex` | `{:ok, state}` — prevents catch-all from incorrectly reprocessing in in_body |
| `modes/after_after_body.ex` | `{:ok, state}` — same |
| `modes/in_select.ex` | `{:ok, state}` |
| `modes/in_frameset.ex` | `{:ok, state}` |

Note: `in_select_in_table.ex` delegates via `process(token, state)` to InSelect, which will now handle `:eof`. No change needed there.

Note: `in_table.ex` routes through `process(token, state) -> process_dispatch -> process_in_table`. The `:eof` handler goes in `process_in_table` since that's where all tuple-pattern matching lives.

**Imports needed**: `in_template.ex` needs `pop_until_tag`, `clear_af_to_marker`, `determine_mode_from_stack`. `in_body.ex` already has what it needs.

**Run tests** to confirm no regressions — handlers are still dead code at this point.

## Step 3: Make tokenizer emit `:eof` token

**File**: `lib/pure_html/tokenizer.ex`

1. Add `:eof` to the `@type token` union (line 29-35)
2. Add `eof_emitted: false` field to the `%Tokenizer{}` struct
3. Change the EOF clause (line 189-191) from returning `nil` to returning `{:eof, %{state | eof_emitted: true}}`
4. Add a new clause matching `%{eof_emitted: true}` that returns `nil` (preserves `Stream.unfold` contract)
5. The pending-chars clause (line 194-198) stays as-is — flushes chars first, next call hits the `:eof` clause

**Do together with Step 4** — the tokenizer and build_loop changes must land simultaneously.

## Step 4: Wire `:eof` through `build_loop` and clean up

**File**: `lib/pure_html/tree_builder.ex`

1. **`build_loop`** (line 311-324): The `nil` branch now just returns `acc` (the loop is done — `:eof` was already dispatched as a token in a previous iteration). Remove the `flush_pending_table_text` call — this is now handled by `in_table_text`'s catch-all which flushes and reprocesses `:eof` to the original mode.

2. **Fix `:eof` form**: Change `use_foreign_content_rules?({:eof}, _state)` at line 510 to `use_foreign_content_rules?(:eof, _state)` — match the atom form used by modes and defined in `insertion_mode.ex`.

3. **Remove** `flush_pending_table_text/1` and `foster_parent_with_formatting/2` and `entries_needing_reconstruction/1` and `reconstruct_formatting_for_foster/2` helper functions (lines 326-376) — they are now dead code since the equivalent logic lives in `in_table_text.ex`.

**Run tests** after combining Steps 3+4. All ~1500 tests should pass.

## Implementation Order

Do steps in this order so the codebase compiles and tests pass at each checkpoint:

1. **Step 1** (add thoroughly variant) → tests pass, no behavioral change
2. **Step 2** (add EOF handlers) → tests pass, handlers are dead code
3. **Steps 3+4 together** (tokenizer emits `:eof`, build_loop wired, cleanup) → tests pass, EOF now flows through modes

## Files Modified

- `lib/pure_html/tokenizer.ex` — emit `:eof` token, add `eof_emitted` field
- `lib/pure_html/tree_builder.ex` — simplify `build_loop`, fix `:eof` form, remove dead helpers
- `lib/pure_html/tree_builder/modes/in_body.ex` — `generate_implied_end_tags_thoroughly`, `:eof` handler
- `lib/pure_html/tree_builder/modes/in_template.ex` — `:eof` handler with template cleanup loop
- `lib/pure_html/tree_builder/modes/in_column_group.ex` — `:eof` handler (reuse `close_colgroup_or_ignore`)
- `lib/pure_html/tree_builder/modes/in_table.ex` — `:eof` in `process_in_table`
- `lib/pure_html/tree_builder/modes/in_caption.ex` — `:eof` handler
- `lib/pure_html/tree_builder/modes/in_table_body.ex` — `:eof` handler
- `lib/pure_html/tree_builder/modes/in_row.ex` — `:eof` handler
- `lib/pure_html/tree_builder/modes/in_cell.ex` — `:eof` handler
- `lib/pure_html/tree_builder/modes/after_body.ex` — `:eof` handler
- `lib/pure_html/tree_builder/modes/after_after_body.ex` — `:eof` handler
- `lib/pure_html/tree_builder/modes/in_select.ex` — `:eof` handler
- `lib/pure_html/tree_builder/modes/in_frameset.ex` — `:eof` handler

## Verification

```bash
# Full html5lib test suite
mix test test/pure_html/html5lib_tree_construction_test.exs

# Template-specific tests (most likely to exercise EOF in template)
mix test test/pure_html/html5lib_tree_construction_test.exs --only test_file:template

# Full suite
mix test

# Code quality
mix format
mix credo --strict
```

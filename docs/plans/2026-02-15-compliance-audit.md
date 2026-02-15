# Non-Compliance Findings

## A. Test Infrastructure (vs html5lib-tests READMEs)

**1. Tests not run in both script modes** — `test/pure_html/html5lib_tree_construction_test.exs:12`

The README says tests without `#script-off` or `#script-on` must be run in **both** scripting modes. Our test file only runs each test once (and skips `script_off` tests entirely). This means hundreds of tests are only exercised in one mode instead of two.

**2. `#new-errors` section parsed but not combined** — `test/support/html5lib_tree_construction_tests.ex:49`

The struct stores `errors` from the `#errors` section, but the `#new-errors` section (which should add to the error count) is parsed yet never merged in.

**3. Error counts not validated at all** — `test/pure_html/html5lib_tree_construction_test.exs:33`

The README says the number of parse errors matters. Our tests only assert on the document tree output (`assert actual == expected`), never checking error counts.

---

## B. Parser Implementation (vs WHATWG Spec)

**4. ~~EOF not dispatched to insertion modes~~** — DONE (eee3b69)

~~The `build_loop` returns directly when the tokenizer returns `nil`. It never dispatches an `:eof` token through the insertion mode system. The spec requires each insertion mode to handle EOF explicitly (e.g., `text` mode must pop the current element; `in_template` must pop the template stack). Two modes (`text.ex:38`, `in_head_noscript.ex:95`) have `:eof` handlers that are dead code — they can never be reached.~~

**5. ~~No "generate all implied end tags thoroughly" variant~~** — DONE (eee3b69)

~~The spec defines two variants:~~
- ~~"generate implied end tags" (current list: `dd dt li optgroup option p rb rp rt rtc`) — implemented~~
- ~~"generate all implied end tags thoroughly" (adds: `caption colgroup tbody td tfoot th thead tr`) — **missing**~~

~~The "thoroughly" variant is needed for EOF handling in `in_body` and for `</body>`/`</html>` processing.~~

**6. ~~Fragment parsing: form element pointer not set~~** — DONE (1ca63a9)

~~Step 8 of the fragment parsing algorithm says: if the context element is a `form`, set the form element pointer to it. The `build_fragment` function never checks this — the form pointer stays `nil`.~~

**7. Fragment parsing: `noscript` tokenizer state ignores scripting flag** — `lib/pure_html.ex:287-303`

The spec says `noscript` should use RAWTEXT state only when scripting is **enabled**. Our code puts `noscript` in `@raw_text_elements` unconditionally. Since we assume scripting enabled, this happens to be correct for that assumption, but becomes wrong if we ever support scripting-disabled mode (relevant to finding #1 above).

**8. ~~`in_select.ex` searches entire stack for foreign namespace~~** — DONE (6883961)

~~The local `foreign_namespace/1` does `Enum.find_value(stack, ...)` scanning the whole stack. It should only check the adjusted current node (top of stack, or context element in fragment mode), per the helpers version.~~

---

## C. Lower Priority / Contextual

- **Quirks mode not inherited in fragment parsing** (spec step 2) — unlikely to matter since we don't receive external quirks mode info, but technically missing
- **Attribute sort order** uses Elixir's default UTF-8 comparison rather than UTF-16 code unit order — only diverges for non-ASCII attribute names, which are extremely rare in practice
- **Encoding confidence** not set in fragment parsing (spec step 9) — low practical impact

---

~~Findings **4** and **5** are related: once EOF dispatch is implemented, the "thoroughly" variant becomes necessary for correct `in_body` EOF handling.~~ Finding **1** is the biggest gap in test coverage.

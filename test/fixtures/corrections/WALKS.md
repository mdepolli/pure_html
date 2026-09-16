# Walks behind the corrections

Every block in this directory cites this file. Each entry below walks the disputed case through the WHATWG living standard's tokenizer or tree-construction algorithm and records what the text gives, which is what the correction asserts. A correction without a walk here is not legitimate; a walk that upstream has since adopted should take its correction with it.

Sections: https://html.spec.whatwg.org/multipage/parsing.html

## Tree construction: error counts

- `webkit02:44` `<select><button><selectedcontent></button><option>X` listed no errors. The text gives three: no doctype (initial, anything else), `</button>` with `selectedcontent` as the current node (in body, a `button` end tag: "if the current node is not an HTML element with the same tag name as that of the token, then this is a parse error"), and `select` open at EOF (in body, end-of-file: "if there is a node in the stack of open elements that is not [one of the listed elements], then this is a parse error").
- `webkit02:45`, `webkit02:46`, `webkit02:47` are the same shape with more content after the option and also listed no errors. The text gives the same three for 46 and 47 (a second `<option>` with an option as the current node just pops it), and four for 45: its `</i>` runs the adoption agency with `b` as the current node ("if formatting element is not the current node, this is a parse error").
- `webkit02:48` `<font><select><option>a</option></font></select>` listed no errors. The text gives three: no doctype, `</font>` whose formatting element is not in scope because `select` is a scope boundary in the adoption agency ("if formatting element is not in the stack of open elements, or is not in scope, then this is a parse error; return"), and `font` still open at EOF.
- `adoption02:2` `<nobr><table><marquee></table><nobr>` listed `end-tag-too-early-named` for the `</table>`. The in-table entry for a table end tag with a table in scope is "Pop elements from this stack until a table element has been popped from the stack. Reset the insertion mode appropriately." No error for the current node. The text gives four: no doctype, `<marquee>` foster-parented (in table, anything else: "parse error; enable foster parenting, process the token using the rules for the in body insertion mode"), the second `<nobr>` with a `nobr` in scope (in body, `nobr` start tag: "if the stack of open elements has a nobr element in scope, then this is a parse error"), and `nobr` open at EOF.

## Tree construction: processing instructions

Tag open on `?` empties the temporary buffer and switches to the processing instruction open state; there is no `unexpected-question-mark-instead-of-tag-name` in the current text. These fixtures predate that change.

- `tests1:39` `<?` listed a comment `?`. PI open at EOF is `eof-in-processing-instruction` and emits only the end-of-file token, so the tree is html/head/body. Count 2: that error plus initial's anything-else (missing doctype).
- `tests1:43` `<?COMMENT?>` and `tests1:46` `<?COM--MENT?>` listed comments. `C` is ASCII alpha, so the target state collects `COMMENT` / `COM--MENT` (hyphens are allowed in a target); `?` then `>` in the questionable state emits the PI with empty data. Count 1: missing doctype.
- `html5test-com:11` `<?import namespace="foo" implementation="#bar">` listed a comment. `import` is a legal target; after-target skips the space; `>` in PI data emits the PI with data `namespace="foo" implementation="#bar"`. Count 1: missing doctype.

## Tokenizer: processing instructions

Cases that listed `unexpected-question-mark-instead-of-tag-name` (`test3:1158-1190`, `test2:31-32`, `domjs:0-2`) are the pre-PI tag-open-`?` path. The text gives:

- A first character after `<?` that is not ASCII alpha or `_` (whitespace, `#`, NUL, EOF-adjacent controls) is `invalid-first-character-of-processing-instruction-target`; the temporary buffer is converted to a comment whose data is `?` plus the buffer, and the bogus comment state continues from that character, so `<?#` is the comment `?#` and `<?\n` the comment `?\n`. A NUL in the bogus comment state adds `unexpected-null-character` and U+FFFD.
- `<?` at EOF is `eof-in-processing-instruction` and emits no token.
- ASCII alpha then EOF (`<?A`) is `eof-in-processing-instruction` in the target state and emits nothing.
- A complete target followed by `>` (`<?namespace>`, `<?foo-->`) is a PI with that target, empty data, and no error.

## Walked and not corrected

- `tests1:110` (a long run of stray end tags inside a table row) lists 111 and the parser reports 111; an earlier claim that the text is one short was stale.
- `tests1:109` matches only because two disagreements cancel: html5lib counts two errors for a `</body>` seen before html, where the text routes it through "act as described in the anything else entry" in before html, before head, in head, and after head, then in body's `</body>` rule finds only html and body open, so no error; and html5lib counts one error for `</br>` in after body and for `</frameset>` in after after body, where the text gives two each: the mode's "Anything else: Parse error. Switch the insertion mode to in body and reprocess the token", then in body's own parse error for the token. The count agrees, so no correction; the tree and count are asserted as upstream lists them.

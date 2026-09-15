These are whole-file copies of html5lib fixtures whose expected tokens, trees, or `#errors` contradicted the WHATWG living standard.

The runners (`source_path/1` in `test/support/html5lib_tree_construction_tests.ex` and `test/support/html5lib_tokenizer_tests.ex`) read a file here in place of the submodule copy.

Patched tree cases have a `#spec` citation and `text:` error lines. Patched tokenizer cases have a `spec` field; PI tokens are `["ProcessingInstruction", target, data]`.

To correct another fixture, copy it here and fix the expected output. Do not update `test/html5lib-tests` past `9329e64` (upstream deleted the tree-construction files).

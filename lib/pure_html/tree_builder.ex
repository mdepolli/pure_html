defmodule PureHTML.TreeBuilder do
  @moduledoc """
  Builds an HTML document tree from a tokenizer.

  ## Architecture

  The tree builder separates parsing context from DOM construction:

  - **Parsing context**: Stack tracks "open elements" for scope checks and mode decisions.
    Active formatting list tracks formatting elements for the adoption agency algorithm.
  - **DOM structure**: Elements stored in a map with explicit parent_ref relationships.
    Foster parenting resolved at insertion time via appropriate_insertion_location.

  ## Data Structures

  - State struct: parsing context + DOM storage
  - Elements: %{ref, tag, attrs, parent_ref, children}
  - make_ref() for element IDs (no counter to pass around)
  - Insertion modes for O(1) context checks

  ## Output

  Final output: {tag, attrs, children} tuples (attrs are maps, not lists like Floki)
  """

  alias PureHTML.Tokenizer
  alias PureHTML.TreeBuilder.Modes

  # --------------------------------------------------------------------------
  # State and Element structures
  # --------------------------------------------------------------------------

  defmodule State do
    @moduledoc """
    Parser state for the HTML5 tree construction algorithm.

    Architecture: Stack tracks "open elements" for parsing context, while DOM
    structure is built via explicit parent_ref relationships in the elements map.
    """

    defstruct [
      # === Parsing Context ===
      # Stack of open elements (currently stores full elements, will migrate to refs only)
      stack: [],
      # Active formatting elements list
      af: [],
      # Current insertion mode
      mode: :initial,
      # Stack of template insertion modes (per HTML5 spec, separate from mode)
      template_mode_stack: [],
      # Original insertion mode (saved when switching to text/in_table_text)
      original_mode: nil,
      # Pending table character tokens (for in_table_text mode)
      pending_table_text: "",
      # Frameset-ok flag
      frameset_ok: true,
      # Head element pointer (for "in head" processing)
      head_element: nil,
      # Form element pointer (for form association)
      form_element: nil,
      # Scripting flag (we assume scripting enabled)
      scripting: true,

      # === DOM Structure ===
      # Element storage: ref => %{ref, tag, attrs, parent_ref, children}
      elements: %{},
      # Current parent element ref (for O(1) parent lookup during insertion)
      current_parent_ref: nil,
      # Top-level document children (comments before <html>)
      document_children: []
    ]
  end

  # HTML5 Insertion Modes (full spec)
  # :initial            - Starting state, before DOCTYPE
  # :before_html        - Before <html> element
  # :before_head        - Before <head> element
  # :in_head            - Inside <head>
  # :in_head_noscript   - Inside <noscript> in <head>
  # :after_head         - After </head>, before <body>
  # :in_body            - Inside <body> (main parsing mode)
  # :text               - Raw text mode (for script/style content)
  # :in_table           - Inside <table>
  # :in_table_text      - Collecting text in table context
  # :in_caption         - Inside <caption>
  # :in_column_group    - Inside <colgroup>
  # :in_table_body      - Inside <tbody>, <thead>, or <tfoot>
  # :in_row             - Inside <tr>
  # :in_cell            - Inside <td> or <th>
  # :in_select          - Inside <select>
  # :in_select_in_table - Inside <select> that's in a table
  # :in_template        - Inside <template>
  # :after_body         - After </body>
  # :in_frameset        - Inside <frameset>
  # :after_frameset     - After </frameset>

  # --------------------------------------------------------------------------
  # Mode modules
  # --------------------------------------------------------------------------

  @mode_modules %{
    initial: Modes.Initial,
    before_html: Modes.BeforeHtml,
    before_head: Modes.BeforeHead,
    in_head: Modes.InHead,
    in_head_noscript: Modes.InHeadNoscript,
    after_head: Modes.AfterHead,
    in_body: Modes.InBody,
    text: Modes.Text,
    in_table: Modes.InTable,
    in_table_text: Modes.InTableText,
    in_caption: Modes.InCaption,
    in_column_group: Modes.InColumnGroup,
    in_table_body: Modes.InTableBody,
    in_row: Modes.InRow,
    in_cell: Modes.InCell,
    in_select: Modes.InSelect,
    in_template: Modes.InTemplate,
    after_body: Modes.AfterBody,
    in_frameset: Modes.InFrameset,
    after_frameset: Modes.AfterFrameset
  }

  # --------------------------------------------------------------------------
  # Element categories (used by finalization)
  # --------------------------------------------------------------------------

  @table_context ~w(table tbody thead tfoot tr)
  @table_elements ~w(table caption colgroup col thead tbody tfoot tr td th script template style)

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @doc """
  Builds a document from a tokenizer.

  Returns `{doctype, nodes}` where nodes is a list of top-level nodes.
  """
  def build(%Tokenizer{} = tokenizer) do
    {doctype, %State{stack: stack}, pre_html_comments} =
      build_loop(tokenizer, {nil, %State{}, []})

    html_node = finalize(stack)
    nodes = Enum.reverse(pre_html_comments) ++ [html_node]
    {doctype, nodes}
  end

  defp build_loop(tokenizer, acc) do
    # Update tokenizer with current foreign content context
    tokenizer = update_tokenizer_context(tokenizer, acc)

    case Tokenizer.next_token(tokenizer) do
      nil ->
        # Flush any pending table text before finalizing
        flush_pending_table_text(acc)

      {token, tokenizer} ->
        acc = process_token(token, acc)
        build_loop(tokenizer, acc)
    end
  end

  # Flush pending table text if any (for in_table_text mode at EOF)
  defp flush_pending_table_text({doctype, %State{pending_table_text: ""} = state, comments}) do
    {doctype, state, comments}
  end

  defp flush_pending_table_text(
         {doctype, %State{pending_table_text: text, stack: stack} = state, comments}
       ) do
    new_stack =
      if String.trim(text) == "" do
        # Whitespace only: insert normally
        add_text(stack, text)
      else
        # Contains non-whitespace: foster parent
        foster_text(stack, text)
      end

    {doctype, %{state | stack: new_stack, pending_table_text: ""}, comments}
  end

  defp update_tokenizer_context(tokenizer, {_, %State{stack: stack}, _}) do
    # We're in foreign content when the current element (top of stack) is foreign
    in_foreign = current_element_is_foreign?(stack)
    Tokenizer.set_foreign_content(tokenizer, in_foreign)
  end

  defp current_element_is_foreign?([%{tag: {ns, _}} | _]) when ns in [:svg, :math], do: true
  defp current_element_is_foreign?(_), do: false

  defp process_token(
         {:doctype, name, public_id, system_id, _},
         {_, %State{mode: :initial} = state, comments}
       ) do
    {{name, public_id, system_id}, state, comments}
  end

  defp process_token({:doctype, _, _, _, _}, acc), do: acc

  defp process_token({:comment, text}, {doctype, %State{stack: []} = state, comments}) do
    {doctype, state, [{:comment, text} | comments]}
  end

  defp process_token(token, {doctype, state, comments}) do
    {doctype, dispatch(token, state), comments}
  end

  # Dispatch token to the appropriate mode module or fall back to existing process/2
  defp dispatch(token, %State{mode: mode} = state) when is_map_key(@mode_modules, mode) do
    module = Map.fetch!(@mode_modules, mode)

    case module.process(token, state) do
      {:ok, new_state} ->
        new_state

      {:reprocess, new_state} ->
        dispatch(token, new_state)
    end
  end

  # --------------------------------------------------------------------------
  # Element creation helpers
  # --------------------------------------------------------------------------

  defp new_element(tag, attrs \\ %{}) do
    %{ref: make_ref(), tag: tag, attrs: attrs, children: []}
  end

  # --------------------------------------------------------------------------
  # Helper functions (used by finalization and flush_pending_table_text)
  # --------------------------------------------------------------------------

  defp has_tag?(nodes, tag) do
    Enum.any?(nodes, fn
      %{tag: t} -> t == tag
      _ -> false
    end)
  end

  # --------------------------------------------------------------------------
  # Foster parenting (used by flush_pending_table_text)
  # --------------------------------------------------------------------------

  defp foster_text(stack, text) do
    foster_content(stack, text, [], &add_foster_text/2)
  end

  defp foster_content([%{tag: "table"} = table | rest], content, acc, add_fn) do
    rest = add_fn.(rest, content)
    rebuild_stack(acc, [table | rest])
  end

  defp foster_content([current | rest], content, acc, add_fn) do
    foster_content(rest, content, [current | acc], add_fn)
  end

  defp foster_content([], _content, acc, _add_fn) do
    Enum.reverse(acc)
  end

  defp add_foster_text([%{children: [prev | children]} = elem | rest], text)
       when is_binary(prev) do
    [%{elem | children: [prev <> text | children]} | rest]
  end

  defp add_foster_text([%{children: children} = elem | rest], text) do
    [%{elem | children: [text | children]} | rest]
  end

  defp add_foster_text([], _text), do: []

  defp rebuild_stack(acc, stack), do: Enum.reverse(acc, stack)

  # --------------------------------------------------------------------------
  # Stack operations
  # --------------------------------------------------------------------------

  defp add_child([%{children: children} = parent | rest], child) do
    [%{parent | children: [child | children]} | rest]
  end

  defp add_child([], child) do
    [child]
  end

  defp add_text([%{children: [prev_text | rest_children]} = parent | rest], text)
       when is_binary(prev_text) do
    [%{parent | children: [prev_text <> text | rest_children]} | rest]
  end

  defp add_text([%{children: children} = parent | rest], text) do
    [%{parent | children: [text | children]} | rest]
  end

  defp add_text([], _text), do: []

  # --------------------------------------------------------------------------
  # Finalization
  # --------------------------------------------------------------------------

  defp finalize(stack) do
    stack
    |> close_through_head()
    |> ensure_head_final()
    |> ensure_body_final()
    |> do_finalize()
    |> convert_to_tuples()
  end

  defp close_through_head([%{tag: "html"}] = stack), do: stack
  defp close_through_head([%{tag: "body"} | _] = stack), do: stack

  defp close_through_head([%{tag: "head"} = head | rest]) do
    # Close head into its parent (should be html)
    close_through_head(foster_aware_add_child(rest, head))
  end

  defp close_through_head([elem | rest]) do
    close_through_head(foster_aware_add_child(rest, elem))
  end

  defp close_through_head([]) do
    [%{new_element("html") | children: [new_element("head")]}]
  end

  defp ensure_head_final([%{tag: "html", children: children} = html]) do
    if has_tag?(children, "head") do
      [html]
    else
      [%{html | children: children ++ [new_element("head")]}]
    end
  end

  defp ensure_head_final([current | rest]) do
    [current | ensure_head_final(rest)]
  end

  defp ensure_head_final([]), do: []

  defp ensure_body_final([%{tag: "body"} | _] = stack), do: stack
  defp ensure_body_final([%{tag: "frameset"} | _] = stack), do: stack

  defp ensure_body_final([%{tag: "html", children: children} = html]) do
    if has_tag?(children, "body") or has_tag?(children, "frameset") do
      [html]
    else
      [new_element("body"), html]
    end
  end

  defp ensure_body_final([current | rest]) do
    [current | ensure_body_final(rest)]
  end

  defp ensure_body_final([]), do: []

  defp do_finalize([]), do: nil

  defp do_finalize([elem]) do
    %{elem | children: reverse_all(elem.children)}
  end

  defp do_finalize([elem | rest]) do
    do_finalize(foster_aware_add_child(rest, elem))
  end

  defp foster_aware_add_child([%{tag: next_tag} | _] = rest, %{tag: child_tag} = child)
       when next_tag in @table_context and child_tag in @table_elements do
    add_child(rest, child)
  end

  defp foster_aware_add_child([%{tag: next_tag} | _] = rest, child)
       when next_tag in @table_context do
    if has_tag?(rest, "body") do
      foster_add_to_body(rest, child, [])
    else
      add_child(rest, child)
    end
  end

  defp foster_aware_add_child(rest, child) do
    add_child(rest, child)
  end

  defp foster_add_to_body([%{tag: "body"} | _] = stack, child, acc) do
    rebuild_stack(acc, add_child(stack, child))
  end

  defp foster_add_to_body([current | rest], child, acc) do
    foster_add_to_body(rest, child, [current | acc])
  end

  defp foster_add_to_body([], child, acc) do
    Enum.reverse([child | acc])
  end

  defp reverse_all(children) do
    children
    |> Enum.reverse()
    |> Enum.map(&reverse_node/1)
  end

  defp reverse_node(%{children: kids} = elem), do: %{elem | children: reverse_all(kids)}
  defp reverse_node({tag, attrs, kids}), do: {tag, attrs, reverse_all(kids)}
  defp reverse_node(leaf), do: leaf

  defp convert_to_tuples(nil), do: nil
  defp convert_to_tuples({:comment, text}), do: {:comment, text}
  defp convert_to_tuples(text) when is_binary(text), do: text

  # Template elements wrap children in :content tuple
  defp convert_to_tuples(%{tag: "template", attrs: attrs, children: children}) do
    {"template", attrs, [{:content, convert_children(children)}]}
  end

  # Map elements convert to tuples, preserving namespace if present
  defp convert_to_tuples(%{tag: tag, attrs: attrs, children: children}) do
    {tag, attrs, convert_children(children)}
  end

  # Already-converted tuples just need children converted
  defp convert_to_tuples({tag, attrs, children}) do
    {tag, attrs, convert_children(children)}
  end

  defp convert_children(children), do: Enum.map(children, &convert_to_tuples/1)
end

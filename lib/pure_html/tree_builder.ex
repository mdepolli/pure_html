defmodule PureHTML.TreeBuilder do
  @moduledoc """
  Builds an HTML document tree from a tokenizer, following the WHATWG tree
  construction stage.

  ## Architecture

  - **Parsing context**: the stack of open elements (refs), the list of active
    formatting elements, the insertion mode, the stack of template insertion
    modes, and the element pointers, all in the `State` struct.
  - **DOM structure**: elements stored in a map keyed by `make_ref()`, each with
    its tag, attributes, children, and parent ref. The stack top is the
    insertion parent; foster parenting is resolved at insertion time.
  - **Dispatch**: each token goes to the foreign content rules
    (`PureHTML.TreeBuilder.ForeignContent`) or to the module for the current
    insertion mode. The modes switch the tokenizer state for raw text, RCDATA,
    script data, and plaintext.
  - **After parsing**: `PureHTML.TreeBuilder.SelectedContent` replays the
    customizable select's selectedcontent mirroring over the finished tree.

  ## Output

  Final output: {tag, attrs, children} tuples (attrs are lists of {name, value} tuples)
  """

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.Tokenizer
  alias PureHTML.TreeBuilder.ForeignContent
  alias PureHTML.TreeBuilder.Modes
  alias PureHTML.TreeBuilder.Modes.InBody
  alias PureHTML.TreeBuilder.Quirks
  alias PureHTML.TreeBuilder.SelectedContent

  # --------------------------------------------------------------------------
  # Type Definitions
  # --------------------------------------------------------------------------

  @typedoc "DOCTYPE information: {name, public_id, system_id} or nil if absent."
  @type doctype :: {String.t() | nil, String.t() | nil, String.t() | nil} | nil

  @typedoc "Document node: element tuple, comment, or text."
  @type document_node ::
          {State.tag_name(), [{String.t(), String.t()}], [document_node()]}
          | {:comment, String.t()}
          | {:content, [document_node()]}
          | String.t()

  # --------------------------------------------------------------------------
  # State and Element structures
  # --------------------------------------------------------------------------

  defmodule State do
    @moduledoc """
    Parser state for the HTML5 tree construction algorithm.

    Architecture: Stack tracks "open elements" for parsing context, while DOM
    structure is built via explicit parent_ref relationships in the elements map.
    """

    # --------------------------------------------------------------------------
    # Type Definitions
    # --------------------------------------------------------------------------

    @typedoc "Reference to an element in the elements map."
    @type element_ref :: reference()

    @typedoc "HTML tag name (string) or foreign element tag ({namespace, name})."
    @type tag_name :: String.t() | {namespace(), String.t()}

    @typedoc "Namespace for foreign elements (SVG or MathML)."
    @type namespace :: :svg | :math

    @typedoc """
    Internal element representation stored in the elements map.

    Fields:
    - `ref` - unique reference for this element
    - `tag` - tag name (string or {namespace, name} tuple)
    - `attrs` - element attributes as a list of {name, value} tuples
    - `children` - list of children (refs, text strings, comments, or tuples)
    - `parent_ref` - reference to parent element (nil for root)
    """
    @type element :: %{
            ref: element_ref(),
            tag: tag_name(),
            attrs: [{String.t(), String.t()}],
            children: [child()],
            parent_ref: element_ref() | nil
          }

    @typedoc "Child content: element ref, text, comment, or pre-built tuple."
    @type child :: element_ref() | String.t() | {:comment, String.t()} | output_node()

    @typedoc "Output node format: {tag, attrs, children} tuple."
    @type output_node :: {tag_name(), [{String.t(), String.t()}], [output_node() | String.t()]}

    @typedoc """
    HTML5 insertion mode.

    The tree builder uses insertion modes to handle tokens differently based on
    the current parsing context (e.g., inside head vs inside body vs inside table).
    """
    @type insertion_mode ::
            :initial
            | :before_html
            | :before_head
            | :in_head
            | :in_head_noscript
            | :after_head
            | :in_body
            | :text
            | :in_table
            | :in_table_text
            | :in_caption
            | :in_column_group
            | :in_table_body
            | :in_row
            | :in_cell
            | :in_template
            | :after_body
            | :after_after_body
            | :in_frameset
            | :after_frameset
            | :after_after_frameset

    @typedoc """
    Active formatting element entry.

    Either a marker (for scope boundaries like applet, object, etc.) or a tuple
    containing the element ref, tag name, and attributes for reconstruction.
    """
    @type af_entry :: :marker | {element_ref(), String.t(), [{String.t(), String.t()}]}

    @typedoc "The tree builder state."
    @type t :: %__MODULE__{
            # Parsing Context
            stack: [element_ref()],
            af: [af_entry()],
            mode: insertion_mode(),
            template_mode_stack: [insertion_mode()],
            original_mode: insertion_mode() | nil,
            tokenizer_state: atom() | nil,
            pending_table_text: String.t(),
            frameset_ok: boolean(),
            head_element: element_ref() | nil,
            form_element: element_ref() | nil,
            scripting: boolean(),
            # DOM Structure
            elements: %{element_ref() => element()},
            document_children: [child()],
            post_html_nodes: [child()],
            error_count: non_neg_integer()
          }

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
      # Tokenizer state to switch to before the next token (raw text, RCDATA, script, plaintext)
      tokenizer_state: nil,
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
      # Quirks mode flag (affects table/p interaction)
      quirks_mode: false,
      # Foster parenting flag (when true, elements inserted via foster_parent)
      foster_parenting: false,
      # Fragment parsing context element - {namespace, tag} or nil
      context_element: nil,

      # === DOM Structure ===
      # Element storage: ref => %{ref, tag, attrs, parent_ref, children}
      elements: %{},
      # Current parent element ref (for O(1) parent lookup during insertion)
      # Top-level document children (comments before <html>)
      document_children: [],
      # Post-html nodes (comments after </html>)
      post_html_nodes: [],
      # Parse error count (tokenizer + tree construction errors)
      error_count: 0
    ]
  end

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
    in_body: InBody,
    text: Modes.Text,
    in_table: Modes.InTable,
    in_table_text: Modes.InTableText,
    in_caption: Modes.InCaption,
    in_column_group: Modes.InColumnGroup,
    in_table_body: Modes.InTableBody,
    in_row: Modes.InRow,
    in_cell: Modes.InCell,
    in_template: Modes.InTemplate,
    after_body: Modes.AfterBody,
    after_after_body: Modes.AfterAfterBody,
    in_frameset: Modes.InFrameset,
    after_frameset: Modes.AfterFrameset,
    after_after_frameset: Modes.AfterAfterFrameset
  }

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @doc """
  Builds a document from a tokenizer.

  Returns a list of top-level nodes. If a doctype is present, it appears first
  as `{:doctype, name, public_id, system_id}`.
  """
  @spec build(Tokenizer.t(), boolean()) :: [document_node()]
  def build(%Tokenizer{} = tokenizer, scripting \\ true) do
    {nodes, _error_count} = do_build(tokenizer, scripting)
    nodes
  end

  @doc """
  Builds a document from a tokenizer, returning both nodes and parse error count.

  Same as `build/2` but returns `{nodes, error_count}`.
  """
  @spec build_with_errors(Tokenizer.t(), boolean()) :: {[document_node()], non_neg_integer()}
  def build_with_errors(%Tokenizer{} = tokenizer, scripting \\ true) do
    do_build(tokenizer, scripting)
  end

  defp do_build(tokenizer, scripting) do
    {doctype, state, pre_html_comments} =
      build_loop(tokenizer, {nil, %State{scripting: scripting}, []})

    html_node = finalize(state)
    pre_comments = Enum.reverse(pre_html_comments)
    post_nodes = Enum.reverse(state.post_html_nodes)

    nodes =
      case doctype do
        nil ->
          pre_comments ++ [html_node] ++ post_nodes

        {name, public, system} ->
          [{:doctype, name, public, system} | pre_comments] ++ [html_node] ++ post_nodes
      end

    {nodes, state.error_count}
  end

  @doc """
  Builds a fragment from a tokenizer using the given context element.

  Implements the WHATWG "parsing HTML fragments" algorithm. The context element
  determines the initial insertion mode and parser behavior.

  Returns a list of child nodes (no `<html>/<head>/<body>` wrappers).
  """
  @spec build_fragment(Tokenizer.t(), atom() | nil, String.t(), boolean()) :: [document_node()]
  def build_fragment(%Tokenizer{} = tokenizer, namespace, tag, scripting \\ true) do
    {children, _error_count} = do_build_fragment(tokenizer, namespace, tag, scripting)
    children
  end

  @doc """
  Builds a fragment from a tokenizer, returning both children and parse error count.

  Same as `build_fragment/4` but returns `{children, error_count}`.
  """
  @spec build_fragment_with_errors(Tokenizer.t(), atom() | nil, String.t(), boolean()) ::
          {[document_node()], non_neg_integer()}
  def build_fragment_with_errors(%Tokenizer{} = tokenizer, namespace, tag, scripting \\ true) do
    do_build_fragment(tokenizer, namespace, tag, scripting)
  end

  defp do_build_fragment(tokenizer, namespace, tag, scripting) do
    context = {namespace, tag}

    # Step 1: Create an html element and push it onto the stack
    html_ref = make_ref()

    html_elem = %{
      ref: html_ref,
      tag: "html",
      attrs: [],
      children: [],
      parent_ref: nil
    }

    elements = %{html_ref => html_elem}

    # Step 2: Only html goes on the stack per WHATWG spec.
    # The context element is used via the "adjusted current node" concept.
    stack = [html_ref]

    # Step 3: Set up initial state with context element
    template_mode_stack = if tag == "template", do: [:in_template], else: []

    state = %State{
      stack: stack,
      elements: elements,
      context_element: context,
      template_mode_stack: template_mode_stack,
      scripting: scripting
    }

    # Step 4: Reset the insertion mode appropriately
    state = reset_insertion_mode(state)

    # Step 5: If the context element is a form element, set the form element pointer
    state =
      if namespace == nil and tag == "form",
        do: %{state | form_element: make_ref()},
        else: state

    # Step 6: Run the normal build loop
    {_doctype, state, _comments} =
      build_loop(tokenizer, {nil, state, []})

    # Step 7: Return children of the html element
    {finalize_fragment(state, html_ref), state.error_count}
  end

  defp build_loop(tokenizer, acc) do
    # Update tokenizer with current foreign content context
    tokenizer = update_tokenizer_context(tokenizer, acc)

    case Tokenizer.next_token(tokenizer) do
      nil ->
        merge_tokenizer_errors(acc, tokenizer)

      {token, tokenizer} ->
        {tokenizer, acc} =
          token
          |> process_token(acc)
          |> apply_tokenizer_switch(tokenizer)

        build_loop(tokenizer, acc)
    end
  end

  # The insertion modes ask for a tokenizer state ("switch the tokenizer to
  # the RAWTEXT state"); it takes effect before the next token is read.
  defp apply_tokenizer_switch({_, %State{tokenizer_state: nil}, _} = acc, tokenizer),
    do: {tokenizer, acc}

  defp apply_tokenizer_switch(
         {doctype, %State{tokenizer_state: next} = state, comments},
         tokenizer
       ) do
    {Tokenizer.set_state(tokenizer, next), {doctype, %{state | tokenizer_state: nil}, comments}}
  end

  defp merge_tokenizer_errors({doctype, state, comments}, %Tokenizer{error_count: n}) do
    {doctype, %{state | error_count: state.error_count + n}, comments}
  end

  defp update_tokenizer_context(tokenizer, {_, %State{} = state, _}) do
    # Per spec: the adjusted current node is the context element if the parser
    # was created for fragment parsing and the stack has only one element.
    Tokenizer.set_foreign_content(tokenizer, ForeignContent.adjusted_current_node_foreign?(state))
  end

  defp process_token(
         {:doctype, name, public_id, system_id, force_quirks},
         {_, %State{mode: :initial} = state, comments}
       ) do
    # Per spec: parse error if name != "html", public_id is not missing,
    # or system_id is not missing and != "about:legacy-compat"
    state =
      if doctype_is_parse_error?(name, public_id, system_id, force_quirks),
        do: parse_error(state),
        else: state

    quirks = Quirks.mode(name, public_id, system_id, force_quirks) == :quirks
    {{name, public_id, system_id}, %{state | mode: :before_html, quirks_mode: quirks}, comments}
  end

  # DOCTYPE outside initial mode: parse error, ignore
  defp process_token({:doctype, _, _, _, _}, {doctype, state, comments}) do
    {doctype, parse_error(state), comments}
  end

  defp process_token({:comment, text}, {doctype, %State{stack: []} = state, comments}) do
    {doctype, state, [{:comment, text} | comments]}
  end

  defp process_token(token, {doctype, state, comments}) do
    {doctype, process_token_fully(token, state), comments}
  end

  # Per spec, foster parenting is enabled by an insertion mode for one token
  # ("enable foster parenting, process the token ..., and then disable foster
  # parenting"). The flag stays on through any reprocessing of that token.
  defp process_token_fully(token, state) do
    token
    |> dispatch(state)
    |> disable_foster_parenting()
  end

  # Per WHATWG spec: DOCTYPE is a parse error if name != "html", public_id is not
  # missing, or system_id is not missing and != "about:legacy-compat".
  defp doctype_is_parse_error?(name, public, system, force_quirks) do
    name != "html" or is_binary(public) or
      (is_binary(system) and system != "about:legacy-compat") or force_quirks
  end

  # Tree construction dispatcher per WHATWG spec.
  # Before routing to any insertion mode, checks the adjusted current node.
  # If foreign (and no integration point exception for the token type),
  # routes to foreign content rules instead.
  # See: https://html.spec.whatwg.org/multipage/parsing.html#tree-construction-dispatcher
  defp dispatch(token, %State{mode: mode} = state) when is_map_key(@mode_modules, mode) do
    result =
      if ForeignContent.applies?(token, state) do
        ForeignContent.process(token, state)
      else
        dispatch_to_insertion_mode(token, mode, state)
      end

    case result do
      {:ok, new_state} -> new_state
      {:reprocess, new_state} -> dispatch(token, new_state)
      {:reprocess_with, new_state, new_token} -> dispatch(new_token, new_state)
    end
  end

  defp dispatch_to_insertion_mode(:eof, mode, state) do
    Map.fetch!(@mode_modules, mode).process(:eof, state)
  end

  # Per spec, a token that is not routed to the foreign content rules (an
  # integration point exception, or an HTML current node) is processed with
  # the rules for the current insertion mode.
  defp dispatch_to_insertion_mode(token, mode, state) do
    Map.fetch!(@mode_modules, mode).process(token, state)
  end

  @doc false
  # "Process the token using the rules for the current insertion mode", for the
  # foreign content rules to hand a token back.
  def process_with_current_mode(token, %State{mode: mode} = state) do
    dispatch_to_insertion_mode(token, mode, state)
  end

  # --------------------------------------------------------------------------
  # Finalization
  # --------------------------------------------------------------------------

  # Finalize tree from state (ref-only stack + elements map)
  defp finalize(%State{stack: stack, elements: elements}) do
    # Find the html element - it should be the last element remaining on stack
    # or we need to find it by looking for an element with no parent
    html_ref = find_html_ref(stack, elements)

    if html_ref do
      elements
      |> build_tree_from_elements(html_ref)
      |> SelectedContent.populate()
      |> convert_to_tuples()
    else
      # No html element - create minimal structure
      {"html", [], [{"head", [], []}, {"body", [], []}]}
    end
  end

  defp finalize_fragment(%State{elements: elements}, html_ref) do
    html_elem = elements[html_ref]
    children = Enum.reverse(html_elem.children)

    Enum.map(children, &finalize_fragment_child(&1, elements))
  end

  defp finalize_fragment_child(child_ref, elements) when is_reference(child_ref) do
    elements
    |> build_tree_from_elements(child_ref)
    |> convert_to_tuples()
  end

  defp finalize_fragment_child(text, _elements) when is_binary(text), do: text
  defp finalize_fragment_child({:comment, _} = comment, _elements), do: comment

  defp finalize_fragment_child({tag, attrs, kids}, _elements)
       when is_binary(tag) or is_tuple(tag) do
    {tag, Enum.sort(attrs), Enum.reverse(kids)}
  end

  # Find the html element ref
  defp find_html_ref(stack, elements) do
    # First try: find html at bottom of stack
    html_ref =
      stack
      |> Enum.reverse()
      |> Enum.find(fn ref ->
        elem = elements[ref]
        elem && elem.tag == "html"
      end)

    # Fallback: find element with tag "html" in elements map
    html_ref || find_html_ref_in_elements(elements)
  end

  defp find_html_ref_in_elements(elements) do
    case Enum.find(elements, fn {_ref, elem} -> elem.tag == "html" end) do
      {ref, _elem} -> ref
      nil -> nil
    end
  end

  # Build tree recursively from elements map
  defp build_tree_from_elements(elements, ref) do
    elem = elements[ref]
    # Children are stored in reverse order (prepended), so reverse them
    children = Enum.reverse(elem.children)

    resolved_children =
      Enum.map(children, fn
        child_ref when is_reference(child_ref) ->
          # Recursively build child element
          build_tree_from_elements(elements, child_ref)

        text when is_binary(text) ->
          text

        {:comment, _} = comment ->
          comment

        {tag, attrs, kids} when is_binary(tag) or is_tuple(tag) ->
          # Already a tuple (foreign elements, void elements)
          {tag, attrs, Enum.reverse(kids)}

        %{tag: tag, attrs: attrs, children: kids} ->
          # Map element stored as child (from legacy code paths)
          %{tag: tag, attrs: attrs, children: Enum.reverse(kids)}
      end)

    %{tag: elem.tag, attrs: elem.attrs, children: resolved_children}
  end

  defp convert_to_tuples(nil), do: nil
  defp convert_to_tuples({:comment, text}), do: {:comment, text}
  defp convert_to_tuples(text) when is_binary(text), do: text

  # Template elements wrap children in :content tuple
  defp convert_to_tuples(%{tag: "template", attrs: attrs, children: children}) do
    {"template", sort_attrs(attrs), [{:content, convert_children(children)}]}
  end

  # Map elements convert to tuples, preserving namespace if present
  defp convert_to_tuples(%{tag: tag, attrs: attrs, children: children}) do
    {tag, sort_attrs(attrs), convert_children(children)}
  end

  # Already-converted tuples just need children converted
  defp convert_to_tuples({tag, attrs, children}) do
    {tag, sort_attrs(attrs), convert_children(children)}
  end

  defp convert_children(children), do: Enum.map(children, &convert_to_tuples/1)

  # Sort attributes alphabetically for deterministic output
  defp sort_attrs(attrs), do: Enum.sort(attrs)
end

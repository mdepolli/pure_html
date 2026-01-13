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
  alias PureHTML.TreeBuilder.{Helpers, Modes}

  import Helpers, only: [add_text_to_stack: 2, foster_parent: 2]

  # --------------------------------------------------------------------------
  # Type Definitions
  # --------------------------------------------------------------------------

  @typedoc "DOCTYPE information: {name, public_id, system_id} or nil if absent."
  @type doctype :: {String.t() | nil, String.t() | nil, String.t() | nil} | nil

  @typedoc "Document node: element tuple, comment, or text."
  @type document_node ::
          {State.tag_name(), %{String.t() => String.t()}, [document_node()]}
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
    - `attrs` - element attributes as a map
    - `children` - list of children (refs, text strings, comments, or tuples)
    - `parent_ref` - reference to parent element (nil for root)
    """
    @type element :: %{
            ref: element_ref(),
            tag: tag_name(),
            attrs: %{String.t() => String.t()},
            children: [child()],
            parent_ref: element_ref() | nil
          }

    @typedoc "Child content: element ref, text, comment, or pre-built tuple."
    @type child :: element_ref() | String.t() | {:comment, String.t()} | output_node()

    @typedoc "Output node format: {tag, attrs, children} tuple."
    @type output_node :: {tag_name(), %{String.t() => String.t()}, [output_node() | String.t()]}

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
            | :in_select
            | :in_select_in_table
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
    @type af_entry :: :marker | {element_ref(), String.t(), %{String.t() => String.t()}}

    @typedoc "The tree builder state."
    @type t :: %__MODULE__{
            # Parsing Context
            stack: [element_ref()],
            af: [af_entry()],
            mode: insertion_mode(),
            template_mode_stack: [insertion_mode()],
            original_mode: insertion_mode() | nil,
            pending_table_text: String.t(),
            frameset_ok: boolean(),
            head_element: element_ref() | nil,
            form_element: element_ref() | nil,
            scripting: boolean(),
            # DOM Structure
            elements: %{element_ref() => element()},
            current_parent_ref: element_ref() | nil,
            document_children: [child()],
            post_html_nodes: [child()]
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
      document_children: [],
      # Post-html nodes (comments after </html>)
      post_html_nodes: []
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
    in_select_in_table: Modes.InSelectInTable,
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
  @spec build(Tokenizer.t()) :: [document_node()]
  def build(%Tokenizer{} = tokenizer) do
    {doctype, state, pre_html_comments} =
      build_loop(tokenizer, {nil, %State{}, []})

    html_node = finalize(state)
    pre_comments = Enum.reverse(pre_html_comments)
    post_nodes = Enum.reverse(state.post_html_nodes)

    case doctype do
      nil ->
        pre_comments ++ [html_node] ++ post_nodes

      {name, public, system} ->
        [{:doctype, name, public, system} | pre_comments] ++ [html_node] ++ post_nodes
    end
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

  defp flush_pending_table_text({doctype, %State{pending_table_text: text} = state, comments}) do
    new_state =
      if String.trim(text) == "" do
        # Whitespace only: insert normally
        add_text_to_stack(state, text)
      else
        # Contains non-whitespace: foster parent
        {state_with_text, _} = foster_parent(state, {:text, text})
        state_with_text
      end

    {doctype, %{new_state | pending_table_text: ""}, comments}
  end

  defp update_tokenizer_context(tokenizer, {_, %State{stack: stack, elements: elements}, _}) do
    # We're in foreign content when the current element (top of stack) is foreign
    in_foreign = current_element_is_foreign?(stack, elements)
    Tokenizer.set_foreign_content(tokenizer, in_foreign)
  end

  defp current_element_is_foreign?([ref | _], elements) do
    case elements[ref] do
      %{tag: {ns, _}} when ns in [:svg, :math] -> true
      _ -> false
    end
  end

  defp current_element_is_foreign?([], _), do: false

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

      {:reprocess_with, new_state, new_token} ->
        dispatch(new_token, new_state)
    end
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
      |> ensure_head()
      |> ensure_body()
      |> convert_to_tuples()
    else
      # No html element - create minimal structure
      {"html", %{}, [{"head", %{}, []}, {"body", %{}, []}]}
    end
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

  defp ensure_head(%{tag: "html", children: children} = html) do
    if Enum.any?(children, fn
         %{tag: "head"} -> true
         {"head", _, _} -> true
         _ -> false
       end) do
      html
    else
      %{html | children: [%{tag: "head", attrs: %{}, children: []} | children]}
    end
  end

  defp ensure_head(other), do: other

  defp ensure_body(%{tag: "html", children: children} = html) do
    has_body_or_frameset? =
      Enum.any?(children, fn
        %{tag: tag} -> tag in ["body", "frameset"]
        {tag, _, _} -> tag in ["body", "frameset"]
        _ -> false
      end)

    if has_body_or_frameset? do
      html
    else
      %{html | children: children ++ [%{tag: "body", attrs: %{}, children: []}]}
    end
  end

  defp ensure_body(other), do: other

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

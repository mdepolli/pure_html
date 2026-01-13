defmodule PureHTML.TreeBuilder.Modes.BeforeHead do
  @moduledoc """
  HTML5 "before head" insertion mode.

  This mode is entered after the html element is created.

  Per HTML5 spec:
  - Whitespace: Ignore
  - Comment: Insert as child of Document
  - DOCTYPE: Parse error, ignore
  - <html> start tag: Process using "in body" rules (merge attrs)
  - <head> start tag: Insert head element, switch to "in head"
  - </head>, </body>, </html>, </br>: Act as "anything else"
  - Any other end tag: Parse error, ignore
  - Anything else: Insert implied <head>, switch to "in head", reprocess

  See: https://html.spec.whatwg.org/multipage/parsing.html#the-before-head-insertion-mode
  """

  @behaviour PureHTML.TreeBuilder.InsertionMode

  import PureHTML.TreeBuilder.Helpers, only: [add_child_to_stack: 2, push_element: 3]

  @impl true
  def process({:character, text}, state) do
    case String.trim(text) do
      "" ->
        # Whitespace is ignored
        {:ok, state}

      _ ->
        # Non-whitespace: insert implied head, reprocess
        {:reprocess, insert_head(state, %{})}
    end
  end

  def process({:comment, text}, state) do
    # Insert comment as child of current element
    {:ok, add_child_to_stack(state, {:comment, text})}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:start_tag, "html", _attrs, _self_closing}, state) do
    # Process using "in body" rules - insert implied head first, then reprocess
    {:reprocess, insert_head(state, %{})}
  end

  def process({:start_tag, "head", attrs, _self_closing}, state) do
    # Insert head element with the given attrs and switch to "in head"
    {:ok, insert_head(state, attrs)}
  end

  def process({:end_tag, tag}, state) when tag in ~w(head body html br) do
    # Act as "anything else" - insert implied head and reprocess
    {:reprocess, insert_head(state, %{})}
  end

  def process({:end_tag, _tag}, state) do
    # Parse error, ignore any other end tag
    {:ok, state}
  end

  def process(_token, state) do
    # Anything else: insert implied <head>, switch to "in head", reprocess
    {:reprocess, insert_head(state, %{})}
  end

  # Insert head element, set head_element pointer, and switch to in_head mode
  defp insert_head(state, attrs) do
    state = push_element(state, "head", attrs)
    # Set head_element pointer to the newly created head ref (top of stack)
    %{state | head_element: hd(state.stack), mode: :in_head}
  end
end

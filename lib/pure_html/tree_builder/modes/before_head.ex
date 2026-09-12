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

  import PureHTML.TreeBuilder.Helpers

  # HTML5 ASCII whitespace characters
  @html5_whitespace ~c[ \t\n\r\f]

  @impl true
  # Empty string - all whitespace was consumed
  def process({:character, ""}, state), do: {:ok, state}

  # Leading HTML5 whitespace - strip and reprocess rest
  def process({:character, <<c, rest::binary>>}, state) when c in @html5_whitespace do
    process({:character, rest}, state)
  end

  # Non-whitespace at start - insert head and reprocess
  def process({:character, text}, state) do
    state |> insert_head([]) |> reprocess_with({:character, text})
  end

  def process({:comment, text}, state) do
    # Insert comment as child of current element
    {:ok, add_child_to_stack(state, {:comment, text})}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    state |> parse_error() |> ok()
  end

  def process({:start_tag, "html", _attrs, _self_closing}, state) do
    # Process using "in body" rules - insert implied head first, then reprocess
    state |> insert_head([]) |> reprocess()
  end

  def process({:start_tag, "head", attrs, _self_closing}, state) do
    # Insert head element with the given attrs and switch to "in head"
    state |> insert_head(attrs) |> ok()
  end

  def process({:end_tag, tag}, state) when tag in ~w(head body html br) do
    # Act as "anything else" - insert implied head and reprocess
    state |> insert_head([]) |> reprocess()
  end

  def process({:end_tag, _tag}, state) do
    # Parse error, ignore any other end tag
    state |> parse_error() |> ok()
  end

  def process(_token, state) do
    # Anything else: insert implied <head>, switch to "in head", reprocess
    state |> insert_head([]) |> reprocess()
  end

  # Insert head element, set head_element pointer, and switch to in_head mode
  defp insert_head(state, attrs) do
    state = push_element(state, "head", attrs)
    # Set head_element pointer to the newly created head ref (top of stack)
    %{state | head_element: hd(state.stack), mode: :in_head}
  end
end

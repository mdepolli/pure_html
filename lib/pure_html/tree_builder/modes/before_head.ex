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

  @impl true
  def process({:character, text}, state) do
    case String.trim(text) do
      "" ->
        # Whitespace is ignored
        {:ok, state}

      _ ->
        # Non-whitespace: insert implied head, reprocess
        {:reprocess, %{state | mode: :in_head}}
    end
  end

  def process({:comment, _text}, state) do
    # Comments are inserted as children of the Document
    # This is handled at document level in TreeBuilder.process_token
    {:ok, state}
  end

  def process({:doctype, _name, _public, _system, _force_quirks}, state) do
    # Parse error, ignore
    {:ok, state}
  end

  def process({:start_tag, "html", _attrs, _self_closing}, state) do
    # Process using "in body" rules - let process/2 handle merging attrs
    # Switch mode so we exit this module's scope
    {:reprocess, %{state | mode: :in_head}}
  end

  def process({:start_tag, "head", _attrs, _self_closing}, state) do
    # Insert head element and switch to "in head"
    # Switch mode so process/2 handles the actual insertion
    {:reprocess, %{state | mode: :in_head}}
  end

  def process({:end_tag, tag}, state) when tag in ~w(head body html br) do
    # Act as "anything else" - insert implied head and reprocess
    {:reprocess, %{state | mode: :in_head}}
  end

  def process({:end_tag, _tag}, state) do
    # Parse error, ignore any other end tag
    {:ok, state}
  end

  def process(_token, state) do
    # Anything else: insert implied <head>, switch to "in head", reprocess
    {:reprocess, %{state | mode: :in_head}}
  end
end

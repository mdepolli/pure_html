defmodule PureHTML.Tokenizer do
  @moduledoc """
  HTML5 tokenizer that produces a stream of tokens.

  The tokenizer is implemented as a state machine. Each call to `next_token/1`
  advances the machine until it produces a token, then returns the token and
  the updated state. The tree builder switches the state for raw text, RCDATA,
  script data, and plaintext elements with `set_state/2`, and tells the
  tokenizer whether the adjusted current node is foreign with
  `set_foreign_content/2` (for CDATA sections).

  ## Usage

      iex> PureHTML.Tokenizer.tokenize("<p>Hello</p>") |> Enum.to_list()
      [{:start_tag, "p", [], false}, {:character, "Hello"}, {:end_tag, "p"}]

  ## Token Types

  - `{:doctype, name, public_id, system_id, force_quirks?}`
  - `{:start_tag, name, attrs, self_closing?}`
  - `{:end_tag, name}`
  - `{:comment, data}`
  - `{:character, data}`

  """

  alias PureHTML.Entities

  @type t :: %__MODULE__{}

  @type token ::
          {:doctype, String.t() | nil, String.t() | nil, String.t() | nil, boolean()}
          | {:start_tag, String.t(), [{String.t(), String.t()}], boolean()}
          | {:end_tag, String.t()}
          | {:comment, String.t()}
          | {:character, String.t()}
          | :eof

  # The tokenizer state struct
  defstruct [
    # remaining input as a list of Unicode code points
    :input,
    # current state atom
    :state,
    # state to return to (for character references, etc.)
    :return_state,
    # token being built
    :token,
    # temporary buffer for tag names, etc.
    :buffer,
    # current attribute name being built
    :attr_name,
    # current attribute value being built
    :attr_value,
    # for appropriate end tag checks
    :last_start_tag,
    # pending character data (for coalescing)
    :pending_chars,
    # deferred token (to emit after flushing pending chars)
    :deferred_token,
    # Tree builder feedback: is adjusted current node NOT in HTML namespace?
    # When true, <![CDATA[ is parsed as CDATA section
    # When false (default), <![CDATA[ is treated as bogus comment
    adjusted_current_node_not_in_html_namespace: false,
    # XML infoset coercion mode - applies transformations for XML compatibility
    xml_violation_mode: false,
    # Whether the EOF token has already been emitted
    eof_emitted: false,
    # Parse error count
    error_count: 0,
    # Set while building an end tag that saw attributes; counted once at emit.
    end_tag_has_attributes: false
  ]

  # Guards
  defguardp is_ascii_alpha(c) when c in ?a..?z or c in ?A..?Z
  defguardp is_ascii_lower(c) when c in ?a..?z
  defguardp is_ascii_upper(c) when c in ?A..?Z
  defguardp is_ascii_digit(c) when c in ?0..?9
  defguardp is_ascii_whitespace(c) when c in ~c[\t\n\f ]
  defguardp is_ascii_hex_digit(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F
  defguardp is_surrogate(cp) when cp in 0xD800..0xDFFF
  defguardp is_outside_unicode_range(cp) when cp > 0x10FFFF

  defguardp is_doctype_name(a, b, c, d, e, f, g)
            when :erlang.bor(a, 0x20) == ?d and :erlang.bor(b, 0x20) == ?o and
                   :erlang.bor(c, 0x20) == ?c and :erlang.bor(d, 0x20) == ?t and
                   :erlang.bor(e, 0x20) == ?y and :erlang.bor(f, 0x20) == ?p and
                   :erlang.bor(g, 0x20) == ?e

  defguardp is_public_name(a, b, c, d, e, f)
            when :erlang.bor(a, 0x20) == ?p and :erlang.bor(b, 0x20) == ?u and
                   :erlang.bor(c, 0x20) == ?b and :erlang.bor(d, 0x20) == ?l and
                   :erlang.bor(e, 0x20) == ?i and :erlang.bor(f, 0x20) == ?c

  defguardp is_system_name(a, b, c, d, e, f)
            when :erlang.bor(a, 0x20) == ?s and :erlang.bor(b, 0x20) == ?y and
                   :erlang.bor(c, 0x20) == ?s and :erlang.bor(d, 0x20) == ?t and
                   :erlang.bor(e, 0x20) == ?e and :erlang.bor(f, 0x20) == ?m

  defguardp is_attribute_value_state(state)
            when state in [
                   :attribute_value_double_quoted,
                   :attribute_value_single_quoted,
                   :attribute_value_unquoted
                 ]

  defp parse_error(state), do: %{state | error_count: state.error_count + 1}

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @doc """
  Creates a new tokenizer state from input.

  ## Options

  - `:initial_state` - Starting tokenizer state (default: `:data`)
  - `:last_start_tag` - Last start tag name for appropriate end tag checks
  """
  @spec new(String.t() | [integer()], keyword()) :: t()
  def new(input, opts \\ []) when is_binary(input) or is_list(input) do
    initial_state = Keyword.get(opts, :initial_state, :data)
    last_start_tag = Keyword.get(opts, :last_start_tag, nil)
    xml_violation_mode = Keyword.get(opts, :xml_violation_mode, false)
    {codepoints, preprocess_errors} = decode_input(input)

    %__MODULE__{
      input: codepoints,
      state: initial_state,
      return_state: nil,
      token: nil,
      buffer: "",
      attr_name: "",
      attr_value: "",
      last_start_tag: last_start_tag,
      pending_chars: [],
      deferred_token: nil,
      xml_violation_mode: xml_violation_mode,
      error_count: preprocess_errors
    }
  end

  @doc """
  Tokenizes an HTML string, returning a Stream of tokens.

  The stream is lazy - tokens are produced on demand as the stream is consumed.
  """
  @spec tokenize(String.t() | [integer()], keyword()) :: Enumerable.t()
  def tokenize(input, opts \\ []) when is_binary(input) or is_list(input) do
    input
    |> new(opts)
    |> Stream.unfold(&next_token/1)
    |> Stream.reject(&(&1 == :eof))
  end

  @doc """
  Updates the foreign content context flag.

  When `in_foreign_content` is true, `<![CDATA[` will be parsed as a CDATA section.
  When false (default), it's treated as a bogus comment per HTML5 spec.
  """
  @spec set_foreign_content(t(), boolean()) :: t()
  def set_foreign_content(%__MODULE__{} = tokenizer, in_foreign_content) do
    %{tokenizer | adjusted_current_node_not_in_html_namespace: in_foreign_content}
  end

  @doc """
  Switches the tokenizer state. The tree builder does this for the generic
  raw text and RCDATA element parsing algorithms, script, and plaintext.
  """
  @spec set_state(t(), atom()) :: t()
  def set_state(%__MODULE__{} = tokenizer, state), do: %{tokenizer | state: state}

  # --------------------------------------------------------------------------
  # Token emission
  # --------------------------------------------------------------------------

  @doc """
  Gets the next token from the tokenizer.

  Returns `{token, updated_tokenizer}` or `nil` when done.
  """
  @spec next_token(t()) :: {token(), t()} | nil

  # First, check for a deferred token from previous flush
  def next_token(%__MODULE__{deferred_token: token} = state) when token != nil do
    {token, %{state | deferred_token: nil}}
  end

  # EOF already emitted — signal end of token stream
  def next_token(%__MODULE__{eof_emitted: true}), do: nil

  # States where EOF should flush pending chars and terminate without a parse error.
  # Excludes "less_than_sign" states which have implicit pending '<' to emit via step.
  @eof_flush_states [
    :data,
    :rawtext,
    :rcdata,
    :plaintext,
    :script_data,
    :script_data_escape_start,
    :script_data_escape_start_dash
  ]

  def next_token(%__MODULE__{input: [], state: s} = state)
      when s in @eof_flush_states do
    emit_eof(state)
  end

  def next_token(%__MODULE__{} = state) do
    case step(state) do
      {:emit_char, chars, new_state} ->
        # Accumulate characters instead of emitting immediately
        next_token(%{new_state | pending_chars: [chars | new_state.pending_chars]})

      {:emit, token, new_state} ->
        # Flush pending chars before emitting non-char token
        case new_state.pending_chars do
          [] ->
            {maybe_coerce_token(token, new_state.xml_violation_mode), new_state}

          pending ->
            # Emit chars now, defer the non-char token
            deferred = maybe_coerce_token(token, new_state.xml_violation_mode)

            {flush_pending(pending, new_state.xml_violation_mode),
             %{new_state | pending_chars: [], deferred_token: deferred}}
        end

      {:continue, new_state} ->
        next_token(new_state)

      {:eof_parse_error, new_state} ->
        emit_eof(new_state)

      nil ->
        emit_eof(state)
    end
  end

  defp emit_eof(%__MODULE__{pending_chars: []} = state) do
    {:eof, %{state | eof_emitted: true}}
  end

  defp emit_eof(%__MODULE__{pending_chars: pending} = state) do
    {flush_pending(pending, state.xml_violation_mode),
     %{state | pending_chars: [], deferred_token: :eof, eof_emitted: true}}
  end

  defp flush_pending(pending, xml_violation_mode) do
    chars =
      pending
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    chars = if xml_violation_mode, do: coerce_chars_for_xml(chars), else: chars
    {:character, chars}
  end

  # XML infoset coercion for characters:
  # - U+FFFF (noncharacter) → U+FFFD (replacement character)
  # - U+000C (form feed) → space
  defp coerce_chars_for_xml(chars) do
    chars
    |> String.replace(<<0xFFFF::utf8>>, <<0xFFFD::utf8>>)
    |> String.replace(<<0x000C>>, " ")
  end

  # XML infoset coercion for comments: "--" → "- -"
  defp maybe_coerce_token({:comment, data}, true) do
    {:comment, String.replace(data, "--", "- -")}
  end

  defp maybe_coerce_token(token, _xml_violation_mode), do: token

  # --------------------------------------------------------------------------
  # State machine
  # --------------------------------------------------------------------------

  # Data state - the default state, reading regular content
  defp step(%{state: :data, input: [?< | rest]} = state) do
    continue(state, state: :tag_open, input: rest)
  end

  defp step(%{state: :data, input: [?& | _rest]} = state) do
    continue(state, state: :character_reference, return_state: :data)
  end

  defp step(%{state: :data, input: [0 | rest]} = state) do
    # Null character - parse error, emit as character
    state
    |> parse_error()
    |> emit_char(<<0>>, input: rest)
  end

  defp step(%{state: :data, input: input} = state) when input != [] do
    # Read ahead until we hit <, &, null, or end - emit coalesced characters
    {chars, rest} = chars_until_data(input)
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :data, input: []} = _state) do
    # Handled by next_token/1 - but keeping for completeness
    nil
  end

  # RAWTEXT state - for <style>, <xmp>, etc. No entity decoding.
  defp step(%{state: :rawtext, input: [?< | rest]} = state) do
    continue(state, state: :rawtext_less_than_sign, input: rest)
  end

  defp step(%{state: :rawtext, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :rawtext, input: []} = _state), do: nil

  defp step(%{state: :rawtext, input: input} = state) do
    {chars, rest} = chars_until_rawtext(input)
    emit_char(state, chars, input: rest)
  end

  # PLAINTEXT state - consumes everything until EOF, no end tag recognition
  defp step(%{state: :plaintext, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :plaintext, input: []} = _state), do: nil

  defp step(%{state: :plaintext, input: input} = state) do
    {chars, rest} = chars_until_null(input)
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :rawtext_less_than_sign, input: [?/ | rest]} = state) do
    continue(state, state: :rawtext_end_tag_open, buffer: "", input: rest)
  end

  defp step(%{state: :rawtext_less_than_sign, input: _} = state) do
    emit_char(state, "<", state: :rawtext)
  end

  defp step(%{state: :rawtext_end_tag_open, input: [c | rest]} = state)
       when is_ascii_alpha(c) do
    continue(state,
      state: :rawtext_end_tag_name,
      token: {:end_tag, ""},
      input: [c | rest]
    )
  end

  defp step(%{state: :rawtext_end_tag_open, input: _} = state) do
    emit_char(state, "</", state: :rawtext)
  end

  defp step(%{state: :rawtext_end_tag_name, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    if appropriate_end_tag?(state) do
      continue(state, state: :before_attribute_name, input: rest)
    else
      # Reconsume the whitespace in rawtext state
      emit_end_tag_buffer(state, :rawtext, state.input)
    end
  end

  defp step(%{state: :rawtext_end_tag_name, input: [?/ | rest]} = state) do
    if appropriate_end_tag?(state) do
      continue(state, state: :self_closing_start_tag, input: rest)
    else
      # Reconsume the '/' in rawtext state
      emit_end_tag_buffer(state, :rawtext, state.input)
    end
  end

  defp step(%{state: :rawtext_end_tag_name, input: [?> | rest]} = state) do
    if appropriate_end_tag?(state) do
      emit(state, input: rest)
    else
      # Include the '>' that triggered this - it's not a valid end tag
      emit_char(state, "</" <> state.buffer <> ">", state: :rawtext, token: nil, input: rest)
    end
  end

  defp step(%{state: :rawtext_end_tag_name, input: [c | rest]} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :rawtext_end_tag_name, input: [c | rest]} = state)
       when is_ascii_lower(c) do
    state
    |> append_to_tag_name(<<c>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :rawtext_end_tag_name, input: _} = state) do
    emit_end_tag_buffer(state, :rawtext, state.input)
  end

  # RCDATA state - for <textarea>, <title>. Processes entities.
  defp step(%{state: :rcdata, input: [?< | rest]} = state) do
    continue(state, state: :rcdata_less_than_sign, input: rest)
  end

  defp step(%{state: :rcdata, input: [?& | _rest]} = state) do
    continue(state, state: :character_reference, return_state: :rcdata)
  end

  defp step(%{state: :rcdata, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :rcdata, input: []} = _state), do: nil

  defp step(%{state: :rcdata, input: input} = state) do
    {chars, rest} = chars_until_data(input)
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :rcdata_less_than_sign, input: [?/ | rest]} = state) do
    continue(state, state: :rcdata_end_tag_open, buffer: "", input: rest)
  end

  defp step(%{state: :rcdata_less_than_sign, input: _} = state) do
    emit_char(state, "<", state: :rcdata)
  end

  defp step(%{state: :rcdata_end_tag_open, input: [c | rest]} = state)
       when is_ascii_alpha(c) do
    continue(state,
      state: :rcdata_end_tag_name,
      token: {:end_tag, ""},
      input: [c | rest]
    )
  end

  defp step(%{state: :rcdata_end_tag_open, input: _} = state) do
    emit_char(state, "</", state: :rcdata)
  end

  defp step(%{state: :rcdata_end_tag_name, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    if appropriate_end_tag?(state) do
      continue(state, state: :before_attribute_name, input: rest)
    else
      # Reconsume the whitespace in rcdata state
      emit_end_tag_buffer(state, :rcdata, state.input)
    end
  end

  defp step(%{state: :rcdata_end_tag_name, input: [?/ | rest]} = state) do
    if appropriate_end_tag?(state) do
      continue(state, state: :self_closing_start_tag, input: rest)
    else
      # Reconsume the '/' in rcdata state
      emit_end_tag_buffer(state, :rcdata, state.input)
    end
  end

  defp step(%{state: :rcdata_end_tag_name, input: [?> | rest]} = state) do
    if appropriate_end_tag?(state) do
      emit(state, input: rest)
    else
      # Include the '>' that triggered this - it's not a valid end tag
      emit_char(state, "</" <> state.buffer <> ">", state: :rcdata, token: nil, input: rest)
    end
  end

  defp step(%{state: :rcdata_end_tag_name, input: [c | rest]} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :rcdata_end_tag_name, input: [c | rest]} = state)
       when is_ascii_lower(c) do
    state
    |> append_to_tag_name(<<c>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :rcdata_end_tag_name, input: _} = state) do
    emit_end_tag_buffer(state, :rcdata, state.input)
  end

  # Script data state - for <script>. Similar to RAWTEXT but handles escaped states.
  defp step(%{state: :script_data, input: [?< | rest]} = state) do
    continue(state, state: :script_data_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :script_data, input: []} = _state), do: nil

  defp step(%{state: :script_data, input: input} = state) do
    {chars, rest} = chars_until_rawtext(input)
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :script_data_less_than_sign, input: [?/ | rest]} = state) do
    continue(state, state: :script_data_end_tag_open, buffer: "", input: rest)
  end

  defp step(%{state: :script_data_less_than_sign, input: [?! | rest]} = state) do
    emit_char(state, "<!", state: :script_data_escape_start, input: rest)
  end

  defp step(%{state: :script_data_less_than_sign, input: _} = state) do
    emit_char(state, "<", state: :script_data)
  end

  defp step(%{state: :script_data_end_tag_open, input: [c | rest]} = state)
       when is_ascii_alpha(c) do
    continue(state,
      state: :script_data_end_tag_name,
      token: {:end_tag, ""},
      input: [c | rest]
    )
  end

  defp step(%{state: :script_data_end_tag_open, input: _} = state) do
    emit_char(state, "</", state: :script_data)
  end

  defp step(%{state: :script_data_end_tag_name, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    if appropriate_end_tag?(state) do
      continue(state, state: :before_attribute_name, input: rest)
    else
      # Reconsume the whitespace in script_data state
      emit_end_tag_buffer(state, :script_data, state.input)
    end
  end

  defp step(%{state: :script_data_end_tag_name, input: [?/ | rest]} = state) do
    if appropriate_end_tag?(state) do
      continue(state, state: :self_closing_start_tag, input: rest)
    else
      # Reconsume the '/' in script_data state
      emit_end_tag_buffer(state, :script_data, state.input)
    end
  end

  defp step(%{state: :script_data_end_tag_name, input: [?> | rest]} = state) do
    if appropriate_end_tag?(state) do
      emit(state, input: rest)
    else
      # Include the '>' that triggered this - it's not a valid end tag
      emit_char(state, "</" <> state.buffer <> ">", state: :script_data, token: nil, input: rest)
    end
  end

  defp step(%{state: :script_data_end_tag_name, input: [c | rest]} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :script_data_end_tag_name, input: [c | rest]} = state)
       when is_ascii_lower(c) do
    state
    |> append_to_tag_name(<<c>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :script_data_end_tag_name, input: _} = state) do
    emit_end_tag_buffer(state, :script_data, state.input)
  end

  # Script data escape start
  defp step(%{state: :script_data_escape_start, input: [?- | rest]} = state) do
    emit_char(state, "-", state: :script_data_escape_start_dash, input: rest)
  end

  defp step(%{state: :script_data_escape_start, input: _} = state) do
    continue(state, state: :script_data)
  end

  defp step(%{state: :script_data_escape_start_dash, input: [?- | rest]} = state) do
    emit_char(state, "-", state: :script_data_escaped_dash_dash, input: rest)
  end

  defp step(%{state: :script_data_escape_start_dash, input: _} = state) do
    continue(state, state: :script_data)
  end

  # Script data escaped state
  defp step(%{state: :script_data_escaped, input: [?- | rest]} = state) do
    emit_char(state, "-", state: :script_data_escaped_dash, input: rest)
  end

  defp step(%{state: :script_data_escaped, input: [?< | rest]} = state) do
    continue(state, state: :script_data_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_escaped, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :script_data_escaped, input: []} = state) do
    # eof-in-script-html-comment-like-text parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :script_data_escaped, input: input} = state) do
    {chars, rest} = chars_until_comment(input)
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash, input: [?- | rest]} = state) do
    emit_char(state, "-", state: :script_data_escaped_dash_dash, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash, input: [?< | rest]} = state) do
    continue(state, state: :script_data_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, state: :script_data_escaped, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash, input: []} = state) do
    # eof-in-script-html-comment-like-text parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :script_data_escaped_dash, input: [c | rest]} = state) do
    emit_char(state, codepoint_to_binary(c), state: :script_data_escaped, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: [?- | rest]} = state) do
    emit_char(state, "-", input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: [?< | rest]} = state) do
    continue(state, state: :script_data_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: [?> | rest]} = state) do
    emit_char(state, ">", state: :script_data, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, state: :script_data_escaped, input: rest)
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: []} = state) do
    # eof-in-script-html-comment-like-text parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :script_data_escaped_dash_dash, input: [c | rest]} = state) do
    emit_char(state, codepoint_to_binary(c), state: :script_data_escaped, input: rest)
  end

  defp step(%{state: :script_data_escaped_less_than_sign, input: [?/ | rest]} = state) do
    continue(state, state: :script_data_escaped_end_tag_open, buffer: "", input: rest)
  end

  defp step(%{state: :script_data_escaped_less_than_sign, input: [c | rest]} = state)
       when is_ascii_alpha(c) do
    char = if is_ascii_upper(c), do: <<c + 32>>, else: <<c>>

    emit_char(state, "<" <> char,
      state: :script_data_double_escape_start,
      buffer: char,
      input: rest
    )
  end

  defp step(%{state: :script_data_escaped_less_than_sign, input: _} = state) do
    emit_char(state, "<", state: :script_data_escaped)
  end

  defp step(%{state: :script_data_escaped_end_tag_open, input: [c | rest]} = state)
       when is_ascii_alpha(c) do
    continue(state,
      state: :script_data_escaped_end_tag_name,
      token: {:end_tag, ""},
      input: [c | rest]
    )
  end

  defp step(%{state: :script_data_escaped_end_tag_open, input: _} = state) do
    emit_char(state, "</", state: :script_data_escaped)
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    if appropriate_end_tag?(state) do
      continue(state, state: :before_attribute_name, input: rest)
    else
      # Reconsume the whitespace in script_data_escaped state
      emit_end_tag_buffer(state, :script_data_escaped, state.input)
    end
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: [?/ | rest]} = state) do
    if appropriate_end_tag?(state) do
      continue(state, state: :self_closing_start_tag, input: rest)
    else
      # Reconsume the '/' in script_data_escaped state
      emit_end_tag_buffer(state, :script_data_escaped, state.input)
    end
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: [?> | rest]} = state) do
    if appropriate_end_tag?(state) do
      emit(state, input: rest)
    else
      # Include the '>' that triggered this - it's not a valid end tag
      emit_char(state, "</" <> state.buffer <> ">",
        state: :script_data_escaped,
        token: nil,
        input: rest
      )
    end
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: [c | rest]} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: [c | rest]} = state)
       when is_ascii_lower(c) do
    state
    |> append_to_tag_name(<<c>>)
    |> continue(buffer: state.buffer <> <<c>>, input: rest)
  end

  defp step(%{state: :script_data_escaped_end_tag_name, input: _} = state) do
    emit_end_tag_buffer(state, :script_data_escaped, state.input)
  end

  # Script data double escape start
  defp step(%{state: :script_data_double_escape_start, input: [c | rest]} = state)
       when c in ~c[\t\n\f /] or c == ?> do
    if state.buffer == "script" do
      emit_char(state, <<c>>, state: :script_data_double_escaped, input: rest)
    else
      emit_char(state, <<c>>, state: :script_data_escaped, input: rest)
    end
  end

  defp step(%{state: :script_data_double_escape_start, input: [c | rest]} = state)
       when is_ascii_alpha(c) do
    char = if is_ascii_upper(c), do: <<c + 32>>, else: <<c>>
    emit_char(state, <<c>>, buffer: state.buffer <> char, input: rest)
  end

  defp step(%{state: :script_data_double_escape_start, input: _} = state) do
    continue(state, state: :script_data_escaped)
  end

  # Script data double escaped state
  defp step(%{state: :script_data_double_escaped, input: [?- | rest]} = state) do
    emit_char(state, "-", state: :script_data_double_escaped_dash, input: rest)
  end

  defp step(%{state: :script_data_double_escaped, input: [?< | rest]} = state) do
    emit_char(state, "<", state: :script_data_double_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_double_escaped, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, input: rest)
  end

  defp step(%{state: :script_data_double_escaped, input: []} = state) do
    # eof-in-script-html-comment-like-text parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :script_data_double_escaped, input: input} = state) do
    {chars, rest} = chars_until_comment(input)
    emit_char(state, chars, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash, input: [?- | rest]} = state) do
    emit_char(state, "-", state: :script_data_double_escaped_dash_dash, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash, input: [?< | rest]} = state) do
    emit_char(state, "<", state: :script_data_double_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, state: :script_data_double_escaped, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash, input: []} = state) do
    # eof-in-script-html-comment-like-text parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :script_data_double_escaped_dash, input: [c | rest]} = state) do
    emit_char(state, codepoint_to_binary(c), state: :script_data_double_escaped, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: [?- | rest]} = state) do
    emit_char(state, "-", input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: [?< | rest]} = state) do
    emit_char(state, "<", state: :script_data_double_escaped_less_than_sign, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: [?> | rest]} = state) do
    emit_char(state, ">", state: :script_data, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> emit_char(<<0xFFFD::utf8>>, state: :script_data_double_escaped, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: []} = state) do
    # eof-in-script-html-comment-like-text parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :script_data_double_escaped_dash_dash, input: [c | rest]} = state) do
    emit_char(state, codepoint_to_binary(c), state: :script_data_double_escaped, input: rest)
  end

  defp step(%{state: :script_data_double_escaped_less_than_sign, input: [?/ | rest]} = state) do
    emit_char(state, "/", state: :script_data_double_escape_end, buffer: "", input: rest)
  end

  defp step(%{state: :script_data_double_escaped_less_than_sign, input: _} = state) do
    continue(state, state: :script_data_double_escaped)
  end

  defp step(%{state: :script_data_double_escape_end, input: [c | rest]} = state)
       when c in ~c[\t\n\f /] or c == ?> do
    if state.buffer == "script" do
      emit_char(state, <<c>>, state: :script_data_escaped, input: rest)
    else
      emit_char(state, <<c>>, state: :script_data_double_escaped, input: rest)
    end
  end

  defp step(%{state: :script_data_double_escape_end, input: [c | rest]} = state)
       when is_ascii_alpha(c) do
    char = if is_ascii_upper(c), do: <<c + 32>>, else: <<c>>
    emit_char(state, <<c>>, buffer: state.buffer <> char, input: rest)
  end

  defp step(%{state: :script_data_double_escape_end, input: _} = state) do
    continue(state, state: :script_data_double_escaped)
  end

  # Tag open state - saw '<', determine what kind of tag
  defp step(%{state: :tag_open, input: [?! | rest]} = state) do
    continue(state, state: :markup_declaration_open, input: rest)
  end

  defp step(%{state: :tag_open, input: [?/ | rest]} = state) do
    continue(state, state: :end_tag_open, input: rest)
  end

  defp step(%{state: :tag_open, input: [c | rest]} = state) when is_ascii_alpha(c) do
    continue(state,
      state: :tag_name,
      input: [c | rest],
      token: {:start_tag, "", [], false}
    )
  end

  defp step(%{state: :tag_open, input: [?? | _rest]} = state) do
    # unexpected-question-mark-instead-of-tag-name parse error
    state
    |> parse_error()
    |> continue(state: :bogus_comment, token: {:comment, ""})
  end

  defp step(%{state: :tag_open, input: []} = state) do
    # eof-before-tag-name parse error
    state
    |> parse_error()
    |> emit_char("<", state: :data)
  end

  defp step(%{state: :tag_open, input: _} = state) do
    # invalid-first-character-of-tag-name parse error
    state
    |> parse_error()
    |> emit_char("<", state: :data)
  end

  # End tag open state - saw '</'
  defp step(%{state: :end_tag_open, input: [c | rest]} = state) when is_ascii_alpha(c) do
    continue(state, state: :tag_name, input: [c | rest], token: {:end_tag, ""})
  end

  defp step(%{state: :end_tag_open, input: [?> | rest]} = state) do
    # Missing end tag name - parse error, ignore token
    state
    |> parse_error()
    |> continue(state: :data, input: rest)
  end

  defp step(%{state: :end_tag_open, input: []} = state) do
    # eof-before-tag-name parse error
    state
    |> parse_error()
    |> emit_char("</", state: :data)
  end

  defp step(%{state: :end_tag_open, input: _} = state) do
    # invalid-first-character-of-tag-name parse error
    state
    |> parse_error()
    |> continue(state: :bogus_comment, token: {:comment, ""})
  end

  # Tag name state - reading the tag name
  defp step(%{state: :tag_name, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest, state: :before_attribute_name)
  end

  defp step(%{state: :tag_name, input: [?/ | rest]} = state) do
    continue(state, input: rest, state: :self_closing_start_tag)
  end

  defp step(%{state: :tag_name, input: [?> | rest]} = state) do
    state
    |> maybe_update_last_start_tag()
    |> emit(input: rest)
  end

  defp step(%{state: :tag_name, input: [c | rest]} = state) when is_ascii_upper(c) do
    # Uppercase - lowercase it
    state
    |> append_to_tag_name(<<c + 32>>)
    |> continue(input: rest)
  end

  defp step(%{state: :tag_name, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_tag_name(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :tag_name, input: []} = state) do
    # EOF in tag - discard the incomplete tag (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :tag_name, input: [c | rest]} = state) do
    state
    |> append_to_tag_name(codepoint_to_binary(c))
    |> continue(input: rest)
  end

  # Before attribute name state
  defp step(%{state: :before_attribute_name, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_attribute_name, input: [c | _]} = state)
       when c in ~c[/>] do
    continue(state, state: :after_attribute_name)
  end

  defp step(%{state: :before_attribute_name, input: []} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :before_attribute_name, input: [?= | rest]} = state) do
    # unexpected-equals-sign-before-attribute-name parse error
    state
    |> parse_error()
    |> start_new_attribute("=")
    |> continue(state: :attribute_name, input: rest)
  end

  defp step(%{state: :before_attribute_name, input: _} = state) do
    state
    |> start_new_attribute("")
    |> continue(state: :attribute_name)
  end

  # Attribute name state
  defp step(%{state: :attribute_name, input: [c | _]} = state)
       when c in ~c[\t\n\f />] do
    state
    |> finalize_attribute_name()
    |> continue(state: :after_attribute_name)
  end

  defp step(%{state: :attribute_name, input: []} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :attribute_name, input: [?= | rest]} = state) do
    state
    |> finalize_attribute_name()
    |> continue(state: :before_attribute_value, input: rest)
  end

  defp step(%{state: :attribute_name, input: [c | rest]} = state)
       when is_ascii_upper(c) do
    continue(state, input: rest, buffer: state.buffer <> <<c + 32>>)
  end

  defp step(%{state: :attribute_name, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> continue(input: rest, buffer: state.buffer <> <<0xFFFD::utf8>>)
  end

  defp step(%{state: :attribute_name, input: [c | rest]} = state)
       when c in [?", ?', ?<] do
    # unexpected-character-in-attribute-name parse error
    state
    |> parse_error()
    |> continue(input: rest, buffer: state.buffer <> <<c>>)
  end

  defp step(%{state: :attribute_name, input: [c | rest]} = state) do
    continue(state, input: rest, buffer: state.buffer <> codepoint_to_binary(c))
  end

  # After attribute name state
  defp step(%{state: :after_attribute_name, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :after_attribute_name, input: [?/ | rest]} = state) do
    state
    |> finalize_attribute_value()
    |> continue(state: :self_closing_start_tag, input: rest)
  end

  defp step(%{state: :after_attribute_name, input: [?= | rest]} = state) do
    continue(state, state: :before_attribute_value, input: rest)
  end

  defp step(%{state: :after_attribute_name, input: [?> | rest]} = state) do
    state
    |> finalize_attribute_value()
    |> maybe_update_last_start_tag()
    |> maybe_end_tag_with_attributes()
    |> emit(input: rest)
  end

  defp step(%{state: :after_attribute_name, input: []} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :after_attribute_name, input: _} = state) do
    state
    |> finalize_attribute_value()
    |> start_new_attribute("")
    |> continue(state: :attribute_name)
  end

  # Before attribute value state
  defp step(%{state: :before_attribute_value, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_attribute_value, input: [?" | rest]} = state) do
    continue(state, state: :attribute_value_double_quoted, input: rest)
  end

  defp step(%{state: :before_attribute_value, input: [?' | rest]} = state) do
    continue(state, state: :attribute_value_single_quoted, input: rest)
  end

  defp step(%{state: :before_attribute_value, input: [?> | rest]} = state) do
    # missing-attribute-value parse error
    state
    |> parse_error()
    |> finalize_attribute_value()
    |> maybe_update_last_start_tag()
    |> maybe_end_tag_with_attributes()
    |> emit(input: rest)
  end

  defp step(%{state: :before_attribute_value, input: []} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :before_attribute_value, input: _} = state) do
    continue(state, state: :attribute_value_unquoted)
  end

  # Attribute value (double-quoted) state
  defp step(%{state: :attribute_value_double_quoted, input: [?" | rest]} = state) do
    state
    |> finalize_attribute_value()
    |> continue(state: :after_attribute_value_quoted, input: rest)
  end

  defp step(%{state: :attribute_value_double_quoted, input: [?& | _]} = state) do
    continue(state, state: :character_reference, return_state: :attribute_value_double_quoted)
  end

  defp step(%{state: :attribute_value_double_quoted, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> continue(input: rest, attr_value: state.attr_value <> <<0xFFFD::utf8>>)
  end

  defp step(%{state: :attribute_value_double_quoted, input: []} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :attribute_value_double_quoted, input: [c | rest]} = state) do
    continue(state, input: rest, attr_value: state.attr_value <> codepoint_to_binary(c))
  end

  # Attribute value (single-quoted) state
  defp step(%{state: :attribute_value_single_quoted, input: [?' | rest]} = state) do
    state
    |> finalize_attribute_value()
    |> continue(state: :after_attribute_value_quoted, input: rest)
  end

  defp step(%{state: :attribute_value_single_quoted, input: [?& | _]} = state) do
    continue(state, state: :character_reference, return_state: :attribute_value_single_quoted)
  end

  defp step(%{state: :attribute_value_single_quoted, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> continue(input: rest, attr_value: state.attr_value <> <<0xFFFD::utf8>>)
  end

  defp step(%{state: :attribute_value_single_quoted, input: []} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :attribute_value_single_quoted, input: [c | rest]} = state) do
    continue(state, input: rest, attr_value: state.attr_value <> codepoint_to_binary(c))
  end

  # Attribute value (unquoted) state
  defp step(%{state: :attribute_value_unquoted, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    state
    |> finalize_attribute_value()
    |> continue(state: :before_attribute_name, input: rest)
  end

  defp step(%{state: :attribute_value_unquoted, input: [?& | _]} = state) do
    continue(state, state: :character_reference, return_state: :attribute_value_unquoted)
  end

  defp step(%{state: :attribute_value_unquoted, input: [?> | rest]} = state) do
    state
    |> finalize_attribute_value()
    |> maybe_update_last_start_tag()
    |> maybe_end_tag_with_attributes()
    |> emit(input: rest)
  end

  defp step(%{state: :attribute_value_unquoted, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> continue(input: rest, attr_value: state.attr_value <> <<0xFFFD::utf8>>)
  end

  defp step(%{state: :attribute_value_unquoted, input: []} = state) do
    # EOF in tag - discard (parse error)
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :attribute_value_unquoted, input: [c | rest]} = state)
       when c in [?", ?', ?<, ?`] do
    # unexpected-character-in-unquoted-attribute-value parse error
    state
    |> parse_error()
    |> continue(input: rest, attr_value: state.attr_value <> <<c>>)
  end

  defp step(%{state: :attribute_value_unquoted, input: [c | rest]} = state) do
    continue(state, input: rest, attr_value: state.attr_value <> codepoint_to_binary(c))
  end

  # After attribute value (quoted) state
  defp step(%{state: :after_attribute_value_quoted, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, state: :before_attribute_name, input: rest)
  end

  defp step(%{state: :after_attribute_value_quoted, input: [?/ | rest]} = state) do
    continue(state, state: :self_closing_start_tag, input: rest)
  end

  defp step(%{state: :after_attribute_value_quoted, input: [?> | rest]} = state) do
    state
    |> maybe_update_last_start_tag()
    |> maybe_end_tag_with_attributes()
    |> emit(input: rest)
  end

  defp step(%{state: :after_attribute_value_quoted, input: []} = state) do
    # eof-in-tag parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :after_attribute_value_quoted, input: _} = state) do
    # missing-whitespace-between-attributes parse error
    state
    |> parse_error()
    |> continue(state: :before_attribute_name)
  end

  # Self-closing start tag state
  defp step(
         %{state: :self_closing_start_tag, input: [?> | rest], token: {:end_tag, _}} =
           state
       ) do
    # end-tag-with-trailing-solidus parse error
    state
    |> parse_error()
    |> maybe_end_tag_with_attributes()
    |> emit(input: rest)
  end

  defp step(%{state: :self_closing_start_tag, input: [?> | rest]} = state) do
    state
    |> set_self_closing()
    |> maybe_update_last_start_tag()
    |> emit(input: rest)
  end

  defp step(%{state: :self_closing_start_tag, input: []} = state) do
    # eof-in-tag parse error
    {:eof_parse_error, parse_error(state)}
  end

  defp step(%{state: :self_closing_start_tag, input: _} = state) do
    # unexpected-solidus-in-tag parse error
    state
    |> parse_error()
    |> continue(state: :before_attribute_name)
  end

  # Markup declaration open state - after '<!'
  defp step(%{state: :markup_declaration_open, input: [?-, ?- | rest]} = state) do
    continue(state, state: :comment_start, input: rest, token: {:comment, ""})
  end

  defp step(
         %{state: :markup_declaration_open, input: [d0, d1, d2, d3, d4, d5, d6 | rest]} = state
       )
       when is_doctype_name(d0, d1, d2, d3, d4, d5, d6) do
    continue(state, state: :doctype, input: rest)
  end

  # CDATA section - only recognized in foreign content (SVG/MathML)
  defp step(
         %{
           state: :markup_declaration_open,
           input: [?[, ?C, ?D, ?A, ?T, ?A, ?[ | rest],
           adjusted_current_node_not_in_html_namespace: true
         } = state
       ) do
    continue(state, state: :cdata_section, input: rest, buffer: "")
  end

  # CDATA in HTML content - treat as bogus comment
  defp step(
         %{
           state: :markup_declaration_open,
           input: [?[, ?C, ?D, ?A, ?T, ?A, ?[ | rest],
           adjusted_current_node_not_in_html_namespace: false
         } = state
       ) do
    # Parse error: cdata-in-html-content
    state
    |> parse_error()
    |> continue(state: :bogus_comment, input: rest, token: {:comment, "[CDATA["})
  end

  defp step(%{state: :markup_declaration_open, input: _} = state) do
    # incorrectly-opened-comment parse error
    state
    |> parse_error()
    |> continue(state: :bogus_comment, token: {:comment, ""})
  end

  # Comment start state
  defp step(%{state: :comment_start, input: [?- | rest]} = state) do
    continue(state, state: :comment_start_dash, input: rest)
  end

  defp step(%{state: :comment_start, input: [?> | rest]} = state) do
    # abrupt-closing-of-empty-comment parse error
    state
    |> parse_error()
    |> emit(input: rest)
  end

  defp step(%{state: :comment_start, input: _} = state) do
    continue(state, state: :comment)
  end

  # Comment start dash state
  defp step(%{state: :comment_start_dash, input: [?- | rest]} = state) do
    continue(state, state: :comment_end, input: rest)
  end

  defp step(%{state: :comment_start_dash, input: [?> | rest]} = state) do
    # abrupt-closing-of-empty-comment parse error
    state
    |> parse_error()
    |> emit(input: rest)
  end

  defp step(%{state: :comment_start_dash, input: []} = state) do
    # eof-in-comment parse error
    state
    |> parse_error()
    |> emit()
  end

  defp step(%{state: :comment_start_dash, input: _} = state) do
    state
    |> append_to_comment("-")
    |> continue(state: :comment)
  end

  # Comment state
  defp step(%{state: :comment, input: [?< | rest]} = state) do
    state
    |> append_to_comment("<")
    |> continue(state: :comment_less_than_sign, input: rest)
  end

  defp step(%{state: :comment, input: [?- | rest]} = state) do
    continue(state, state: :comment_end_dash, input: rest)
  end

  defp step(%{state: :comment, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_comment(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :comment, input: []} = state) do
    # eof-in-comment parse error
    state
    |> parse_error()
    |> emit()
  end

  defp step(%{state: :comment, input: [c | rest]} = state) do
    state
    |> append_to_comment(codepoint_to_binary(c))
    |> continue(input: rest)
  end

  # Comment less-than sign state
  defp step(%{state: :comment_less_than_sign, input: [?! | rest]} = state) do
    state
    |> append_to_comment("!")
    |> continue(state: :comment_less_than_sign_bang, input: rest)
  end

  defp step(%{state: :comment_less_than_sign, input: [?< | rest]} = state) do
    state
    |> append_to_comment("<")
    |> continue(input: rest)
  end

  defp step(%{state: :comment_less_than_sign, input: _} = state) do
    continue(state, state: :comment)
  end

  # Comment less-than sign bang state
  defp step(%{state: :comment_less_than_sign_bang, input: [?- | rest]} = state) do
    continue(state, state: :comment_less_than_sign_bang_dash, input: rest)
  end

  defp step(%{state: :comment_less_than_sign_bang, input: _} = state) do
    continue(state, state: :comment)
  end

  # Comment less-than sign bang dash state
  defp step(%{state: :comment_less_than_sign_bang_dash, input: [?- | rest]} = state) do
    continue(state, state: :comment_less_than_sign_bang_dash_dash, input: rest)
  end

  defp step(%{state: :comment_less_than_sign_bang_dash, input: _} = state) do
    continue(state, state: :comment_end_dash)
  end

  # Comment less-than sign bang dash dash state
  defp step(%{state: :comment_less_than_sign_bang_dash_dash, input: [?> | _]} = state) do
    continue(state, state: :comment_end)
  end

  defp step(%{state: :comment_less_than_sign_bang_dash_dash, input: []} = state) do
    continue(state, state: :comment_end)
  end

  defp step(%{state: :comment_less_than_sign_bang_dash_dash, input: _} = state) do
    # Nested comment - parse error
    state
    |> parse_error()
    |> continue(state: :comment_end)
  end

  # Comment end dash state
  defp step(%{state: :comment_end_dash, input: [?- | rest]} = state) do
    continue(state, state: :comment_end, input: rest)
  end

  defp step(%{state: :comment_end_dash, input: []} = state) do
    # eof-in-comment parse error
    state
    |> parse_error()
    |> emit()
  end

  defp step(%{state: :comment_end_dash, input: _} = state) do
    state
    |> append_to_comment("-")
    |> continue(state: :comment)
  end

  # Comment end state
  defp step(%{state: :comment_end, input: [?> | rest]} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :comment_end, input: [?! | rest]} = state) do
    continue(state, state: :comment_end_bang, input: rest)
  end

  defp step(%{state: :comment_end, input: [?- | rest]} = state) do
    state
    |> append_to_comment("-")
    |> continue(input: rest)
  end

  defp step(%{state: :comment_end, input: []} = state) do
    # eof-in-comment parse error
    state
    |> parse_error()
    |> emit()
  end

  defp step(%{state: :comment_end, input: _} = state) do
    state
    |> append_to_comment("--")
    |> continue(state: :comment)
  end

  # Comment end bang state
  defp step(%{state: :comment_end_bang, input: [?- | rest]} = state) do
    state
    |> append_to_comment("--!")
    |> continue(state: :comment_end_dash, input: rest)
  end

  defp step(%{state: :comment_end_bang, input: [?> | rest]} = state) do
    # incorrectly-closed-comment parse error
    state
    |> parse_error()
    |> emit(input: rest)
  end

  defp step(%{state: :comment_end_bang, input: []} = state) do
    # eof-in-comment parse error
    state
    |> parse_error()
    |> emit()
  end

  defp step(%{state: :comment_end_bang, input: _} = state) do
    state
    |> append_to_comment("--!")
    |> continue(state: :comment)
  end

  # DOCTYPE state
  defp step(%{state: :doctype, input: [c | rest]} = state) when is_ascii_whitespace(c) do
    continue(state, state: :before_doctype_name, input: rest)
  end

  defp step(%{state: :doctype, input: [?> | _]} = state) do
    continue(state, state: :before_doctype_name)
  end

  defp step(%{state: :doctype, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> then(&emit(%{&1 | token: {:doctype, nil, nil, nil, true}}, []))
  end

  defp step(%{state: :doctype, input: _} = state) do
    # missing-whitespace-before-doctype-name parse error
    state
    |> parse_error()
    |> continue(state: :before_doctype_name)
  end

  # Before DOCTYPE name state
  defp step(%{state: :before_doctype_name, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_doctype_name, input: [c | rest]} = state)
       when is_ascii_upper(c) do
    continue(state,
      state: :doctype_name,
      input: rest,
      token: {:doctype, <<c + 32>>, nil, nil, false}
    )
  end

  defp step(%{state: :before_doctype_name, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> continue(
      state: :doctype_name,
      input: rest,
      token: {:doctype, <<0xFFFD::utf8>>, nil, nil, false}
    )
  end

  defp step(%{state: :before_doctype_name, input: [?> | rest]} = state) do
    # missing-doctype-name parse error
    state
    |> parse_error()
    |> then(&emit(%{&1 | token: {:doctype, nil, nil, nil, true}}, input: rest))
  end

  defp step(%{state: :before_doctype_name, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> then(&emit(%{&1 | token: {:doctype, nil, nil, nil, true}}, []))
  end

  defp step(%{state: :before_doctype_name, input: [c | rest]} = state) do
    continue(state,
      state: :doctype_name,
      input: rest,
      token: {:doctype, codepoint_to_binary(c), nil, nil, false}
    )
  end

  # DOCTYPE name state
  defp step(%{state: :doctype_name, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest, state: :after_doctype_name)
  end

  defp step(%{state: :doctype_name, input: [?> | rest]} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :doctype_name, input: [c | rest]} = state)
       when is_ascii_upper(c) do
    state
    |> append_to_doctype_name(<<c + 32>>)
    |> continue(input: rest)
  end

  defp step(%{state: :doctype_name, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_doctype_name(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :doctype_name, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :doctype_name, input: [c | rest]} = state) do
    state
    |> append_to_doctype_name(codepoint_to_binary(c))
    |> continue(input: rest)
  end

  # After DOCTYPE name state
  defp step(%{state: :after_doctype_name, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :after_doctype_name, input: [?> | rest]} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :after_doctype_name, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :after_doctype_name, input: [k0, k1, k2, k3, k4, k5 | rest]} = state)
       when is_public_name(k0, k1, k2, k3, k4, k5) do
    continue(state, state: :after_doctype_public_keyword, input: rest)
  end

  defp step(%{state: :after_doctype_name, input: [k0, k1, k2, k3, k4, k5 | rest]} = state)
       when is_system_name(k0, k1, k2, k3, k4, k5) do
    continue(state, state: :after_doctype_system_keyword, input: rest)
  end

  defp step(%{state: :after_doctype_name, input: _} = state) do
    # invalid-character-sequence-after-doctype-name parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # After DOCTYPE public keyword state
  defp step(%{state: :after_doctype_public_keyword, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, state: :before_doctype_public_identifier, input: rest)
  end

  defp step(%{state: :after_doctype_public_keyword, input: [?" | rest]} = state) do
    # missing-whitespace-after-doctype-public-keyword parse error
    state
    |> parse_error()
    |> set_doctype_public_id("")
    |> continue(state: :doctype_public_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_public_keyword, input: [?' | rest]} = state) do
    # missing-whitespace-after-doctype-public-keyword parse error
    state
    |> parse_error()
    |> set_doctype_public_id("")
    |> continue(state: :doctype_public_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_public_keyword, input: [?> | rest]} = state) do
    # missing-doctype-public-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :after_doctype_public_keyword, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :after_doctype_public_keyword, input: _} = state) do
    # missing-quote-before-doctype-public-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # Before DOCTYPE public identifier state
  defp step(%{state: :before_doctype_public_identifier, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_doctype_public_identifier, input: [?" | rest]} = state) do
    state
    |> set_doctype_public_id("")
    |> continue(state: :doctype_public_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :before_doctype_public_identifier, input: [?' | rest]} = state) do
    state
    |> set_doctype_public_id("")
    |> continue(state: :doctype_public_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :before_doctype_public_identifier, input: [?> | rest]} = state) do
    # missing-doctype-public-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :before_doctype_public_identifier, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :before_doctype_public_identifier, input: _} = state) do
    # missing-quote-before-doctype-public-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # DOCTYPE public identifier (double-quoted) state
  defp step(%{state: :doctype_public_identifier_double_quoted, input: [?" | rest]} = state) do
    continue(state, state: :after_doctype_public_identifier, input: rest)
  end

  defp step(%{state: :doctype_public_identifier_double_quoted, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_doctype_public_id(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :doctype_public_identifier_double_quoted, input: [?> | rest]} = state) do
    # abrupt-doctype-public-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :doctype_public_identifier_double_quoted, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(
         %{state: :doctype_public_identifier_double_quoted, input: [c | rest]} =
           state
       ) do
    state
    |> append_to_doctype_public_id(codepoint_to_binary(c))
    |> continue(input: rest)
  end

  # DOCTYPE public identifier (single-quoted) state
  defp step(%{state: :doctype_public_identifier_single_quoted, input: [?' | rest]} = state) do
    continue(state, state: :after_doctype_public_identifier, input: rest)
  end

  defp step(%{state: :doctype_public_identifier_single_quoted, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_doctype_public_id(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :doctype_public_identifier_single_quoted, input: [?> | rest]} = state) do
    # abrupt-doctype-public-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :doctype_public_identifier_single_quoted, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(
         %{state: :doctype_public_identifier_single_quoted, input: [c | rest]} =
           state
       ) do
    state
    |> append_to_doctype_public_id(codepoint_to_binary(c))
    |> continue(input: rest)
  end

  # After DOCTYPE public identifier state
  defp step(%{state: :after_doctype_public_identifier, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, state: :between_doctype_public_and_system_identifiers, input: rest)
  end

  defp step(%{state: :after_doctype_public_identifier, input: [?> | rest]} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :after_doctype_public_identifier, input: [?" | rest]} = state) do
    # missing-whitespace-between-doctype-public-and-system-identifiers parse error
    state
    |> parse_error()
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_public_identifier, input: [?' | rest]} = state) do
    # missing-whitespace-between-doctype-public-and-system-identifiers parse error
    state
    |> parse_error()
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_public_identifier, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :after_doctype_public_identifier, input: _} = state) do
    # missing-quote-before-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # Between DOCTYPE public and system identifiers state
  defp step(
         %{state: :between_doctype_public_and_system_identifiers, input: [c | rest]} =
           state
       )
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(
         %{state: :between_doctype_public_and_system_identifiers, input: [?> | rest]} =
           state
       ) do
    emit(state, input: rest)
  end

  defp step(
         %{state: :between_doctype_public_and_system_identifiers, input: [?" | rest]} =
           state
       ) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_double_quoted, input: rest)
  end

  defp step(
         %{state: :between_doctype_public_and_system_identifiers, input: [?' | rest]} =
           state
       ) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :between_doctype_public_and_system_identifiers, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :between_doctype_public_and_system_identifiers, input: _} = state) do
    # missing-quote-before-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # After DOCTYPE system keyword state
  defp step(%{state: :after_doctype_system_keyword, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, state: :before_doctype_system_identifier, input: rest)
  end

  defp step(%{state: :after_doctype_system_keyword, input: [?" | rest]} = state) do
    # missing-whitespace-after-doctype-system-keyword parse error
    state
    |> parse_error()
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_system_keyword, input: [?' | rest]} = state) do
    # missing-whitespace-after-doctype-system-keyword parse error
    state
    |> parse_error()
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :after_doctype_system_keyword, input: [?> | rest]} = state) do
    # missing-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :after_doctype_system_keyword, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :after_doctype_system_keyword, input: _} = state) do
    # missing-quote-before-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # Before DOCTYPE system identifier state
  defp step(%{state: :before_doctype_system_identifier, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :before_doctype_system_identifier, input: [?" | rest]} = state) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_double_quoted, input: rest)
  end

  defp step(%{state: :before_doctype_system_identifier, input: [?' | rest]} = state) do
    state
    |> set_doctype_system_id("")
    |> continue(state: :doctype_system_identifier_single_quoted, input: rest)
  end

  defp step(%{state: :before_doctype_system_identifier, input: [?> | rest]} = state) do
    # missing-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :before_doctype_system_identifier, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :before_doctype_system_identifier, input: _} = state) do
    # missing-quote-before-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> continue(state: :bogus_doctype)
  end

  # DOCTYPE system identifier (double-quoted) state
  defp step(%{state: :doctype_system_identifier_double_quoted, input: [?" | rest]} = state) do
    continue(state, state: :after_doctype_system_identifier, input: rest)
  end

  defp step(%{state: :doctype_system_identifier_double_quoted, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_doctype_system_id(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :doctype_system_identifier_double_quoted, input: [?> | rest]} = state) do
    # abrupt-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :doctype_system_identifier_double_quoted, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(
         %{state: :doctype_system_identifier_double_quoted, input: [c | rest]} =
           state
       ) do
    state
    |> append_to_doctype_system_id(codepoint_to_binary(c))
    |> continue(input: rest)
  end

  # DOCTYPE system identifier (single-quoted) state
  defp step(%{state: :doctype_system_identifier_single_quoted, input: [?' | rest]} = state) do
    continue(state, state: :after_doctype_system_identifier, input: rest)
  end

  defp step(%{state: :doctype_system_identifier_single_quoted, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_doctype_system_id(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :doctype_system_identifier_single_quoted, input: [?> | rest]} = state) do
    # abrupt-doctype-system-identifier parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit(input: rest)
  end

  defp step(%{state: :doctype_system_identifier_single_quoted, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(
         %{state: :doctype_system_identifier_single_quoted, input: [c | rest]} =
           state
       ) do
    state
    |> append_to_doctype_system_id(codepoint_to_binary(c))
    |> continue(input: rest)
  end

  # After DOCTYPE system identifier state
  defp step(%{state: :after_doctype_system_identifier, input: [c | rest]} = state)
       when is_ascii_whitespace(c) do
    continue(state, input: rest)
  end

  defp step(%{state: :after_doctype_system_identifier, input: [?> | rest]} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :after_doctype_system_identifier, input: []} = state) do
    # eof-in-doctype parse error
    state
    |> parse_error()
    |> set_force_quirks()
    |> emit()
  end

  defp step(%{state: :after_doctype_system_identifier, input: _} = state) do
    # unexpected-character-after-doctype-system-identifier parse error
    state
    |> parse_error()
    |> continue(state: :bogus_doctype)
  end

  # Bogus comment state
  defp step(%{state: :bogus_comment, input: [?> | rest]} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :bogus_comment, input: []} = state) do
    emit(state)
  end

  defp step(%{state: :bogus_comment, input: [0 | rest]} = state) do
    # unexpected-null-character parse error
    state
    |> parse_error()
    |> append_to_comment(<<0xFFFD::utf8>>)
    |> continue(input: rest)
  end

  defp step(%{state: :bogus_comment, input: [c | rest]} = state) do
    state
    |> append_to_comment(codepoint_to_binary(c))
    |> continue(input: rest)
  end

  # Bogus DOCTYPE state
  defp step(%{state: :bogus_doctype, input: [?> | rest]} = state) do
    emit(state, input: rest)
  end

  defp step(%{state: :bogus_doctype, input: []} = state) do
    emit(state)
  end

  defp step(%{state: :bogus_doctype, input: [_ | rest]} = state) do
    continue(state, input: rest)
  end

  # CDATA section state - consume content until ]]>
  defp step(%{state: :cdata_section, input: [?], ?], ?> | rest], buffer: ""} = state) do
    # Empty CDATA - don't emit anything, just continue
    continue(state, state: :data, input: rest)
  end

  defp step(%{state: :cdata_section, input: [?], ?], ?> | rest]} = state) do
    # End of CDATA - emit accumulated content as character token
    emit_char(state, state.buffer, state: :data, input: rest, buffer: "")
  end

  defp step(%{state: :cdata_section, input: [?] | rest]} = state) do
    continue(state, state: :cdata_section_bracket, input: rest)
  end

  defp step(%{state: :cdata_section, input: [], buffer: ""} = state) do
    # eof-in-cdata parse error
    state
    |> parse_error()
    |> continue(state: :data)
  end

  defp step(%{state: :cdata_section, input: []} = state) do
    # eof-in-cdata parse error
    state
    |> parse_error()
    |> emit_char(state.buffer, state: :data, buffer: "")
  end

  defp step(%{state: :cdata_section, input: [0 | rest]} = state) do
    # NUL in CDATA - pass through unchanged (unlike other states)
    continue(state, input: rest, buffer: state.buffer <> <<0>>)
  end

  defp step(%{state: :cdata_section, input: input} = state) do
    # Consume characters until ] or NUL or end
    {chars, rest} = chars_until_cdata(input)
    continue(state, input: rest, buffer: state.buffer <> chars)
  end

  defp step(%{state: :cdata_section_bracket, input: [?] | rest]} = state) do
    continue(state, state: :cdata_section_end, input: rest)
  end

  defp step(%{state: :cdata_section_bracket, input: _} = state) do
    # Not ]], add the ] to buffer and continue
    continue(state, state: :cdata_section, buffer: state.buffer <> "]")
  end

  defp step(%{state: :cdata_section_end, input: [?] | rest]} = state) do
    # Additional ] - keep accumulating
    continue(state, input: rest, buffer: state.buffer <> "]")
  end

  defp step(%{state: :cdata_section_end, input: [?> | rest], buffer: ""} = state) do
    # ]]> found with empty content - don't emit anything
    continue(state, state: :data, input: rest)
  end

  defp step(%{state: :cdata_section_end, input: [?> | rest]} = state) do
    # ]]> found - emit content
    emit_char(state, state.buffer, state: :data, input: rest, buffer: "")
  end

  defp step(%{state: :cdata_section_end, input: _} = state) do
    # Not ]]>, add ]] to buffer and continue
    continue(state, state: :cdata_section, buffer: state.buffer <> "]]")
  end

  # Character reference state - handles &entities;
  defp step(%{state: :character_reference, input: [?&, ?# | rest]} = state) do
    continue(state, input: rest, buffer: "", state: :numeric_character_reference)
  end

  defp step(%{state: :character_reference, input: [?&, next | _] = input} = state)
       when is_ascii_alpha(next) or is_ascii_digit(next) do
    case lookup_named_entity(input) do
      {chars, rest} ->
        consume_named_entity(state, input, chars, rest)

      nil ->
        [_amp | after_amp] = input

        state
        |> ambiguous_ampersand_error(after_amp)
        |> flush_char_ref("&", after_amp)
    end
  end

  defp step(%{state: :character_reference, input: [?& | rest]} = state) do
    flush_char_ref(state, "&", rest)
  end

  # Numeric character reference state
  defp step(%{state: :numeric_character_reference, input: [c | rest]} = state)
       when c in ~c[xX] do
    # Store the x/X in buffer to preserve case if we need to emit it as text
    continue(state, input: rest, buffer: <<c>>, state: :hexadecimal_character_reference_start)
  end

  defp step(%{state: :numeric_character_reference, input: _} = state) do
    continue(state, buffer: "", state: :decimal_character_reference_start)
  end

  # Decimal character reference start
  defp step(%{state: :decimal_character_reference_start, input: [c | _]} = state)
       when is_ascii_digit(c) do
    continue(state, state: :decimal_character_reference)
  end

  defp step(%{state: :decimal_character_reference_start, input: _} = state) do
    # absence-of-digits-in-numeric-character-reference parse error
    state
    |> parse_error()
    |> emit_failed_char_ref("&#")
  end

  # Decimal character reference
  defp step(%{state: :decimal_character_reference, input: [c | rest]} = state)
       when is_ascii_digit(c) do
    continue(state, input: rest, buffer: state.buffer <> <<c>>)
  end

  defp step(%{state: :decimal_character_reference, input: [?; | rest]} = state) do
    finish_numeric_char_ref(state, rest, 10)
  end

  defp step(%{state: :decimal_character_reference, input: _} = state) do
    # missing-semicolon-after-character-reference parse error
    state
    |> parse_error()
    |> finish_numeric_char_ref(state.input, 10)
  end

  # Hexadecimal character reference start
  defp step(%{state: :hexadecimal_character_reference_start, input: [c | _]} = state)
       when is_ascii_hex_digit(c) do
    # Clear the x/X from buffer, start collecting digits
    continue(state, buffer: "", state: :hexadecimal_character_reference)
  end

  defp step(%{state: :hexadecimal_character_reference_start, input: _} = state) do
    # absence-of-digits-in-numeric-character-reference parse error
    state
    |> parse_error()
    |> emit_failed_char_ref("&#" <> state.buffer)
  end

  # Hexadecimal character reference
  defp step(%{state: :hexadecimal_character_reference, input: [c | rest]} = state)
       when is_ascii_hex_digit(c) do
    continue(state, input: rest, buffer: state.buffer <> <<c>>)
  end

  defp step(%{state: :hexadecimal_character_reference, input: [?; | rest]} = state) do
    finish_numeric_char_ref(state, rest, 16)
  end

  defp step(%{state: :hexadecimal_character_reference, input: _} = state) do
    # missing-semicolon-after-character-reference parse error
    state
    |> parse_error()
    |> finish_numeric_char_ref(state.input, 16)
  end

  defp emit_failed_char_ref(state, prefix) do
    case state.return_state do
      return_state when is_attribute_value_state(return_state) ->
        continue(state,
          attr_value: state.attr_value <> prefix,
          state: state.return_state,
          return_state: nil
        )

      return_state ->
        emit_char(state, prefix, state: return_state, return_state: nil)
    end
  end

  # Windows-1252 replacements for 0x80-0x9F per HTML5 spec
  @windows_1252 %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  defp finish_numeric_char_ref(state, rest, base) do
    codepoint = String.to_integer(state.buffer, base)
    state = check_numeric_char_ref(state, codepoint)
    char = codepoint_to_char(codepoint)

    case state.return_state do
      return_state when is_attribute_value_state(return_state) ->
        continue(state,
          input: rest,
          attr_value: state.attr_value <> char,
          state: state.return_state,
          return_state: nil,
          buffer: ""
        )

      return_state ->
        emit_char(state, char, input: rest, state: return_state, return_state: nil, buffer: "")
    end
  end

  # Check numeric character reference for parse errors per WHATWG spec
  defp check_numeric_char_ref(state, 0) do
    # null-character-reference parse error
    parse_error(state)
  end

  defp check_numeric_char_ref(state, cp) when is_outside_unicode_range(cp) do
    # character-reference-outside-unicode-range parse error
    parse_error(state)
  end

  defp check_numeric_char_ref(state, cp) when is_surrogate(cp) do
    # surrogate-character-reference parse error
    parse_error(state)
  end

  defp check_numeric_char_ref(state, cp) when cp in 0x80..0x9F do
    # control-character-reference parse error (C1 controls, including those
    # not in the Windows-1252 replacement table: 0x81, 0x8D, 0x8F, 0x90, 0x9D)
    parse_error(state)
  end

  defp check_numeric_char_ref(state, cp)
       when cp in 0x01..0x08 or cp in 0x0E..0x1F or cp == 0x0B do
    # control-character-reference parse error (C0 controls except HT, LF, FF)
    parse_error(state)
  end

  defp check_numeric_char_ref(state, 0x7F) do
    # control-character-reference parse error (DEL)
    parse_error(state)
  end

  # Noncharacters: U+FDD0..U+FDEF, plus U+FFFE/U+FFFF in each of the 17 planes.
  defp check_numeric_char_ref(state, cp)
       when cp in 0xFDD0..0xFDEF or rem(cp, 0x10000) in [0xFFFE, 0xFFFF] do
    # noncharacter-character-reference parse error
    parse_error(state)
  end

  defp check_numeric_char_ref(state, _cp), do: state

  # --------------------------------------------------------------------------
  # Helper functions
  # --------------------------------------------------------------------------

  # Convert numeric character reference codepoint to UTF-8 char (per HTML5 spec)
  defp codepoint_to_char(0), do: <<0xFFFD::utf8>>
  defp codepoint_to_char(cp) when is_outside_unicode_range(cp), do: <<0xFFFD::utf8>>
  defp codepoint_to_char(cp) when is_surrogate(cp), do: <<0xFFFD::utf8>>
  defp codepoint_to_char(cp) when is_map_key(@windows_1252, cp), do: <<@windows_1252[cp]::utf8>>
  defp codepoint_to_char(cp), do: <<cp::utf8>>

  # Specialized continue/2 clauses for common patterns (avoids struct! overhead)
  defp continue(state, state: new_state, input: new_input) do
    {:continue, %{state | state: new_state, input: new_input}}
  end

  defp continue(state, state: new_state) do
    {:continue, %{state | state: new_state}}
  end

  defp continue(state, input: new_input) do
    {:continue, %{state | input: new_input}}
  end

  defp continue(state, input: new_input, attr_value: new_attr_value) do
    {:continue, %{state | input: new_input, attr_value: new_attr_value}}
  end

  defp continue(state, state: new_state, return_state: new_return_state) do
    {:continue, %{state | state: new_state, return_state: new_return_state}}
  end

  defp continue(state, input: new_input, buffer: new_buffer) do
    {:continue, %{state | input: new_input, buffer: new_buffer}}
  end

  # Fallback for remaining patterns
  defp continue(state, updates) do
    {:continue, struct!(state, updates)}
  end

  defp emit(state), do: emit(state, [])

  # Common pattern: input: rest
  defp emit(state, input: new_input) do
    {:emit, state.token, %{state | state: :data, token: nil, input: new_input}}
  end

  defp emit(state, []) do
    {:emit, state.token, %{state | state: :data, token: nil}}
  end

  # Fallback with other updates
  defp emit(state, updates) do
    all_updates = Keyword.merge([state: :data, token: nil], updates)
    {:emit, state.token, struct!(state, all_updates)}
  end

  # Specialized emit_char/3 clauses for common patterns
  defp emit_char(state, char, state: new_state, input: new_input) do
    {:emit_char, char, %{state | state: new_state, input: new_input}}
  end

  defp emit_char(state, char, input: new_input) do
    {:emit_char, char, %{state | input: new_input}}
  end

  defp emit_char(state, char, state: new_state) do
    {:emit_char, char, %{state | state: new_state}}
  end

  # Fallback for remaining patterns
  defp emit_char(state, char, updates) do
    {:emit_char, char, struct!(state, updates)}
  end

  defp append_to_tag_name(%{token: {:start_tag, name, attrs, sc}} = state, char) do
    %{state | token: {:start_tag, name <> char, attrs, sc}}
  end

  defp append_to_tag_name(%{token: {:end_tag, name}} = state, char) do
    %{state | token: {:end_tag, name <> char}}
  end

  defp start_new_attribute(%{token: {:start_tag, _, _, _}} = state, initial_char) do
    %{state | attr_name: initial_char, attr_value: "", buffer: ""}
  end

  defp start_new_attribute(%{token: {:end_tag, _}} = state, _initial_char) do
    %{state | end_tag_has_attributes: true}
  end

  defp start_new_attribute(state, _), do: state

  defp maybe_end_tag_with_attributes(
         %{token: {:end_tag, _}, end_tag_has_attributes: true} = state
       ) do
    parse_error(%{state | end_tag_has_attributes: false})
  end

  defp maybe_end_tag_with_attributes(state), do: state

  defp finalize_attribute_name(%{token: {:start_tag, _, _, _}} = state) do
    # Move buffer contents to attr_name, clear buffer
    %{state | attr_name: state.attr_name <> state.buffer, buffer: ""}
  end

  defp finalize_attribute_name(state), do: state

  defp finalize_attribute_value(
         %{token: {:start_tag, name, attrs, sc}, attr_name: attr_name, attr_value: attr_value} =
           state
       ) do
    # Add the attribute to the token (only if name is non-empty and not duplicate)
    {attrs, state} =
      cond do
        attr_name == "" ->
          {attrs, state}

        List.keymember?(attrs, attr_name, 0) ->
          # duplicate-attribute parse error
          {attrs, parse_error(state)}

        true ->
          {[{attr_name, attr_value} | attrs], state}
      end

    %{state | token: {:start_tag, name, attrs, sc}, attr_name: "", attr_value: ""}
  end

  defp finalize_attribute_value(state), do: state

  defp set_self_closing(%{token: {:start_tag, name, attrs, _}} = state) do
    %{state | token: {:start_tag, name, attrs, true}}
  end

  defp set_self_closing(state), do: state

  defp append_to_doctype_name(%{token: {:doctype, name, pub, sys, quirks}} = state, char) do
    %{state | token: {:doctype, (name || "") <> char, pub, sys, quirks}}
  end

  defp set_force_quirks(%{token: {:doctype, name, pub, sys, _}} = state) do
    %{state | token: {:doctype, name, pub, sys, true}}
  end

  defp set_force_quirks(state), do: state

  defp set_doctype_public_id(%{token: {:doctype, name, _pub, sys, quirks}} = state, value) do
    %{state | token: {:doctype, name, value, sys, quirks}}
  end

  defp append_to_doctype_public_id(%{token: {:doctype, name, pub, sys, quirks}} = state, char) do
    %{state | token: {:doctype, name, (pub || "") <> char, sys, quirks}}
  end

  defp set_doctype_system_id(%{token: {:doctype, name, pub, _sys, quirks}} = state, value) do
    %{state | token: {:doctype, name, pub, value, quirks}}
  end

  defp append_to_doctype_system_id(%{token: {:doctype, name, pub, sys, quirks}} = state, char) do
    %{state | token: {:doctype, name, pub, (sys || "") <> char, quirks}}
  end

  defp append_to_comment(%{token: {:comment, data}} = state, char) do
    %{state | token: {:comment, data <> char}}
  end

  defp maybe_update_last_start_tag(%{token: {:start_tag, name, _, _}} = state) do
    %{state | last_start_tag: name}
  end

  defp maybe_update_last_start_tag(state), do: state

  defp appropriate_end_tag?(%{token: {:end_tag, name}, last_start_tag: last}) do
    name == last
  end

  defp appropriate_end_tag?(_state), do: false

  defp emit_end_tag_buffer(state, next_state, rest) do
    emit_char(state, "</" <> state.buffer, state: next_state, token: nil, input: rest)
  end

  defp flush_char_ref(%{return_state: return_state} = state, chars, rest)
       when is_attribute_value_state(return_state) do
    continue(state,
      input: rest,
      attr_value: state.attr_value <> chars,
      state: return_state,
      return_state: nil
    )
  end

  defp flush_char_ref(state, chars, rest) do
    emit_char(state, chars, input: rest, state: state.return_state, return_state: nil)
  end

  defp consume_named_entity(state, input, chars, rest) do
    has_semicolon? = entity_has_semicolon?(input, rest)

    if consumable_entity?(state.return_state, has_semicolon?, rest) do
      # missing-semicolon-after-character-reference parse error
      state = if has_semicolon?, do: state, else: parse_error(state)
      flush_char_ref(state, chars, rest)
    else
      [_amp | after_amp] = input
      flush_char_ref(state, "&", after_amp)
    end
  end

  defp lookup_named_entity(input) do
    {ascii, tail} = Enum.split_while(input, &(&1 < 128))
    bin = List.to_string(ascii)

    case Entities.lookup(bin) do
      {chars, rest_bin} ->
        consumed = byte_size(bin) - byte_size(rest_bin)
        {chars, Enum.drop(ascii, consumed) ++ tail}

      nil ->
        nil
    end
  end

  # Ambiguous ampersand state: the alphanumerics after the ampersand go back to
  # the return state as ordinary characters. Only a semicolon ending that run
  # is an unknown-named-character-reference parse error.
  defp ambiguous_ampersand_error(state, input) do
    case skip_ascii_alphanumerics(input) do
      [?; | _] -> parse_error(state)
      _ -> state
    end
  end

  defp skip_ascii_alphanumerics([c | rest]) when is_ascii_alpha(c) or is_ascii_digit(c),
    do: skip_ascii_alphanumerics(rest)

  defp skip_ascii_alphanumerics(rest), do: rest

  # The matched text is the prefix of input that Entities.lookup consumed.
  # Legacy references like "&amp" match without a terminating semicolon.
  defp entity_has_semicolon?(input, rest) do
    consumed = length(input) - length(rest)
    Enum.at(input, consumed - 1) == ?;
  end

  # Per HTML5 spec: in attribute values, legacy entities (no semicolon) followed
  # by = or alphanumeric should NOT be consumed (to preserve URLs like ?a=1&lang=en)
  defp consumable_entity?(return_state, has_semicolon?, rest)
       when is_attribute_value_state(return_state) do
    legacy_follows_problematic_char? =
      case rest do
        [?= | _] -> true
        [c | _] when is_ascii_digit(c) or is_ascii_alpha(c) -> true
        _ -> false
      end

    has_semicolon? or not legacy_follows_problematic_char?
  end

  defp consumable_entity?(_, _, _), do: true

  # Read characters until we hit one of the stop characters
  # Returns {collected_chars, remaining_input}
  # Specialized functions with guards for each stop set (faster than Enum.member?)

  defguardp is_data_safe(c) when c != ?< and c != ?& and c != 0 and c < 128

  defp chars_until_data(input), do: chars_until_data(input, [])

  defp chars_until_data([c | rest], acc) when is_data_safe(c) do
    chars_until_data(rest, [c | acc])
  end

  defp chars_until_data([c | _] = input, acc) when c == ?< or c == ?& or c == 0 do
    {codepoints_to_binary(:lists.reverse(acc)), input}
  end

  defp chars_until_data([c | rest], acc) do
    chars_until_data(rest, [c | acc])
  end

  defp chars_until_data([], acc) do
    {codepoints_to_binary(:lists.reverse(acc)), []}
  end

  defguardp is_rawtext_safe(c) when c != ?< and c != 0 and c < 128

  defp chars_until_rawtext(input), do: chars_until_rawtext(input, [])

  defp chars_until_rawtext([c | rest], acc) when is_rawtext_safe(c) do
    chars_until_rawtext(rest, [c | acc])
  end

  defp chars_until_rawtext([c | _] = input, acc) when c == ?< or c == 0 do
    {codepoints_to_binary(:lists.reverse(acc)), input}
  end

  defp chars_until_rawtext([c | rest], acc) do
    chars_until_rawtext(rest, [c | acc])
  end

  defp chars_until_rawtext([], acc) do
    {codepoints_to_binary(:lists.reverse(acc)), []}
  end

  defguardp is_null_safe(c) when c != 0 and c < 128

  defp chars_until_null(input), do: chars_until_null(input, [])

  defp chars_until_null([c | rest], acc) when is_null_safe(c) do
    chars_until_null(rest, [c | acc])
  end

  defp chars_until_null([0 | _] = input, acc) do
    {codepoints_to_binary(:lists.reverse(acc)), input}
  end

  defp chars_until_null([c | rest], acc) do
    chars_until_null(rest, [c | acc])
  end

  defp chars_until_null([], acc) do
    {codepoints_to_binary(:lists.reverse(acc)), []}
  end

  defguardp is_comment_safe(c) when c != ?- and c != ?< and c != 0 and c < 128

  defp chars_until_comment(input), do: chars_until_comment(input, [])

  defp chars_until_comment([c | rest], acc) when is_comment_safe(c) do
    chars_until_comment(rest, [c | acc])
  end

  defp chars_until_comment([c | _] = input, acc) when c == ?- or c == ?< or c == 0 do
    {codepoints_to_binary(:lists.reverse(acc)), input}
  end

  defp chars_until_comment([c | rest], acc) do
    chars_until_comment(rest, [c | acc])
  end

  defp chars_until_comment([], acc) do
    {codepoints_to_binary(:lists.reverse(acc)), []}
  end

  defguardp is_cdata_safe(c) when c != ?] and c != 0 and c < 128

  defp chars_until_cdata(input), do: chars_until_cdata(input, [])

  defp chars_until_cdata([c | rest], acc) when is_cdata_safe(c) do
    chars_until_cdata(rest, [c | acc])
  end

  defp chars_until_cdata([c | _] = input, acc) when c == ?] or c == 0 do
    {codepoints_to_binary(:lists.reverse(acc)), input}
  end

  defp chars_until_cdata([c | rest], acc) do
    chars_until_cdata(rest, [c | acc])
  end

  defp chars_until_cdata([], acc) do
    {codepoints_to_binary(:lists.reverse(acc)), []}
  end

  defp normalize_newlines(cps) when is_list(cps), do: normalize_newlines(cps, [])

  defp normalize_newlines([?\r, ?\n | rest], acc), do: normalize_newlines(rest, [?\n | acc])
  defp normalize_newlines([?\r | rest], acc), do: normalize_newlines(rest, [?\n | acc])
  defp normalize_newlines([c | rest], acc), do: normalize_newlines(rest, [c | acc])
  defp normalize_newlines([], acc), do: Enum.reverse(acc)

  defp decode_input(bytes) when is_binary(bytes) do
    cps =
      bytes
      |> utf8_with_replacement()
      |> :unicode.characters_to_list()
      |> normalize_newlines()

    {cps, preprocess_error_count(cps)}
  end

  defp decode_input(cps) when is_list(cps) do
    cps = normalize_newlines(cps)
    {cps, preprocess_error_count(cps)}
  end

  defp preprocess_error_count(cps) do
    Enum.count(cps, &preprocess_error?/1)
  end

  defp preprocess_error?(cp) when cp in 0xD800..0xDFFF, do: true
  defp preprocess_error?(cp) when cp in 0xFDD0..0xFDEF, do: true
  defp preprocess_error?(cp) when rem(cp, 0x10000) in [0xFFFE, 0xFFFF], do: true
  defp preprocess_error?(cp) when cp in 0x01..0x08 or cp in 0x0E..0x1F or cp == 0x0B, do: true
  defp preprocess_error?(0x7F), do: true
  defp preprocess_error?(cp) when cp in 0x80..0x9F, do: true
  defp preprocess_error?(_), do: false

  defp codepoints_to_binary(cps) do
    cps
    |> Enum.map(&codepoint_to_binary/1)
    |> IO.iodata_to_binary()
  end

  defp codepoint_to_binary(cp) when cp in 0xD800..0xDFFF, do: <<cp::16>>
  defp codepoint_to_binary(cp), do: <<cp::utf8>>

  # Decode as UTF-8 with U+FFFD replacement, matching the spec input stream.
  defp utf8_with_replacement(input) do
    case :unicode.characters_to_binary(input, :utf8, :utf8) do
      out when is_binary(out) -> out
      {:error, good, rest} -> replace_invalid_utf8(good, rest)
      {:incomplete, good, rest} -> good <> incomplete_utf8_replacements(rest)
    end
  end

  defp replace_invalid_utf8(good, <<>>) do
    good
  end

  defp replace_invalid_utf8(good, <<_bad, rest::binary>>) do
    good <> <<0xFFFD::utf8>> <> utf8_with_replacement(rest)
  end

  defp incomplete_utf8_replacements(rest) do
    String.duplicate(<<0xFFFD::utf8>>, byte_size(rest))
  end
end

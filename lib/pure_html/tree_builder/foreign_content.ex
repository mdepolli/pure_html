defmodule PureHTML.TreeBuilder.ForeignContent do
  @moduledoc """
  The rules for parsing tokens in foreign content (SVG and MathML), the
  integration point tests that decide when the tree construction dispatcher
  applies them, and the insertion of foreign elements with their tag and
  attribute adjustments.

  See: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inforeign
  """

  import PureHTML.TreeBuilder.Helpers

  alias PureHTML.TreeBuilder

  @svg_html_integration_points ~w(foreignObject desc title)

  # --------------------------------------------------------------------------
  # Tree construction dispatcher
  # --------------------------------------------------------------------------

  # Per WHATWG spec, process using the current insertion mode (NOT foreign content)
  # when any of these conditions is true:
  # 1. Stack is empty
  # 2. Adjusted current node is in HTML namespace
  # 3. Adjusted current node is MathML text integration point AND token is
  #    a start tag (not mglyph/malignmark)
  # 4. Adjusted current node is MathML text integration point AND token is character
  # 5. Adjusted current node is annotation-xml AND token is start tag "svg"
  # 6. Adjusted current node is HTML integration point AND token is start tag
  # 7. Adjusted current node is HTML integration point AND token is character
  # 8. Token is EOF
  # Otherwise, use foreign content rules.
  @doc """
  Whether the tree construction dispatcher routes `token` to the rules for
  parsing tokens in foreign content.
  """
  def applies?(_token, %{stack: []}), do: false
  def applies?(:eof, _state), do: false

  def applies?(token, state) do
    case adjusted_current_node_tag(state) do
      {ns, _} = node_tag when ns in [:svg, :math] ->
        not insertion_mode_exception?(token, node_tag, state)

      _ ->
        false
    end
  end

  defp adjusted_current_node_tag(%{stack: [_single], context_element: {_, _} = ctx}), do: ctx

  defp adjusted_current_node_tag(%{stack: [ref | _], elements: elements}),
    do: elements[ref].tag

  @mathml_text_integration_points ~w(mi mo mn ms mtext)

  # Condition 3: MathML text integration point + start tag (not mglyph/malignmark)
  defp insertion_mode_exception?({:start_tag, tag, _, _}, {:math, mtag}, _state)
       when mtag in @mathml_text_integration_points and tag not in ~w(mglyph malignmark),
       do: true

  # Condition 4: MathML text integration point + character
  defp insertion_mode_exception?({:character, _}, {:math, mtag}, _state)
       when mtag in @mathml_text_integration_points,
       do: true

  # Condition 5: annotation-xml + start tag "svg"
  defp insertion_mode_exception?({:start_tag, "svg", _, _}, {:math, "annotation-xml"}, _state),
    do: true

  # Condition 6: HTML integration point (SVG) + start tag
  defp insertion_mode_exception?({:start_tag, _, _, _}, {:svg, tag}, _state)
       when tag in @svg_html_integration_points,
       do: true

  # Condition 7: HTML integration point (SVG) + character
  defp insertion_mode_exception?({:character, _}, {:svg, tag}, _state)
       when tag in @svg_html_integration_points,
       do: true

  # Condition 6: HTML integration point (MathML annotation-xml with encoding) + start tag
  defp insertion_mode_exception?({:start_tag, _, _, _}, {:math, "annotation-xml"}, state),
    do: annotation_xml_is_html_integration_point?(state)

  # Condition 7: HTML integration point (MathML annotation-xml with encoding) + character
  defp insertion_mode_exception?({:character, _}, {:math, "annotation-xml"}, state),
    do: annotation_xml_is_html_integration_point?(state)

  defp insertion_mode_exception?(_, _, _), do: false

  defp annotation_xml_is_html_integration_point?(%{stack: [ref | _], elements: elements}) do
    case get_attr(elements[ref].attrs || [], "encoding") do
      nil -> false
      enc -> String.downcase(enc) in ["text/html", "application/xhtml+xml"]
    end
  end

  defp annotation_xml_is_html_integration_point?(_), do: false

  # --------------------------------------------------------------------------
  # Tokenizer feedback
  # --------------------------------------------------------------------------

  @doc """
  Whether there is an adjusted current node and it is not an element in the
  HTML namespace: the tokenizer's condition for a CDATA section.
  """
  def adjusted_current_node_foreign?(%{stack: []}), do: false

  def adjusted_current_node_foreign?(state) do
    state
    |> adjusted_current_node_tag()
    |> foreign_tag?()
  end

  # An HTML fragment context is `{nil, tag}`; only SVG and MathML are foreign.
  defp foreign_tag?({ns, _tag}) when ns in [:svg, :math], do: true
  defp foreign_tag?(_tag), do: false

  # --------------------------------------------------------------------------
  # The rules for parsing tokens in foreign content
  # --------------------------------------------------------------------------

  @doc """
  Processes `token` with the rules for parsing tokens in foreign content.
  """
  # Start tags. Per spec, an HTML breakout tag is a parse error; pop until the
  # current node is an integration point or an HTML element, then reprocess the
  # token with the rules for the current insertion mode (not the dispatcher).
  # Other start tags insert a foreign element.
  def process({:start_tag, tag, attrs, _} = token, state) do
    if html_breakout_tag?(tag, attrs) do
      state
      |> parse_error()
      |> close()
      |> process_with_current_mode(token)
    else
      insert_foreign_element(token, state)
    end
  end

  # End tags: walk the stack per spec. Match foreign elements by tag name,
  # fall through to insertion mode when reaching an HTML element.
  # First step: if the current node's tag name does not match, parse error.
  # Per spec, "An end tag whose tag name is 'br', 'p'": parse error; pop until
  # an integration point or an HTML element; reprocess the token with the
  # rules for the current insertion mode.
  def process({:end_tag, tag} = token, state) when tag in ~w(br p) do
    state
    |> parse_error()
    |> close()
    |> process_with_current_mode(token)
  end

  def process({:end_tag, tag}, state) do
    state
    |> parse_error_unless_current_matches(tag)
    |> walk_end_tag(tag)
  end

  # U+0000: "Parse error. Insert a U+FFFD REPLACEMENT CHARACTER character."
  # Whitespace is inserted; any other character is inserted and sets
  # frameset-ok to "not ok". Unlike in body, nothing is reconstructed.
  def process({:character, text}, state) do
    {kept, null_count} = split_null_characters(text)
    {_whitespace, rest} = split_whitespace(kept)

    state
    |> parse_error(null_count)
    |> add_text_to_stack(String.replace(text, <<0>>, "\uFFFD"))
    |> frameset_not_ok_for_text(rest)
    |> ok()
  end

  # Comments: insert a comment
  def process({:comment, text}, state) do
    state
    |> add_child_to_stack({:comment, text})
    |> ok()
  end

  def process({:pi, target, data}, state) do
    state
    |> insert_pi(target, data)
    |> ok()
  end

  # DOCTYPE: parse error, ignore
  def process({:doctype, _, _, _, _}, state) do
    state
    |> parse_error()
    |> ok()
  end

  defp frameset_not_ok_for_text(state, ""), do: state
  defp frameset_not_ok_for_text(state, _text), do: set_frameset_not_ok(state)

  defp process_with_current_mode(state, token) do
    TreeBuilder.process_with_current_mode(token, state)
  end

  # Foreign content end tag algorithm per WHATWG spec:
  # Walk down the stack from current node. If a foreign element's tag matches
  # (case-insensitive), pop until it's popped. If an HTML element is reached,
  # process using the current insertion mode's rules instead.
  defp walk_end_tag(%{stack: stack} = state, tag),
    do: foreign_content_end_tag(tag, stack, 0, state)

  defp foreign_content_end_tag(_tag, [], _count, state), do: ok(state)

  # Per spec: "If node is the topmost element in the stack of open elements,
  # then return. (fragment case)" — checked before the tag match and before
  # any hand-off to the current insertion mode.
  defp foreign_content_end_tag(_tag, [_topmost], _count, state), do: ok(state)

  defp foreign_content_end_tag(tag, [ref | rest], count, %{elements: elements} = state) do
    case elements[ref].tag do
      {_ns, etag} ->
        foreign_content_match_or_continue(tag, etag, rest, count, state)

      _html_tag ->
        # Reached an HTML element: process using the current insertion mode
        TreeBuilder.process_with_current_mode({:end_tag, tag}, state)
    end
  end

  defp foreign_content_match_or_continue(tag, etag, rest, count, state) do
    if String.downcase(etag) == tag do
      ok(%{state | stack: Enum.drop(state.stack, count + 1)})
    else
      foreign_content_end_tag(tag, rest, count + 1, state)
    end
  end

  # "If node's tag name, converted to ASCII lowercase, is not the same as the
  # tag name of the token, then this is a parse error."
  defp parse_error_unless_current_matches(state, tag) do
    state
    |> current_tag()
    |> parse_error_unless_matches(tag, state)
  end

  defp parse_error_unless_matches({_ns, etag}, tag, state) do
    if String.downcase(etag) == tag, do: state, else: parse_error(state)
  end

  defp parse_error_unless_matches(tag, tag, state), do: state
  defp parse_error_unless_matches(_current, _tag, state), do: parse_error(state)

  # --------------------------------------------------------------------------
  # Inserting foreign elements
  # --------------------------------------------------------------------------

  # Inserts a foreign element for a start tag processed by these rules: the
  # element goes into the adjusted current node's namespace.
  defp insert_foreign_element({:start_tag, tag, attrs, self_closing}, state) do
    state
    |> insert_element(foreign_namespace(state), tag, attrs, self_closing)
    |> ok()
  end

  @doc """
  Inserts a foreign element in namespace `ns` with the SVG tag and foreign
  attribute adjustments applied. A self-closing tag is inserted and popped
  (its flag acknowledged); otherwise the element is pushed.
  """
  def insert_element(state, ns, tag, attrs, true = _self_closing) do
    add_child_to_stack(
      state,
      {{ns, adjust_svg_tag(ns, tag)}, adjust_foreign_attributes(ns, attrs), []}
    )
  end

  def insert_element(state, ns, tag, attrs, _self_closing) do
    push_foreign_element(state, ns, adjust_svg_tag(ns, tag), adjust_foreign_attributes(ns, attrs))
  end

  @foreign_attr_adjustments %{
    "xlink:actuate" => {:xlink, "actuate"},
    "xlink:arcrole" => {:xlink, "arcrole"},
    "xlink:href" => {:xlink, "href"},
    "xlink:role" => {:xlink, "role"},
    "xlink:show" => {:xlink, "show"},
    "xlink:title" => {:xlink, "title"},
    "xlink:type" => {:xlink, "type"},
    "xml:lang" => {:xml, "lang"},
    "xml:space" => {:xml, "space"},
    "xmlns" => {:xmlns, "xmlns"},
    "xmlns:xlink" => {:xmlns, "xlink"}
  }

  @mathml_attr_case_adjustments %{"definitionurl" => "definitionURL"}

  # SVG attributes that need case adjustment (per HTML5 spec)
  @svg_attr_case_adjustments %{
    "attributename" => "attributeName",
    "attributetype" => "attributeType",
    "basefrequency" => "baseFrequency",
    "baseprofile" => "baseProfile",
    "calcmode" => "calcMode",
    "clippathunits" => "clipPathUnits",
    "diffuseconstant" => "diffuseConstant",
    "edgemode" => "edgeMode",
    "filterunits" => "filterUnits",
    "glyphref" => "glyphRef",
    "gradienttransform" => "gradientTransform",
    "gradientunits" => "gradientUnits",
    "kernelmatrix" => "kernelMatrix",
    "kernelunitlength" => "kernelUnitLength",
    "keypoints" => "keyPoints",
    "keysplines" => "keySplines",
    "keytimes" => "keyTimes",
    "lengthadjust" => "lengthAdjust",
    "limitingconeangle" => "limitingConeAngle",
    "markerheight" => "markerHeight",
    "markerunits" => "markerUnits",
    "markerwidth" => "markerWidth",
    "maskcontentunits" => "maskContentUnits",
    "maskunits" => "maskUnits",
    "numoctaves" => "numOctaves",
    "pathlength" => "pathLength",
    "patterncontentunits" => "patternContentUnits",
    "patterntransform" => "patternTransform",
    "patternunits" => "patternUnits",
    "pointsatx" => "pointsAtX",
    "pointsaty" => "pointsAtY",
    "pointsatz" => "pointsAtZ",
    "preservealpha" => "preserveAlpha",
    "preserveaspectratio" => "preserveAspectRatio",
    "primitiveunits" => "primitiveUnits",
    "refx" => "refX",
    "refy" => "refY",
    "repeatcount" => "repeatCount",
    "repeatdur" => "repeatDur",
    "requiredextensions" => "requiredExtensions",
    "requiredfeatures" => "requiredFeatures",
    "specularconstant" => "specularConstant",
    "specularexponent" => "specularExponent",
    "spreadmethod" => "spreadMethod",
    "startoffset" => "startOffset",
    "stddeviation" => "stdDeviation",
    "stitchtiles" => "stitchTiles",
    "surfacescale" => "surfaceScale",
    "systemlanguage" => "systemLanguage",
    "tablevalues" => "tableValues",
    "targetx" => "targetX",
    "targety" => "targetY",
    "textlength" => "textLength",
    "viewbox" => "viewBox",
    "viewtarget" => "viewTarget",
    "xchannelselector" => "xChannelSelector",
    "ychannelselector" => "yChannelSelector",
    "zoomandpan" => "zoomAndPan"
  }

  defp adjust_foreign_attributes(ns, attrs) do
    Enum.map(attrs, fn {key, value} ->
      {adjust_attr_key(ns, key), value}
    end)
  end

  defp adjust_attr_key(_ns, key) when is_map_key(@foreign_attr_adjustments, key) do
    @foreign_attr_adjustments[key]
  end

  defp adjust_attr_key(:math, key) when is_map_key(@mathml_attr_case_adjustments, key) do
    @mathml_attr_case_adjustments[key]
  end

  defp adjust_attr_key(:svg, key) when is_map_key(@svg_attr_case_adjustments, key) do
    @svg_attr_case_adjustments[key]
  end

  defp adjust_attr_key(_ns, key), do: key

  @svg_tag_adjustments %{
    "altglyph" => "altGlyph",
    "altglyphdef" => "altGlyphDef",
    "altglyphitem" => "altGlyphItem",
    "animatecolor" => "animateColor",
    "animatemotion" => "animateMotion",
    "animatetransform" => "animateTransform",
    "clippath" => "clipPath",
    "feblend" => "feBlend",
    "fecolormatrix" => "feColorMatrix",
    "fecomponenttransfer" => "feComponentTransfer",
    "fecomposite" => "feComposite",
    "feconvolvematrix" => "feConvolveMatrix",
    "fediffuselighting" => "feDiffuseLighting",
    "fedisplacementmap" => "feDisplacementMap",
    "fedistantlight" => "feDistantLight",
    "fedropshadow" => "feDropShadow",
    "feflood" => "feFlood",
    "fefunca" => "feFuncA",
    "fefuncb" => "feFuncB",
    "fefuncg" => "feFuncG",
    "fefuncr" => "feFuncR",
    "fegaussianblur" => "feGaussianBlur",
    "feimage" => "feImage",
    "femerge" => "feMerge",
    "femergenode" => "feMergeNode",
    "femorphology" => "feMorphology",
    "feoffset" => "feOffset",
    "fepointlight" => "fePointLight",
    "fespecularlighting" => "feSpecularLighting",
    "fespotlight" => "feSpotLight",
    "fetile" => "feTile",
    "feturbulence" => "feTurbulence",
    "foreignobject" => "foreignObject",
    "glyphref" => "glyphRef",
    "lineargradient" => "linearGradient",
    "radialgradient" => "radialGradient",
    "textpath" => "textPath"
  }

  defp adjust_svg_tag(:svg, tag) when is_map_key(@svg_tag_adjustments, tag) do
    @svg_tag_adjustments[tag]
  end

  defp adjust_svg_tag(_ns, tag), do: tag

  # --------------------------------------------------------------------------
  # Namespaces, integration points, and breaking out
  # --------------------------------------------------------------------------

  # The adjusted current node's namespace (:svg or :math), or nil for HTML.
  defp foreign_namespace(%{stack: [_single], context_element: {ns, _}})
       when ns in [:svg, :math],
       do: ns

  defp foreign_namespace(%{stack: [ref | _], elements: elements}) do
    case elements[ref].tag do
      {:svg, _} -> :svg
      {:math, _} -> :math
      _ -> nil
    end
  end

  defp foreign_namespace(%{stack: []}), do: nil

  @html_breakout_tags ~w(b big blockquote body br center code dd div dl dt em embed
                         h1 h2 h3 h4 h5 h6 head hr i img li listing menu meta nobr ol
                         p pre ruby s small span strong strike sub sup table tt u ul var)

  # Whether an HTML start tag breaks out of foreign content (a font start tag
  # only with a color, face, or size attribute)
  defp html_breakout_tag?(tag, attrs) do
    tag in @html_breakout_tags or (tag == "font" and font_breakout_tag?(attrs))
  end

  # Per WHATWG spec: <font> is a breakout tag only when it has color, face, or size attributes
  defp font_breakout_tag?(attrs) do
    Enum.any?(attrs, fn {name, _} -> name in ~w(color face size) end)
  end

  @doc """
  Pops elements while the current node is not a MathML text integration point,
  an HTML integration point, or an element in the HTML namespace.
  """
  def close(%{stack: stack, elements: elements} = state) do
    # Pop all foreign elements from the stack
    # With ref-only architecture, children are already in elements map
    {new_stack, _parent_ref} = pop_foreign_elements(stack, elements)
    %{state | stack: new_stack}
  end

  defp pop_foreign_elements([], _elements), do: {[], nil}

  defp pop_foreign_elements([ref | rest] = stack, elements) do
    elem = elements[ref]

    case elem.tag do
      # HTML element - stop here
      tag when is_binary(tag) ->
        {stack, ref}

      # MathML text integration points - stop here
      {:math, math_tag} when math_tag in @mathml_text_integration_points ->
        {stack, ref}

      # SVG HTML integration points - stop here
      {:svg, svg_tag} when svg_tag in ~w(foreignObject desc title) ->
        {stack, ref}

      # MathML HTML integration point (with proper encoding)
      {:math, "annotation-xml"} ->
        if html_integration_encoding?(get_attr(elem.attrs, "encoding")) do
          {stack, ref}
        else
          pop_foreign_elements(rest, elements)
        end

      # Other foreign elements - pop and continue
      _ ->
        pop_foreign_elements(rest, elements)
    end
  end

  defp html_integration_encoding?(nil), do: false

  defp html_integration_encoding?(encoding) do
    String.downcase(encoding) in ~w(text/html application/xhtml+xml)
  end
end

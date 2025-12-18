defmodule PureHtmlTest do
  use ExUnit.Case
  doctest PureHtml

  test "greets the world" do
    assert PureHtml.hello() == :world
  end
end

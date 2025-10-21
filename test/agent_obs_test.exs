defmodule AgentObsTest do
  use ExUnit.Case
  doctest AgentObs

  test "greets the world" do
    assert AgentObs.hello() == :world
  end
end

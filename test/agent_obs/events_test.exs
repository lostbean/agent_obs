defmodule AgentObs.EventsTest do
  use ExUnit.Case, async: true

  alias AgentObs.Events

  describe "validate_event/3 for agent events" do
    test "validates valid agent start metadata" do
      metadata = %{name: "test_agent", input: "test task"}
      assert :ok = Events.validate_event(:agent, :start, metadata)
    end

    test "returns error for missing required name field" do
      metadata = %{input: "test task"}

      assert {:error, "Missing required field: name"} =
               Events.validate_event(:agent, :start, metadata)
    end

    test "returns error for missing required input field" do
      metadata = %{name: "test_agent"}

      assert {:error, "Missing required field: input"} =
               Events.validate_event(:agent, :start, metadata)
    end

    test "validates valid agent stop metadata" do
      metadata = %{output: "test result"}
      assert :ok = Events.validate_event(:agent, :stop, metadata)
    end

    test "validates agent exception metadata" do
      metadata = %{kind: :error, reason: "some error"}
      assert :ok = Events.validate_event(:agent, :exception, metadata)
    end
  end

  describe "validate_event/3 for tool events" do
    test "validates valid tool start metadata" do
      metadata = %{name: "get_weather", arguments: %{city: "SF"}}
      assert :ok = Events.validate_event(:tool, :start, metadata)
    end

    test "returns error for missing tool name" do
      metadata = %{arguments: %{city: "SF"}}

      assert {:error, "Missing required field: name"} =
               Events.validate_event(:tool, :start, metadata)
    end

    test "validates valid tool stop metadata" do
      metadata = %{result: %{temp: 72}}
      assert :ok = Events.validate_event(:tool, :stop, metadata)
    end
  end

  describe "validate_event/3 for LLM events" do
    test "validates valid LLM start metadata" do
      metadata = %{
        model: "gpt-4o",
        input_messages: [%{role: "user", content: "Hello"}]
      }

      assert :ok = Events.validate_event(:llm, :start, metadata)
    end

    test "returns error for missing model" do
      metadata = %{input_messages: [%{role: "user", content: "Hello"}]}

      assert {:error, "Missing required field: model"} =
               Events.validate_event(:llm, :start, metadata)
    end

    test "returns error for invalid LLM type" do
      metadata = %{
        model: "gpt-4o",
        type: "invalid",
        input_messages: []
      }

      assert {:error, msg} = Events.validate_event(:llm, :start, metadata)
      assert msg =~ "Invalid LLM type"
    end

    test "validates LLM stop metadata" do
      metadata = %{output_messages: [], tokens: %{total: 100}}
      assert :ok = Events.validate_event(:llm, :stop, metadata)
    end
  end

  describe "validate_event/3 for prompt events" do
    test "validates valid prompt start metadata" do
      metadata = %{name: "system_prompt", variables: %{user: "Alice"}}
      assert :ok = Events.validate_event(:prompt, :start, metadata)
    end

    test "validates prompt stop metadata" do
      metadata = %{rendered: "Hello Alice"}
      assert :ok = Events.validate_event(:prompt, :stop, metadata)
    end
  end

  describe "normalize_metadata/3" do
    test "normalizes LLM message roles from atoms to strings" do
      metadata = %{
        model: "gpt-4o",
        input_messages: [
          %{role: :user, content: "Hello"},
          %{role: :assistant, content: "Hi"}
        ]
      }

      normalized = Events.normalize_metadata(:llm, :start, metadata)

      assert [
               %{role: "user", content: "Hello"},
               %{role: "assistant", content: "Hi"}
             ] = normalized.input_messages
    end

    test "leaves string roles unchanged" do
      metadata = %{
        output_messages: [%{role: "assistant", content: "Hello"}]
      }

      normalized = Events.normalize_metadata(:llm, :stop, metadata)
      assert [%{role: "assistant", content: "Hello"}] = normalized.output_messages
    end

    test "does not modify other event types" do
      metadata = %{name: "test", input: "data"}
      assert metadata == Events.normalize_metadata(:agent, :start, metadata)
    end
  end

  describe "event_types/0 and event_phases/0" do
    test "returns list of event types" do
      assert [:agent, :tool, :llm, :prompt] = Events.event_types()
    end

    test "returns list of event phases" do
      assert [:start, :stop, :exception] = Events.event_phases()
    end
  end
end

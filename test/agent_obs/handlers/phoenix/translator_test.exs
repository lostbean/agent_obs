defmodule AgentObs.Handlers.Phoenix.TranslatorTest do
  use ExUnit.Case, async: true

  alias AgentObs.Handlers.Phoenix.Translator

  describe "from_start_metadata/2 for agent events" do
    test "translates agent start metadata to OpenInference" do
      metadata = %{name: "weather_agent", input: "What's the weather?"}
      attributes = Translator.from_start_metadata(:agent, metadata)

      assert attributes["openinference.span.kind"] == "AGENT"
      assert attributes["input.value"] == "What's the weather?"
    end

    test "includes optional model name" do
      metadata = %{name: "agent", input: "task", model: "gpt-4o"}
      attributes = Translator.from_start_metadata(:agent, metadata)

      assert attributes["llm.model_name"] == "gpt-4o"
    end
  end

  describe "from_start_metadata/2 for tool events" do
    test "translates tool start metadata" do
      metadata = %{name: "get_weather", arguments: %{city: "SF"}}
      attributes = Translator.from_start_metadata(:tool, metadata)

      assert attributes["openinference.span.kind"] == "TOOL"
      assert attributes["tool.name"] == "get_weather"
      assert is_binary(attributes["tool.parameters"])
    end

    test "includes optional description" do
      metadata = %{
        name: "calculator",
        arguments: %{op: "add"},
        description: "A calculator tool"
      }

      attributes = Translator.from_start_metadata(:tool, metadata)
      assert attributes["tool.description"] == "A calculator tool"
    end
  end

  describe "from_start_metadata/2 for LLM events" do
    test "translates LLM start metadata" do
      metadata = %{
        model: "gpt-4o",
        input_messages: [
          %{role: "user", content: "Hello"}
        ]
      }

      attributes = Translator.from_start_metadata(:llm, metadata)

      assert attributes["openinference.span.kind"] == "LLM"
      assert attributes["llm.model_name"] == "gpt-4o"
    end

    test "flattens input messages correctly" do
      metadata = %{
        model: "gpt-4o",
        input_messages: [
          %{role: "user", content: "First message"},
          %{role: "assistant", content: "Second message"}
        ]
      }

      attributes = Translator.from_start_metadata(:llm, metadata)

      assert attributes["llm.input_messages.0.message.role"] == "user"
      assert attributes["llm.input_messages.0.message.content"] == "First message"
      assert attributes["llm.input_messages.1.message.role"] == "assistant"
      assert attributes["llm.input_messages.1.message.content"] == "Second message"
    end

    test "handles messages with tool calls" do
      metadata = %{
        model: "gpt-4o",
        input_messages: [
          %{
            role: "assistant",
            tool_calls: [
              %{
                function: %{
                  name: "get_weather",
                  arguments: ~s({"city": "SF"})
                }
              }
            ]
          }
        ]
      }

      attributes = Translator.from_start_metadata(:llm, metadata)

      assert attributes["llm.input_messages.0.message.tool_calls.0.tool_call.function.name"] ==
               "get_weather"

      assert attributes["llm.input_messages.0.message.tool_calls.0.tool_call.function.arguments"] ==
               ~s({"city": "SF"})
    end
  end

  describe "from_stop_metadata/3 for agent events" do
    test "translates agent stop metadata" do
      metadata = %{output: "The weather is sunny", iterations: 2}
      measurements = %{duration: 1_500_000_000}

      attributes = Translator.from_stop_metadata(:agent, metadata, measurements)

      assert attributes["output.value"] == "The weather is sunny"
      assert attributes["agent.iterations"] == 2
      assert attributes["latency_ms"] == 1500.0
    end
  end

  describe "from_stop_metadata/3 for LLM events" do
    test "translates LLM stop metadata with token counts" do
      metadata = %{
        output_messages: [%{role: "assistant", content: "Hello!"}],
        tokens: %{prompt: 10, completion: 5, total: 15},
        cost: 0.00015
      }

      measurements = %{duration: 2_000_000_000}

      attributes = Translator.from_stop_metadata(:llm, metadata, measurements)

      assert attributes["llm.token_count.prompt"] == 10
      assert attributes["llm.token_count.completion"] == 5
      assert attributes["llm.token_count.total"] == 15
      assert attributes["llm.cost.total"] == 0.00015
      assert attributes["latency_ms"] == 2000.0
    end

    test "flattens output messages" do
      metadata = %{
        output_messages: [
          %{role: "assistant", content: "Response"}
        ]
      }

      attributes = Translator.from_stop_metadata(:llm, metadata, %{})

      assert attributes["llm.output_messages.0.message.role"] == "assistant"
      assert attributes["llm.output_messages.0.message.content"] == "Response"
    end
  end

  describe "from_exception_metadata/3" do
    test "translates exception metadata" do
      metadata = %{
        kind: :error,
        reason: %RuntimeError{message: "Something went wrong"},
        stacktrace: []
      }

      measurements = %{duration: 100_000_000}

      attributes = Translator.from_exception_metadata(:agent, metadata, measurements)

      assert attributes["exception.type"] == "error"
      assert attributes["exception.message"] =~ "Something went wrong"
      assert attributes["exception.escaped"] == false
    end
  end
end

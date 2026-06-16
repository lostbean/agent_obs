defmodule AgentObs.Handlers.Phoenix.TranslatorTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias AgentObs.Handlers.Phoenix.Translator

  describe "from_start_metadata/2 for agent events" do
    test "translates agent start metadata to OpenInference" do
      metadata = %{name: "weather_agent", input: "What's the weather?"}
      attributes = Translator.from_start_metadata(:agent, metadata)

      assert attributes["openinference.span.kind"] == "AGENT"
      assert attributes["input.value"] == "What's the weather?"
    end

    test "includes input MIME type" do
      metadata = %{name: "agent", input: "task"}
      attributes = Translator.from_start_metadata(:agent, metadata)

      assert attributes["input.mime_type"] == "text/plain"
    end

    test "includes optional model name" do
      metadata = %{name: "agent", input: "task", model: "gpt-4o"}
      attributes = Translator.from_start_metadata(:agent, metadata)

      assert attributes["llm.model_name"] == "gpt-4o"
    end

    test "includes optional session ID" do
      metadata = %{name: "agent", input: "task", session_id: "session-123"}
      attributes = Translator.from_start_metadata(:agent, metadata)

      assert attributes["session.id"] == "session-123"
    end

    test "includes optional user ID" do
      metadata = %{name: "agent", input: "task", user_id: "user-456"}
      attributes = Translator.from_start_metadata(:agent, metadata)

      assert attributes["user.id"] == "user-456"
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

    test "sets gen_ai.system from model string (regression test)" do
      metadata = %{model: "anthropic:claude-3-sonnet", input_messages: []}

      attrs = Translator.from_start_metadata(:llm, metadata)

      assert attrs["gen_ai.system"] == "anthropic"
      assert attrs["gen_ai.request.model"] == "anthropic:claude-3-sonnet"
    end

    test "extracts provider from various model formats" do
      test_cases = [
        {"anthropic:claude-3-sonnet", "anthropic"},
        {"openai:gpt-4", "openai"},
        {"google:gemini-pro", "google"},
        {"gpt-4", "openai"},
        {"claude-3", "anthropic"},
        {"gemini-pro", "google"},
        {"unknown-model", "unknown"}
      ]

      Enum.each(test_cases, fn {model, expected} ->
        metadata = %{model: model, input_messages: []}
        attrs = Translator.from_start_metadata(:llm, metadata)

        assert attrs["gen_ai.system"] == expected,
               "Expected #{expected} for model #{model}, got #{attrs["gen_ai.system"]}"
      end)
    end

    test "sets AI Observability Working Group attributes" do
      metadata = %{model: "anthropic:claude-3", input_messages: []}

      attrs = Translator.from_start_metadata(:llm, metadata)

      assert attrs["ai.operationId"] == "ai.generateText.doGenerate"
      assert attrs["ai.model.id"] == "anthropic:claude-3"
      assert attrs["ai.model.provider"] == "anthropic"
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
                  # Arguments as map (will be JSON-encoded by translator)
                  arguments: %{city: "SF"}
                }
              }
            ]
          }
        ]
      }

      attributes = Translator.from_start_metadata(:llm, metadata)

      assert attributes["llm.input_messages.0.message.tool_calls.0.tool_call.function.name"] ==
               "get_weather"

      # Arguments should be JSON-encoded
      args_json =
        attributes["llm.input_messages.0.message.tool_calls.0.tool_call.function.arguments"]

      assert is_binary(args_json)
      assert String.contains?(args_json, "city")
      assert String.contains?(args_json, "SF")
    end

    test "handles input messages with map content without crashing" do
      # Test that map content in input messages is handled correctly
      # This mirrors the fix for output messages with structured objects
      metadata = %{
        model: "gpt-4o",
        input_messages: [
          %{role: "user", content: "Extract the entity"},
          %{role: "assistant", content: %{"name" => "Entity", "type" => "test"}}
        ]
      }

      # Should not raise Protocol.UndefinedError
      attributes = Translator.from_start_metadata(:llm, metadata)

      assert attributes["llm.input_messages.0.message.content"] == "Extract the entity"
      # Map content should be JSON-encoded
      content = attributes["llm.input_messages.1.message.content"]
      assert is_binary(content)
      assert String.contains?(content, "Entity")
    end

    test "renders multimodal content parts as placeholders by default" do
      pdf_data = String.duplicate("x", 1024)

      metadata = %{
        model: "gpt-4o",
        input_messages: [
          %{
            role: "user",
            content: [
              %{type: :text, text: "Extract from this document."},
              %{type: :file, data: pdf_data, media_type: "application/pdf"}
            ]
          }
        ]
      }

      attributes = Translator.from_start_metadata(:llm, metadata)
      content = attributes["llm.input_messages.0.message.content"]

      assert is_binary(content)
      assert String.contains?(content, "Extract from this document.")
      assert String.contains?(content, "[file: application/pdf, 1024 bytes]")
      refute String.contains?(content, pdf_data)
    end

    test "renders image content parts with media type and size by default" do
      image_data = String.duplicate("x", 2048)

      metadata = %{
        model: "gpt-4o",
        input_messages: [
          %{role: "user", content: [%{type: :image, data: image_data, media_type: "image/png"}]}
        ]
      }

      attributes = Translator.from_start_metadata(:llm, metadata)

      assert attributes["llm.input_messages.0.message.content"] ==
               "[image: image/png, 2048 bytes]"
    end

    test "inlines raw multimodal data when include_multimodal_data is enabled" do
      Application.put_env(:agent_obs, :include_multimodal_data, true)
      on_exit(fn -> Application.delete_env(:agent_obs, :include_multimodal_data) end)

      pdf_data = String.duplicate("x", 1024)

      metadata = %{
        model: "gpt-4o",
        input_messages: [
          %{
            role: "user",
            content: [%{type: :file, data: pdf_data, media_type: "application/pdf"}]
          }
        ]
      }

      attributes = Translator.from_start_metadata(:llm, metadata)
      content = attributes["llm.input_messages.0.message.content"]

      assert String.contains?(content, "[file: application/pdf, 1024 bytes]")
      assert String.contains?(content, pdf_data)
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

    test "includes output MIME type" do
      metadata = %{output: "result"}
      measurements = %{}

      attributes = Translator.from_stop_metadata(:agent, metadata, measurements)

      assert attributes["output.mime_type"] == "text/plain"
    end

    test "formats tools_used as indexed array" do
      metadata = %{output: "done", tools_used: ["web_search", "calculator"]}
      measurements = %{}

      attributes = Translator.from_stop_metadata(:agent, metadata, measurements)

      assert attributes["agent.tools_used.0"] == "web_search"
      assert attributes["agent.tools_used.1"] == "calculator"
      # Should NOT have a plain "agent.tools_used" key with JSON string
      refute Map.has_key?(attributes, "agent.tools_used")
    end

    test "handles empty tools_used list" do
      metadata = %{output: "done", tools_used: []}
      measurements = %{}

      attributes = Translator.from_stop_metadata(:agent, metadata, measurements)

      # No tools_used attributes should be present
      refute Map.has_key?(attributes, "agent.tools_used")
      refute Map.has_key?(attributes, "agent.tools_used.0")
    end

    test "includes token counts at agent level" do
      metadata = %{
        output: "done",
        tokens: %{prompt: 100, completion: 50, total: 150}
      }

      measurements = %{}

      attributes = Translator.from_stop_metadata(:agent, metadata, measurements)

      assert attributes["llm.token_count.prompt"] == 100
      assert attributes["llm.token_count.completion"] == 50
      assert attributes["llm.token_count.total"] == 150
    end

    test "includes cost at agent level" do
      metadata = %{output: "done", cost: 0.00123}
      measurements = %{}

      attributes = Translator.from_stop_metadata(:agent, metadata, measurements)

      assert attributes["llm.cost.total"] == 0.00123
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

    test "sets gen_ai.usage.* attributes (regression test for GenAI compatibility)" do
      metadata = %{
        output_messages: [],
        tokens: %{prompt: 150, completion: 75}
      }

      measurements = %{duration: 1_000_000_000}

      attrs = Translator.from_stop_metadata(:llm, metadata, measurements)

      assert attrs["gen_ai.usage.input_tokens"] == 150
      assert attrs["gen_ai.usage.output_tokens"] == 75
    end

    test "handles missing token data gracefully" do
      metadata = %{output_messages: []}
      measurements = %{duration: 1_000_000_000}

      attrs = Translator.from_stop_metadata(:llm, metadata, measurements)

      # Should not crash, just not include token attributes
      refute Map.has_key?(attrs, "llm.token_count.prompt")
      refute Map.has_key?(attrs, "gen_ai.usage.input_tokens")
    end

    test "handles structured object output (map content) without crashing" do
      # Regression test for Protocol.UndefinedError when trace_generate_object/4
      # returns a map as the message content
      metadata = %{
        output_messages: [
          %{role: "assistant", content: %{"name" => "Test Entity", "value" => 42}}
        ],
        tokens: %{prompt: 10, completion: 20, total: 30},
        object: %{"name" => "Test Entity", "value" => 42}
      }

      measurements = %{duration: 1_000_000_000}

      # Should not raise Protocol.UndefinedError
      attrs = Translator.from_stop_metadata(:llm, metadata, measurements)

      assert attrs["llm.output_messages.0.message.role"] == "assistant"
      # Content should be JSON-encoded
      content = attrs["llm.output_messages.0.message.content"]
      assert is_binary(content)
      assert String.contains?(content, "Test Entity")
      assert String.contains?(content, "42")
    end

    test "handles complex nested object output" do
      # Test with a more complex nested structure like the bug report shows
      metadata = %{
        output_messages: [
          %{
            role: "assistant",
            content: %{
              "entities" => [
                %{
                  "confidence" => 0.95,
                  "description" => "A customer record",
                  "name" => "Customer"
                },
                %{"confidence" => 0.87, "description" => "An order record", "name" => "Order"}
              ],
              "metadata" => %{"version" => "1.0", "extracted_at" => "2025-11-26"}
            }
          }
        ]
      }

      measurements = %{}

      attrs = Translator.from_stop_metadata(:llm, metadata, measurements)

      content = attrs["llm.output_messages.0.message.content"]
      assert is_binary(content)
      # Verify it's valid JSON
      assert {:ok, decoded} = Jason.decode(content)
      assert is_map(decoded)
      assert is_list(decoded["entities"])
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

      assert attributes["exception.type"] == "RuntimeError"
      assert attributes["exception.message"] =~ "Something went wrong"
      assert attributes["exception.escaped"] == false
    end

    test "extracts exception type from Exception struct" do
      metadata = %{
        kind: :error,
        reason: %ArithmeticError{message: "bad argument"},
        stacktrace: []
      }

      measurements = %{}

      attributes = Translator.from_exception_metadata(:llm, metadata, measurements)

      assert attributes["exception.type"] == "ArithmeticError"
      assert attributes["exception.message"] == "bad argument"
    end

    test "uses kind when reason is not an Exception" do
      metadata = %{
        kind: :throw,
        reason: :something_bad,
        stacktrace: []
      }

      measurements = %{}

      attributes = Translator.from_exception_metadata(:tool, metadata, measurements)

      assert attributes["exception.type"] == "throw"
      assert attributes["exception.message"] == ":something_bad"
    end

    test "formats stacktrace with file and line info" do
      metadata = %{
        kind: :error,
        reason: %RuntimeError{message: "Error"},
        stacktrace: [
          {MyModule, :my_function, 2, [file: ~c"lib/my_module.ex", line: 42]},
          {OtherModule, :other_function, 1, [file: ~c"lib/other.ex", line: 100]}
        ]
      }

      measurements = %{}

      attributes = Translator.from_exception_metadata(:agent, metadata, measurements)

      assert attributes["exception.stacktrace"] =~ "MyModule.my_function/2"
      assert attributes["exception.stacktrace"] =~ "lib/my_module.ex:42"
      assert attributes["exception.stacktrace"] =~ "OtherModule.other_function/1"
      assert attributes["exception.stacktrace"] =~ "lib/other.ex:100"
    end

    test "formats stacktrace without location info" do
      metadata = %{
        kind: :error,
        reason: %RuntimeError{message: "Error"},
        stacktrace: [
          {SomeModule, :some_function, 3}
        ]
      }

      measurements = %{}

      attributes = Translator.from_exception_metadata(:agent, metadata, measurements)

      assert attributes["exception.stacktrace"] == "SomeModule.some_function/3"
    end

    test "handles empty stacktrace" do
      metadata = %{
        kind: :error,
        reason: %RuntimeError{message: "Error"},
        stacktrace: []
      }

      measurements = %{}

      attributes = Translator.from_exception_metadata(:agent, metadata, measurements)

      # Should not have stacktrace attribute if empty
      refute Map.has_key?(attributes, "exception.stacktrace")
    end

    test "includes duration in exception metadata" do
      metadata = %{
        kind: :error,
        reason: %RuntimeError{message: "Error"},
        stacktrace: []
      }

      measurements = %{duration: 500_000_000}

      attributes = Translator.from_exception_metadata(:agent, metadata, measurements)

      assert attributes["latency_ms"] == 500.0
    end
  end
end

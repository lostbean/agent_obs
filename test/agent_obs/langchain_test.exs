defmodule AgentObs.LangChainTest do
  use ExUnit.Case, async: true

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.ChatModels.ChatGoogleAI
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Function
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult
  alias LangChain.TokenUsage

  @moduletag :capture_log

  @langchain_available Code.ensure_loaded?(LangChain.Chains.LLMChain)

  setup_all do
    unless @langchain_available do
      raise "LangChain not available — required for these tests"
    end

    :ok
  end

  # Build a minimal chain struct for use in callback tests.
  # The chain carries `llm` (for model extraction) and `messages` (for input extraction).
  # Messages must be added via add_messages since LLMChain.new! ignores the :messages key.
  defp mock_chain(opts \\ []) do
    llm = Keyword.get(opts, :llm, ChatOpenAI.new!(%{model: "gpt-4o"}))
    messages = Keyword.get(opts, :messages, [])

    LLMChain.new!(%{llm: llm})
    |> LLMChain.add_messages(messages)
  end

  describe "extract_model_name/1" do
    test "extracts model name from string" do
      assert AgentObs.LangChain.extract_model_name("gpt-4o") == "gpt-4o"
    end

    test "extracts model name from ChatAnthropic struct" do
      llm = struct!(ChatAnthropic, model: "claude-sonnet-4-5-20250929")
      assert AgentObs.LangChain.extract_model_name(llm) == "anthropic/claude-sonnet-4-5-20250929"
    end

    test "extracts model name from ChatOpenAI struct" do
      llm = struct!(ChatOpenAI, model: "gpt-4o")
      assert AgentObs.LangChain.extract_model_name(llm) == "openai/gpt-4o"
    end

    test "extracts model name from ChatGoogleAI struct" do
      llm = struct!(ChatGoogleAI, model: "gemini-2.0-flash")
      assert AgentObs.LangChain.extract_model_name(llm) == "google/gemini-2.0-flash"
    end

    test "falls back to inspect for unknown types" do
      result = AgentObs.LangChain.extract_model_name(%{not_a_struct: true})
      assert is_binary(result)
    end
  end

  describe "callbacks/0" do
    test "returns a map with expected callback keys" do
      cb = AgentObs.LangChain.callbacks()

      assert is_map(cb)
      assert Map.has_key?(cb, :on_llm_token_usage)
      assert Map.has_key?(cb, :on_message_processed)
      assert Map.has_key?(cb, :on_tool_response_created)
      assert Map.has_key?(cb, :on_tool_execution_started)
      assert Map.has_key?(cb, :on_tool_execution_completed)
      assert Map.has_key?(cb, :on_tool_execution_failed)
    end

    test "all callbacks are functions" do
      cb = AgentObs.LangChain.callbacks()

      Enum.each(cb, fn {_key, fun} ->
        assert is_function(fun)
      end)
    end

    test "callbacks with trace_tools: false omits tool callbacks" do
      cb = AgentObs.LangChain.callbacks(trace_tools: false)

      assert Map.has_key?(cb, :on_llm_token_usage)
      assert Map.has_key?(cb, :on_message_processed)
      refute Map.has_key?(cb, :on_tool_execution_started)
      refute Map.has_key?(cb, :on_tool_execution_completed)
      refute Map.has_key?(cb, :on_tool_execution_failed)
    end

    test "on_message_processed + on_llm_token_usage emits [:agent_obs, :llm, :start/stop] events" do
      cb = AgentObs.LangChain.callbacks()

      handler_id = "test-langchain-token-usage-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:agent_obs, :llm, :start],
          [:agent_obs, :llm, :stop]
        ],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      chain = mock_chain(messages: [Message.new_user!("Hi")])
      # Add assistant message to chain like LangChain does before firing callback
      chain = LLMChain.add_message(chain, Message.new_assistant!("Hello!"))

      cb.on_message_processed.(chain, Message.new_assistant!("Hello!"))

      token_usage = TokenUsage.new!(%{input: 10, output: 5})
      cb.on_llm_token_usage.(chain, token_usage)

      # :start is emitted by on_message_processed with model from chain.llm
      assert_receive {:telemetry_event, [:agent_obs, :llm, :start], %{},
                      %{model: "openai/gpt-4o"}}

      assert_receive {:telemetry_event, [:agent_obs, :llm, :stop], _measurements,
                      %{tokens: %{prompt: 10, completion: 5, total: 15}}}

      :telemetry.detach(handler_id)
    end

    test "on_message_processed callback tracks messages for LLM events" do
      cb = AgentObs.LangChain.callbacks()

      handler_id = "test-langchain-message-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:agent_obs, :llm, :start],
          [:agent_obs, :llm, :stop]
        ],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      chain =
        mock_chain(messages: [Message.new_user!("Hi")])
        |> LLMChain.add_message(Message.new_assistant!("Hello!"))

      message = Message.new_assistant!("Hello!")
      cb.on_message_processed.(chain, message)

      # Message is tracked; :stop emitted when token usage arrives
      token_usage = TokenUsage.new!(%{input: 10, output: 5})
      cb.on_llm_token_usage.(chain, token_usage)

      # Start event fires on on_message_processed with input messages extracted from chain
      assert_receive {:telemetry_event, [:agent_obs, :llm, :start], %{},
                      %{input_messages: [%{role: "user", content: "Hi"}]}}

      # Messages appear as output_messages in the stop event
      assert_receive {:telemetry_event, [:agent_obs, :llm, :stop], _measurements,
                      %{output_messages: [%{role: "assistant", content: "Hello!"}]}}

      :telemetry.detach(handler_id)
    end

    test "callbacks accept :metadata option" do
      cb = AgentObs.LangChain.callbacks(metadata: %{agent_name: "test_agent"})

      handler_id = "test-langchain-metadata-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:agent_obs, :llm, :start],
        fn _event_name, _measurements, metadata, _config ->
          send(self(), {:start_meta, metadata})
        end,
        nil
      )

      chain =
        mock_chain()
        |> LLMChain.add_message(Message.new_assistant!("Hi"))

      cb.on_message_processed.(chain, Message.new_assistant!("Hi"))

      assert_receive {:start_meta, %{metadata: %{agent_name: "test_agent"}}}

      # Clean up the LLM span (fire token usage to close it)
      cb.on_llm_token_usage.(chain, TokenUsage.new!(%{input: 1, output: 1}))

      :telemetry.detach(handler_id)
    end

    test "callbacks with :model option emits correct model in events" do
      cb = AgentObs.LangChain.callbacks(model: "openai/gpt-4o")

      handler_id = "test-langchain-model-opt-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:agent_obs, :llm, :start],
          [:agent_obs, :llm, :stop]
        ],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      chain =
        mock_chain()
        |> LLMChain.add_message(Message.new_assistant!("Hello!"))

      cb.on_message_processed.(chain, Message.new_assistant!("Hello!"))

      token_usage = TokenUsage.new!(%{input: 15, output: 8})
      cb.on_llm_token_usage.(chain, token_usage)

      # :model override takes precedence over chain.llm
      assert_receive {:telemetry_event, [:agent_obs, :llm, :start], %{},
                      %{model: "openai/gpt-4o"}}

      assert_receive {:telemetry_event, [:agent_obs, :llm, :stop], _measurements,
                      %{tokens: %{prompt: 15, completion: 8, total: 23}}}

      :telemetry.detach(handler_id)
    end

    test "callbacks reset state between LLM iterations" do
      cb = AgentObs.LangChain.callbacks(model: "openai/gpt-4o")

      handler_id = "test-langchain-reset-#{System.unique_integer()}"

      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:agent_obs, :llm, :stop],
        fn _event_name, _measurements, metadata, _config ->
          send(test_pid, {:stop_event, metadata})
        end,
        nil
      )

      chain_a =
        mock_chain(messages: [Message.new_user!("Q1")])
        |> LLMChain.add_message(Message.new_assistant!("Response A"))

      # Iteration 1: message A
      cb.on_message_processed.(chain_a, Message.new_assistant!("Response A"))
      cb.on_llm_token_usage.(chain_a, TokenUsage.new!(%{input: 10, output: 5}))

      assert_receive {:stop_event, stop_meta_1}
      assert [%{role: "assistant", content: "Response A"}] = stop_meta_1.output_messages

      chain_b =
        mock_chain(messages: [Message.new_user!("Q2")])
        |> LLMChain.add_message(Message.new_assistant!("Response B"))

      # Iteration 2: message B (state should have been reset)
      cb.on_message_processed.(chain_b, Message.new_assistant!("Response B"))
      cb.on_llm_token_usage.(chain_b, TokenUsage.new!(%{input: 20, output: 10}))

      assert_receive {:stop_event, stop_meta_2}
      # Should only contain message B, not A+B
      assert [%{role: "assistant", content: "Response B"}] = stop_meta_2.output_messages

      :telemetry.detach(handler_id)
    end
  end

  describe "tool tracing via callbacks" do
    test "tool execution start/complete emits tool telemetry events" do
      cb = AgentObs.LangChain.callbacks()

      handler_id = "test-langchain-tool-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:agent_obs, :tool, :start],
          [:agent_obs, :tool, :stop]
        ],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      tool_call =
        ToolCall.new!(%{
          call_id: "call_123",
          name: "calculator",
          arguments: %{"x" => 2},
          status: :complete
        })

      function =
        Function.new!(%{
          name: "calculator",
          function: fn _args, _ctx -> {:ok, "result"} end
        })

      tool_result =
        ToolResult.new!(%{
          tool_call_id: "call_123",
          name: "calculator",
          content: "4"
        })

      # Simulate the callback sequence
      cb.on_tool_execution_started.(nil, tool_call, function)
      cb.on_tool_execution_completed.(nil, tool_call, tool_result)

      assert_receive {:telemetry_event, [:agent_obs, :tool, :start], %{},
                      %{name: "calculator", arguments: %{"x" => 2}}}

      assert_receive {:telemetry_event, [:agent_obs, :tool, :stop], _measurements, %{result: "4"}}

      :telemetry.detach(handler_id)
    end

    test "tool execution start/failed emits tool telemetry events" do
      cb = AgentObs.LangChain.callbacks()

      handler_id = "test-langchain-tool-fail-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:agent_obs, :tool, :start],
          [:agent_obs, :tool, :stop]
        ],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      tool_call =
        ToolCall.new!(%{
          call_id: "call_456",
          name: "search",
          arguments: %{"query" => "test"},
          status: :complete
        })

      function =
        Function.new!(%{
          name: "search",
          function: fn _args, _ctx -> {:ok, "result"} end
        })

      # Simulate the callback sequence with failure
      cb.on_tool_execution_started.(nil, tool_call, function)
      cb.on_tool_execution_failed.(nil, tool_call, "API timeout")

      assert_receive {:telemetry_event, [:agent_obs, :tool, :start], %{},
                      %{name: "search", arguments: %{"query" => "test"}}}

      assert_receive {:telemetry_event, [:agent_obs, :tool, :stop], _measurements, %{error: _}}

      :telemetry.detach(handler_id)
    end
  end

  describe "instrument/2" do
    test "returns chain with callbacks added" do
      chain =
        LLMChain.new!(%{
          llm: ChatOpenAI.new!(%{model: "gpt-4o"})
        })

      instrumented = AgentObs.LangChain.instrument(chain)

      assert is_struct(instrumented, LLMChain)
      # The chain should have callbacks added
      assert length(instrumented.callbacks) > length(chain.callbacks)
    end

    test "accepts :trace_tools option" do
      chain =
        LLMChain.new!(%{
          llm: ChatOpenAI.new!(%{model: "gpt-4o"})
        })

      # Should not raise
      _instrumented = AgentObs.LangChain.instrument(chain, trace_tools: false)
      _instrumented = AgentObs.LangChain.instrument(chain, trace_tools: true)
    end

    test "accepts :parent_ctx option" do
      chain =
        LLMChain.new!(%{
          llm: ChatOpenAI.new!(%{model: "gpt-4o"})
        })

      parent_ctx = OpenTelemetry.Ctx.get_current()
      _instrumented = AgentObs.LangChain.instrument(chain, parent_ctx: parent_ctx)
    end

    test "accepts :metadata option" do
      chain =
        LLMChain.new!(%{
          llm: ChatOpenAI.new!(%{model: "gpt-4o"})
        })

      _instrumented =
        AgentObs.LangChain.instrument(chain, metadata: %{agent_name: "linkage_agent"})
    end

    test "instrument/2 can be called multiple times (additive callbacks)" do
      chain =
        LLMChain.new!(%{
          llm: ChatOpenAI.new!(%{model: "gpt-4o"})
        })

      original_count = length(chain.callbacks)
      instrumented_once = AgentObs.LangChain.instrument(chain)
      instrumented_twice = AgentObs.LangChain.instrument(instrumented_once)

      # Each call to instrument/2 adds one callback map
      assert length(instrumented_once.callbacks) == original_count + 1
      assert length(instrumented_twice.callbacks) == original_count + 2
    end

    test "instrument/2 emits proper telemetry events with model name from chain" do
      chain =
        LLMChain.new!(%{
          llm: ChatOpenAI.new!(%{model: "gpt-4o"})
        })

      instrumented = AgentObs.LangChain.instrument(chain)

      handler_id = "test-instrument-model-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:agent_obs, :llm, :start],
          [:agent_obs, :llm, :stop]
        ],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      # Get the last callback added by instrument/2
      cb = List.last(instrumented.callbacks)

      # Simulate a message followed by token usage (like a real LLM call)
      # The chain passed to callbacks should have the assistant message already added
      chain_with_msg = LLMChain.add_message(chain, Message.new_assistant!("Hi there"))
      cb.on_message_processed.(chain_with_msg, Message.new_assistant!("Hi there"))
      cb.on_llm_token_usage.(chain_with_msg, TokenUsage.new!(%{input: 12, output: 6}))

      assert_receive {:telemetry_event, [:agent_obs, :llm, :start], %{},
                      %{model: "openai/gpt-4o"}}

      assert_receive {:telemetry_event, [:agent_obs, :llm, :stop], _measurements,
                      %{tokens: %{prompt: 12, completion: 6, total: 18}}}

      :telemetry.detach(handler_id)
    end
  end

  describe "run/2" do
    test "returns error tuple when LLMChain.run fails" do
      # Use a chain with no valid API key to trigger an error
      chain =
        LLMChain.new!(%{
          llm: ChatOpenAI.new!(%{model: "gpt-4o"})
        })

      result = AgentObs.LangChain.run(chain)

      assert {:error, _chain, _error} = result
    end

    test "run! raises on error" do
      assert_raise RuntimeError, ~r/LangChain.run failed/, fn ->
        chain =
          LLMChain.new!(%{
            llm: ChatOpenAI.new!(%{model: "gpt-4o"})
          })

        AgentObs.LangChain.run!(chain)
      end
    end

    test "run/2 with while_needs_response emits telemetry events" do
      handler_id = "test-wnr-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [[:agent_obs, :llm, :start], [:agent_obs, :llm, :stop], [:agent_obs, :llm, :exception]],
        fn event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      chain =
        LLMChain.new!(%{
          llm: ChatOpenAI.new!(%{model: "gpt-4o"})
        })

      # This will fail due to no API key, but telemetry events should still fire
      result = AgentObs.LangChain.run(chain, mode: :while_needs_response)

      assert {:error, _chain, _error} = result

      # The outer trace_llm span should emit a start event with the model name
      assert_receive {:telemetry_event, [:agent_obs, :llm, :start], _, %{model: "openai/gpt-4o"}}

      # We should get either a stop or exception event for the outer span
      assert_receive {:telemetry_event, event_name, _, _}
                     when event_name in [
                            [:agent_obs, :llm, :stop],
                            [:agent_obs, :llm, :exception]
                          ]

      :telemetry.detach(handler_id)
    end
  end

  describe "message normalization" do
    test "normalizes assistant message to map with string role" do
      cb = AgentObs.LangChain.callbacks()

      handler_id = "test-langchain-normalize-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:agent_obs, :llm, :stop],
        fn _event_name, _measurements, metadata, _config ->
          send(self(), {:output_messages, metadata.output_messages})
        end,
        nil
      )

      chain =
        mock_chain(messages: [Message.new_user!("Hi")])
        |> LLMChain.add_message(Message.new_assistant!("Hello!"))

      cb.on_message_processed.(chain, Message.new_assistant!("Hello!"))
      cb.on_llm_token_usage.(chain, TokenUsage.new!(%{input: 1, output: 1}))

      assert_receive {:output_messages, [%{role: "assistant", content: "Hello!"}]}

      :telemetry.detach(handler_id)
    end

    test "normalizes assistant message with tool calls" do
      tool_call =
        ToolCall.new!(%{
          call_id: "call_abc",
          name: "search",
          arguments: %{"q" => "test"},
          status: :complete
        })

      message =
        Message.new_assistant!(%{
          content: "Let me search",
          tool_calls: [tool_call]
        })

      cb = AgentObs.LangChain.callbacks()

      handler_id = "test-langchain-normalize-tc-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:agent_obs, :llm, :stop],
        fn _event_name, _measurements, metadata, _config ->
          send(self(), {:output_messages, metadata.output_messages})
        end,
        nil
      )

      chain =
        mock_chain(messages: [Message.new_user!("Search")])
        |> LLMChain.add_message(message)

      # Assistant with tool calls — span stays open, close via on_tool_response_created
      cb.on_message_processed.(chain, message)
      cb.on_llm_token_usage.(chain, TokenUsage.new!(%{input: 1, output: 1}))
      # Simulate tool response to close the span
      cb.on_tool_response_created.(chain, Message.new_tool_result!(%{tool_results: []}))

      assert_receive {:output_messages, [normalized | _]}
      assert normalized.role == "assistant"
      assert normalized.content == "Let me search"

      assert [%{id: "call_abc", name: "search", arguments: %{"q" => "test"}}] =
               normalized.tool_calls

      :telemetry.detach(handler_id)
    end

    test "input messages extracted from chain" do
      cb = AgentObs.LangChain.callbacks()

      handler_id = "test-langchain-normalize-input-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:agent_obs, :llm, :start],
        fn _event_name, _measurements, metadata, _config ->
          send(self(), {:input_messages, metadata.input_messages})
        end,
        nil
      )

      chain =
        mock_chain(
          messages: [
            Message.new_system!("You are helpful."),
            Message.new_user!("Hello!")
          ]
        )
        |> LLMChain.add_message(Message.new_assistant!("Hi!"))

      cb.on_message_processed.(chain, Message.new_assistant!("Hi!"))

      assert_receive {:input_messages, input_msgs}

      assert [%{role: "system", content: "You are helpful."}, %{role: "user", content: "Hello!"}] =
               input_msgs

      # Clean up
      cb.on_llm_token_usage.(chain, TokenUsage.new!(%{input: 1, output: 1}))

      :telemetry.detach(handler_id)
    end
  end

  describe "token usage extraction" do
    test "extracts tokens from TokenUsage struct" do
      cb = AgentObs.LangChain.callbacks()

      handler_id = "test-langchain-tokens-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:agent_obs, :llm, :stop],
        fn _event_name, _measurements, metadata, _config ->
          send(self(), {:tokens, metadata.tokens})
        end,
        nil
      )

      chain =
        mock_chain(messages: [Message.new_user!("Hi")])
        |> LLMChain.add_message(Message.new_assistant!("Hello"))

      cb.on_message_processed.(chain, Message.new_assistant!("Hello"))
      cb.on_llm_token_usage.(chain, TokenUsage.new!(%{input: 100, output: 50}))

      assert_receive {:tokens, %{prompt: 100, completion: 50, total: 150}}

      :telemetry.detach(handler_id)
    end

    test "handles TokenUsage with zero values" do
      cb = AgentObs.LangChain.callbacks()

      handler_id = "test-langchain-tokens-zero-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:agent_obs, :llm, :stop],
        fn _event_name, _measurements, metadata, _config ->
          send(self(), {:tokens, metadata.tokens})
        end,
        nil
      )

      chain =
        mock_chain(messages: [Message.new_user!("Hi")])
        |> LLMChain.add_message(Message.new_assistant!("Hello"))

      cb.on_message_processed.(chain, Message.new_assistant!("Hello"))
      cb.on_llm_token_usage.(chain, TokenUsage.new!(%{input: 0, output: 0}))

      assert_receive {:tokens, %{prompt: 0, completion: 0, total: 0}}

      :telemetry.detach(handler_id)
    end

    test "handles nil token usage gracefully" do
      cb = AgentObs.LangChain.callbacks()

      handler_id = "test-langchain-tokens-nil-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:agent_obs, :llm, :stop],
        fn _event_name, _measurements, metadata, _config ->
          send(self(), {:tokens, metadata.tokens})
        end,
        nil
      )

      chain =
        mock_chain(messages: [Message.new_user!("Hi")])
        |> LLMChain.add_message(Message.new_assistant!("Hello"))

      cb.on_message_processed.(chain, Message.new_assistant!("Hello"))
      cb.on_llm_token_usage.(chain, nil)

      assert_receive {:tokens, %{prompt: 0, completion: 0, total: 0}}

      :telemetry.detach(handler_id)
    end
  end
end

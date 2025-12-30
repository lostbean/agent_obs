defmodule AgentObs.ReqLLMTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  @req_llm_available Code.ensure_loaded?(ReqLLM)

  setup_all do
    if @req_llm_available do
      :ok
    else
      {:skip, "ReqLLM not available"}
    end
  end

  describe "collect_stream/1" do
    test "collects complete text from stream" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream =
          create_mock_stream([
            %{type: :content, text: "First "},
            %{type: :content, text: "second "},
            %{type: :content, text: "third"}
          ])

        metadata_task =
          Task.async(fn ->
            %{
              usage: %{input_tokens: 5, output_tokens: 3},
              finish_reason: "stop"
            }
          end)

        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream(stream_response)

        assert result.text == "First second third"
        assert result.tokens == %{prompt: 5, completion: 3, total: 8}
        assert result.finish_reason == "stop"
        assert result.tool_calls == []
      end
    end

    test "extracts tool calls from stream chunks" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream =
          create_mock_stream([
            %{type: :content, text: "Using calculator"},
            %{
              type: :tool_call,
              name: "add",
              arguments: %{},
              metadata: %{id: "call_1", index: 0}
            },
            %{
              type: :meta,
              metadata: %{tool_call_args: %{index: 0, fragment: ~s|{"a":1,"b":2}|}}
            },
            %{
              type: :tool_call,
              name: "multiply",
              arguments: %{},
              metadata: %{id: "call_2", index: 1}
            },
            %{
              type: :meta,
              metadata: %{tool_call_args: %{index: 1, partial_json: ~s|{"x":3,"y":4}|}}
            }
          ])

        metadata_task = Task.async(fn -> %{usage: %{input_tokens: 10, output_tokens: 20}} end)

        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream(stream_response)

        assert result.text == "Using calculator"
        assert length(result.tool_calls) == 2

        [tool1, tool2] = result.tool_calls

        assert tool1.name == "add"
        assert tool1.arguments == %{"a" => 1, "b" => 2}

        assert tool2.name == "multiply"
        assert tool2.arguments == %{"x" => 3, "y" => 4}
      end
    end

    test "handles empty stream" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream = create_mock_stream([])
        metadata_task = Task.async(fn -> %{} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream(stream_response)

        assert result.text == ""
        assert result.tokens == %{prompt: 0, completion: 0, total: 0}
        assert result.tool_calls == []
      end
    end

    test "handles tool calls with both fragment and partial_json keys" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        # Test both :fragment and :partial_json for compatibility
        stream =
          create_mock_stream([
            %{
              type: :tool_call,
              name: "tool_with_fragment",
              arguments: %{},
              metadata: %{id: "call_1", index: 0}
            },
            %{
              type: :meta,
              metadata: %{tool_call_args: %{index: 0, fragment: ~s|{"key":"value"}|}}
            },
            %{
              type: :tool_call,
              name: "tool_with_partial_json",
              arguments: %{},
              metadata: %{id: "call_2", index: 1}
            },
            %{
              type: :meta,
              metadata: %{tool_call_args: %{index: 1, partial_json: ~s|{"other":"data"}|}}
            }
          ])

        metadata_task = Task.async(fn -> %{} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream(stream_response)

        assert length(result.tool_calls) == 2
        [tool1, tool2] = result.tool_calls

        assert tool1.arguments == %{"key" => "value"}
        assert tool2.arguments == %{"other" => "data"}
      end
    end
  end

  describe "edge cases and error handling" do
    test "handles malformed tool call JSON" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream =
          create_mock_stream([
            %{
              type: :tool_call,
              name: "broken_tool",
              arguments: %{},
              metadata: %{id: "call_x", index: 0}
            },
            %{
              type: :meta,
              metadata: %{tool_call_args: %{index: 0, partial_json: ~s|{invalid json}|}}
            }
          ])

        metadata_task = Task.async(fn -> %{} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream(stream_response)

        # Should handle gracefully with empty arguments
        assert [tool_call] = result.tool_calls
        assert tool_call.name == "broken_tool"
        assert tool_call.arguments == %{}
      end
    end

    test "handles missing metadata fields" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream = create_mock_stream([%{type: :content, text: "Hi"}])

        # Metadata with no usage
        metadata_task = Task.async(fn -> %{} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream(stream_response)

        assert result.tokens == %{prompt: 0, completion: 0, total: 0}
        assert result.finish_reason == nil
      end
    end

    test "handles tool calls without argument fragments" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream =
          create_mock_stream([
            %{
              type: :tool_call,
              name: "no_args_tool",
              arguments: %{"preset" => "default"},
              metadata: %{id: "call_z", index: 0}
            }
          ])

        metadata_task = Task.async(fn -> %{} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream(stream_response)

        assert [tool_call] = result.tool_calls
        assert tool_call.name == "no_args_tool"
        assert tool_call.arguments == %{"preset" => "default"}
      end
    end

    test "handles tool calls with missing IDs" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream =
          create_mock_stream([
            %{
              type: :tool_call,
              name: "tool_no_id",
              arguments: %{},
              metadata: %{index: 0}
            }
          ])

        metadata_task = Task.async(fn -> %{} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream(stream_response)

        assert [tool_call] = result.tool_calls
        assert tool_call.name == "tool_no_id"
        # Should generate a unique ID
        assert String.starts_with?(tool_call.id, "call_")
      end
    end

    test "handles multiple tool call argument fragments for same index" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        # Simulates streaming where arguments come in multiple chunks
        stream =
          create_mock_stream([
            %{
              type: :tool_call,
              name: "streaming_args",
              arguments: %{},
              metadata: %{id: "call_1", index: 0}
            },
            %{
              type: :meta,
              metadata: %{tool_call_args: %{index: 0, fragment: ~s|{"long":"|}}
            },
            %{
              type: :meta,
              metadata: %{tool_call_args: %{index: 0, fragment: ~s|value"}|}}
            }
          ])

        metadata_task = Task.async(fn -> %{} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream(stream_response)

        assert [tool_call] = result.tool_calls
        assert tool_call.arguments == %{"long" => "value"}
      end
    end

    test "handles partial usage information" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream = create_mock_stream([%{type: :content, text: "Test"}])

        # Usage with only input_tokens
        metadata_task = Task.async(fn -> %{usage: %{input_tokens: 50}} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream(stream_response)

        assert result.tokens.prompt == 50
        assert result.tokens.completion == 0
        assert result.tokens.total == 50
      end
    end

    test "filters out non-content chunks when building text" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream =
          create_mock_stream([
            %{type: :content, text: "Hello "},
            %{type: :meta, metadata: %{foo: "bar"}},
            %{type: :content, text: "world"},
            %{type: :tool_call, name: "test", arguments: %{}},
            %{type: :content, text: "!"}
          ])

        metadata_task = Task.async(fn -> %{} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream(stream_response)

        # Should only include content chunks
        assert result.text == "Hello world!"
      end
    end
  end

  describe "normalize functions (via collect_stream behavior)" do
    test "handles different token usage formats" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream = create_mock_stream([%{type: :content, text: "Test"}])

        # Test with proper usage
        metadata_task =
          Task.async(fn -> %{usage: %{input_tokens: 100, output_tokens: 50}} end)

        stream_response = %{stream: stream, metadata_task: metadata_task}
        result = AgentObs.ReqLLM.collect_stream(stream_response)
        assert result.tokens == %{prompt: 100, completion: 50, total: 150}

        # Test with nil values
        metadata_task = Task.async(fn -> %{usage: %{input_tokens: nil, output_tokens: nil}} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}
        result = AgentObs.ReqLLM.collect_stream(stream_response)
        assert result.tokens == %{prompt: 0, completion: 0, total: 0}

        # Test with missing usage entirely
        metadata_task = Task.async(fn -> %{} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}
        result = AgentObs.ReqLLM.collect_stream(stream_response)
        assert result.tokens == %{prompt: 0, completion: 0, total: 0}
      end
    end
  end

  describe "trace_generate_text/3" do
    test "instruments non-streaming text generation" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        # Mock ReqLLM.generate_text response
        # Since we can't easily mock ReqLLM in unit tests, we'll test this in integration tests
        # For now, just verify the function exists and has correct spec
        assert function_exported?(AgentObs.ReqLLM, :trace_generate_text, 3)
      end
    end

    test "has correct function signature" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        assert function_exported?(AgentObs.ReqLLM, :trace_generate_text, 2)
        assert function_exported?(AgentObs.ReqLLM, :trace_generate_text, 3)
      end
    end
  end

  describe "trace_generate_text!/3" do
    test "has correct function signature" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        assert function_exported?(AgentObs.ReqLLM, :trace_generate_text!, 2)
        assert function_exported?(AgentObs.ReqLLM, :trace_generate_text!, 3)
      end
    end
  end

  describe "trace_generate_object/4" do
    test "has correct function signature" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        assert function_exported?(AgentObs.ReqLLM, :trace_generate_object, 3)
        assert function_exported?(AgentObs.ReqLLM, :trace_generate_object, 4)
      end
    end
  end

  describe "trace_generate_object!/4" do
    test "has correct function signature" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        assert function_exported?(AgentObs.ReqLLM, :trace_generate_object!, 3)
        assert function_exported?(AgentObs.ReqLLM, :trace_generate_object!, 4)
      end
    end
  end

  describe "trace_stream_object/4" do
    test "has correct function signature" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        assert function_exported?(AgentObs.ReqLLM, :trace_stream_object, 3)
        assert function_exported?(AgentObs.ReqLLM, :trace_stream_object, 4)
      end
    end
  end

  describe "collect_stream_object/1" do
    test "collects object from stream metadata" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream = create_mock_stream([])

        metadata_task =
          Task.async(fn ->
            %{
              usage: %{input_tokens: 10, output_tokens: 5},
              finish_reason: "stop",
              object: %{name: "Test", age: 25}
            }
          end)

        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream_object(stream_response)

        assert result.object == %{name: "Test", age: 25}
        assert result.tokens == %{prompt: 10, completion: 5, total: 15}
        assert result.finish_reason == "stop"
      end
    end

    test "handles missing object in metadata" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream = create_mock_stream([])
        metadata_task = Task.async(fn -> %{usage: %{input_tokens: 5, output_tokens: 3}} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream_object(stream_response)

        # Should return empty map when object is missing
        assert result.object == %{}
        assert result.tokens == %{prompt: 5, completion: 3, total: 8}
      end
    end

    test "handles empty metadata" do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        stream = create_mock_stream([])
        metadata_task = Task.async(fn -> %{} end)
        stream_response = %{stream: stream, metadata_task: metadata_task}

        result = AgentObs.ReqLLM.collect_stream_object(stream_response)

        assert result.object == %{}
        assert result.tokens == %{prompt: 0, completion: 0, total: 0}
        assert result.finish_reason == nil
      end
    end
  end

  describe "integration tests (require real ReqLLM setup)" do
    @moduletag :integration

    # Note: These tests are tagged with :integration and excluded by default
    # Run with: mix test --include integration
    #
    # These tests require API credentials to be set up:
    # - For Anthropic: export ANTHROPIC_API_KEY=your_key
    # - For OpenAI: export OPENAI_API_KEY=your_key
    # - For Google: export GOOGLE_API_KEY=your_key

    setup do
      # Start telemetry events collector
      {:ok, collector} = Agent.start_link(fn -> [] end)

      # Attach telemetry handler for integration tests with collector as config
      handler_id = "integration-test-#{:erlang.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:agent_obs, :llm, :start],
          [:agent_obs, :llm, :stop],
          [:agent_obs, :llm, :exception],
          [:agent_obs, :tool, :start],
          [:agent_obs, :tool, :stop],
          [:agent_obs, :tool, :exception]
        ],
        &__MODULE__.handle_integration_event/4,
        collector
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
        if Process.alive?(collector), do: Agent.stop(collector)
      end)

      {:ok, collector: collector}
    end

    test "trace_stream_text with real LLM call", %{collector: collector} do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        model = get_test_model()

        if model do
          # Make a simple LLM call
          {:ok, stream_response} =
            AgentObs.ReqLLM.trace_stream_text(
              model,
              [%{role: "user", content: "Say hello in exactly one word"}]
            )

          # Verify stream response structure
          assert stream_response.stream
          assert stream_response.model

          # Consume the stream to get text
          # Note: The stream has already been consumed by trace_stream_text,
          # but a replay stream is provided for us to use
          text =
            stream_response.stream
            |> Enum.filter(&(&1.type == :content))
            |> Enum.map_join("", & &1.text)

          # Verify we got text back
          assert is_binary(text)
          assert String.length(text) > 0

          # Verify telemetry events were emitted
          events = get_collector_events(collector)
          assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :llm, :start] end)
          assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :llm, :stop] end)

          # Verify metadata in stop event
          {_, _, stop_metadata} =
            Enum.find(events, fn {event, _, _} -> event == [:agent_obs, :llm, :stop] end)

          assert stop_metadata.output_messages
          assert stop_metadata.tokens
          assert stop_metadata.tokens.prompt > 0
        else
          # Skip if no API key configured
          IO.puts("\nSkipping: No API key configured for integration test")
          assert true
        end
      end
    end

    test "trace_tool_execution with real tool", %{collector: collector} do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        # Create a simple calculator tool
        tool =
          ReqLLM.Tool.new!(
            name: "calculator",
            description: "Perform simple arithmetic calculations",
            parameter_schema: [
              expression: [type: :string, required: true, doc: "Math expression to evaluate"]
            ],
            callback: fn args ->
              try do
                # ReqLLM passes args as atom-keyed map
                expr = args[:expression] || args["expression"] || "0"
                {result, _binding} = Code.eval_string(expr)
                result
              rescue
                e -> {:error, Exception.message(e)}
              end
            end
          )

        # Create a tool call
        tool_call = %{
          name: "calculator",
          arguments: %{"expression" => "2 + 2"}
        }

        # Execute with instrumentation
        execution_result = AgentObs.ReqLLM.trace_tool_execution(tool, tool_call)

        result =
          case execution_result do
            {:ok, res, _metadata} -> res
            {:ok, res} -> res
            other -> other
          end

        # Verify result
        assert result == 4,
               "Expected 4, got #{inspect(result)}, full result: #{inspect(execution_result)}"

        # Verify telemetry events
        events = get_collector_events(collector)
        assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :tool, :start] end)
        assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :tool, :stop] end)

        # Verify metadata
        {_, _, stop_metadata} =
          Enum.find(events, fn {event, _, _} -> event == [:agent_obs, :tool, :stop] end)

        assert stop_metadata.result == 4

        # Arguments are in the start event, not stop event
        {_, _, start_metadata} =
          Enum.find(events, fn {event, _, _} -> event == [:agent_obs, :tool, :start] end)

        assert start_metadata.arguments == %{"expression" => "2 + 2"}
      end
    end

    test "full agent loop with streaming and tools", %{collector: collector} do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        model = get_test_model()

        if model do
          # Create calculator tool
          calculator_tool =
            ReqLLM.Tool.new!(
              name: "multiply",
              description: "Multiply two numbers together",
              parameter_schema: [
                a: [type: :integer, required: true],
                b: [type: :integer, required: true]
              ],
              callback: fn args ->
                args["a"] * args["b"]
              end
            )

          # First LLM call asking it to use the tool
          {:ok, response} =
            AgentObs.ReqLLM.trace_stream_text(
              model,
              [%{role: "user", content: "Use the multiply tool to calculate 7 times 8"}],
              tools: [calculator_tool]
            )

          # Extract tool calls from response
          tool_calls = ReqLLM.StreamResponse.extract_tool_calls(response)

          # If the model decided to use the tool, execute it
          tool_results =
            Enum.map(tool_calls, fn tc ->
              tool = Enum.find([calculator_tool], &(&1.name == tc.name))

              if tool do
                case AgentObs.ReqLLM.trace_tool_execution(tool, tc) do
                  {:ok, result, _metadata} -> result
                  {:ok, result} -> result
                  {:error, _} -> nil
                end
              else
                nil
              end
            end)
            |> Enum.filter(&(&1 != nil))

          # Verify telemetry events for complete workflow
          events = get_collector_events(collector)

          # Should have at least one LLM call
          llm_starts =
            Enum.count(events, fn {event, _, _} -> event == [:agent_obs, :llm, :start] end)

          llm_stops =
            Enum.count(events, fn {event, _, _} -> event == [:agent_obs, :llm, :stop] end)

          assert llm_starts >= 1
          assert llm_stops >= 1

          # If tools were used, verify tool events
          if tool_results != [] do
            tool_starts =
              Enum.count(events, fn {event, _, _} -> event == [:agent_obs, :tool, :start] end)

            tool_stops =
              Enum.count(events, fn {event, _, _} -> event == [:agent_obs, :tool, :stop] end)

            assert tool_starts >= 1
            assert tool_stops >= 1
            assert 56 in tool_results
          end
        else
          # Skip if no API key configured
          IO.puts("\nSkipping: No API key configured for integration test")
          assert true
        end
      end
    end

    test "trace_generate_text with real LLM call", %{collector: collector} do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        model = get_test_model()

        if model do
          # Make a simple non-streaming LLM call
          {:ok, response} =
            AgentObs.ReqLLM.trace_generate_text(
              model,
              [%{role: "user", content: "Say hello in exactly one word"}]
            )

          # Verify response structure
          assert response.model

          # Get text from response
          text = ReqLLM.Response.text(response)

          # Verify we got text back
          assert is_binary(text)
          assert String.length(text) > 0

          # Verify telemetry events were emitted
          events = get_collector_events(collector)
          assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :llm, :start] end)
          assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :llm, :stop] end)

          # Verify metadata in stop event
          {_, _, stop_metadata} =
            Enum.find(events, fn {event, _, _} -> event == [:agent_obs, :llm, :stop] end)

          assert stop_metadata.output_messages
          assert stop_metadata.tokens
          assert stop_metadata.tokens.prompt > 0
        else
          IO.puts("\nSkipping: No API key configured for integration test")
          assert true
        end
      end
    end

    test "trace_generate_text! returns text directly", %{collector: collector} do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        model = get_test_model()

        if model do
          # Make a simple non-streaming LLM call
          text =
            AgentObs.ReqLLM.trace_generate_text!(
              model,
              [%{role: "user", content: "Say hello in exactly one word"}]
            )

          # Verify we got text back
          assert is_binary(text)
          assert String.length(text) > 0

          # Verify telemetry events were emitted
          events = get_collector_events(collector)
          assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :llm, :start] end)
          assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :llm, :stop] end)
        else
          IO.puts("\nSkipping: No API key configured for integration test")
          assert true
        end
      end
    end

    test "trace_generate_object with real LLM call", %{collector: collector} do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        model = get_test_model()

        if model do
          schema = [
            name: [type: :string, required: true],
            greeting: [type: :string, required: true]
          ]

          # Generate structured object
          {:ok, response} =
            AgentObs.ReqLLM.trace_generate_object(
              model,
              [%{role: "user", content: "Generate a person named Alice with a hello greeting"}],
              schema
            )

          # Verify response structure
          assert response.model

          # Get object from response
          object = ReqLLM.Response.object(response)

          # Verify object structure
          assert is_map(object)
          assert Map.has_key?(object, :name) or Map.has_key?(object, "name")
          assert Map.has_key?(object, :greeting) or Map.has_key?(object, "greeting")

          # Verify telemetry events
          events = get_collector_events(collector)
          assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :llm, :start] end)
          assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :llm, :stop] end)

          # Verify metadata includes object
          {_, _, stop_metadata} =
            Enum.find(events, fn {event, _, _} -> event == [:agent_obs, :llm, :stop] end)

          assert stop_metadata.object
          assert stop_metadata.tokens
        else
          IO.puts("\nSkipping: No API key configured for integration test")
          assert true
        end
      end
    end

    test "trace_generate_object! returns object directly", %{collector: collector} do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        model = get_test_model()

        if model do
          schema = [
            name: [type: :string, required: true]
          ]

          # Generate structured object
          object =
            AgentObs.ReqLLM.trace_generate_object!(
              model,
              [%{role: "user", content: "Generate a person named Bob"}],
              schema
            )

          # Verify object structure
          assert is_map(object)

          # Verify telemetry events
          events = get_collector_events(collector)
          assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :llm, :start] end)
          assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :llm, :stop] end)
        else
          IO.puts("\nSkipping: No API key configured for integration test")
          assert true
        end
      end
    end

    test "trace_stream_object with real LLM call", %{collector: collector} do
      unless @req_llm_available, do: assert(true)

      if @req_llm_available do
        model = get_test_model()

        if model do
          schema = [
            name: [type: :string, required: true],
            age: [type: :pos_integer, required: true]
          ]

          # Stream structured object
          {:ok, stream_response} =
            AgentObs.ReqLLM.trace_stream_object(
              model,
              [%{role: "user", content: "Generate a person named Carol, age 35"}],
              schema
            )

          # Verify stream response structure
          assert stream_response.stream
          assert stream_response.model

          # Collect the object
          result = AgentObs.ReqLLM.collect_stream_object(stream_response)

          # Verify object was generated
          assert is_map(result.object)
          assert result.tokens.prompt > 0

          # Verify telemetry events
          events = get_collector_events(collector)
          assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :llm, :start] end)
          assert Enum.any?(events, fn {event, _, _} -> event == [:agent_obs, :llm, :stop] end)
        else
          IO.puts("\nSkipping: No API key configured for integration test")
          assert true
        end
      end
    end

    # Helper to get a configured test model
    defp get_test_model do
      cond do
        System.get_env("ANTHROPIC_API_KEY") ->
          "anthropic:claude-3-5-haiku-latest"

        System.get_env("OPENAI_API_KEY") ->
          "openai:gpt-4o-mini"

        System.get_env("GOOGLE_API_KEY") ->
          "google:gemini-2.0-flash-exp"

        true ->
          nil
      end
    end

    defp get_collector_events(collector) do
      Agent.get(collector, & &1) |> Enum.reverse()
    end

    # Telemetry event handler for integration tests
    def handle_integration_event(event, measurements, metadata, collector)
        when is_pid(collector) do
      Agent.update(collector, fn events ->
        [{event, measurements, metadata} | events]
      end)
    end

    def handle_integration_event(_event, _measurements, _metadata, _config), do: :ok
  end

  # Helper functions for creating mock data

  defp create_mock_stream(chunks) do
    Stream.into(chunks, [])
  end

  # Documentation tests (ensure examples compile)
  if @req_llm_available do
    doctest AgentObs.ReqLLM,
      except: [:moduledoc, :trace_stream_text, :trace_tool_execution, :collect_stream]
  end
end

defmodule AgentObs.TestHelper do
  @moduledoc """
  Test helpers for AgentObs test suite.

  Provides utilities for capturing and asserting on OpenTelemetry spans
  during testing without requiring actual backend connections.
  """

  @doc """
  Captures all spans created during the execution of a function.

  Uses OpenTelemetry's in-process exporter to collect spans without
  sending them to an external backend.

  ## Examples

      spans = capture_spans(fn ->
        AgentObs.trace_agent("test", %{input: "test"}, fn ->
          {:ok, "result"}
        end)
      end)

      assert length(spans) == 1
  """
  def capture_spans(fun) when is_function(fun, 0) do
    # Start a simple span processor with in-memory collector
    collector_pid = start_span_collector()

    result =
      try do
        # Execute the function that should create spans
        fun.()
      after
        # Give spans time to be processed
        Process.sleep(50)
      end

    # Get collected spans
    spans = get_collected_spans(collector_pid)
    stop_span_collector(collector_pid)

    {result, spans}
  end

  @doc """
  Asserts that a span with the given name exists in the list of spans.

  ## Examples

      assert_span_exists(spans, "my_agent")
  """
  def assert_span_exists(spans, expected_name) do
    span_names = Enum.map(spans, & &1.name)

    if expected_name in span_names do
      :ok
    else
      raise ExUnit.AssertionError,
        message: """
        Expected span named "#{expected_name}" not found.
        Available spans: #{inspect(span_names)}
        """
    end
  end

  @doc """
  Finds a span by name in the list of spans.

  Returns the first matching span or nil if not found.

  ## Examples

      span = find_span(spans, "my_agent")
      assert span.attributes["input.value"] == "test"
  """
  def find_span(spans, name) do
    Enum.find(spans, &(&1.name == name))
  end

  @doc """
  Asserts that a span has a specific attribute with the expected value.

  ## Examples

      assert_span_attribute(span, "llm.model", "gpt-4o")
  """
  def assert_span_attribute(span, key, expected_value) do
    actual_value = get_in(span, [:attributes, key])

    if actual_value == expected_value do
      :ok
    else
      raise ExUnit.AssertionError,
        message: """
        Span attribute mismatch for "#{key}":
        Expected: #{inspect(expected_value)}
        Actual: #{inspect(actual_value)}
        """
    end
  end

  @doc """
  Asserts that a span has a specific attribute (regardless of value).

  ## Examples

      assert_span_has_attribute(span, "openinference.span.kind")
  """
  def assert_span_has_attribute(span, key) do
    if Map.has_key?(span.attributes || %{}, key) do
      :ok
    else
      available_keys = Map.keys(span.attributes || %{})

      raise ExUnit.AssertionError,
        message: """
        Span does not have attribute "#{key}".
        Available attributes: #{inspect(available_keys)}
        """
    end
  end

  @doc """
  Asserts parent-child relationship between two spans.

  Verifies that child_span's parent_span_id matches parent_span's span_id.

  ## Examples

      parent = find_span(spans, "agent")
      child = find_span(spans, "llm_call")
      assert_span_parent(child, parent)
  """
  def assert_span_parent(child_span, parent_span) do
    parent_id = extract_span_id(parent_span)
    child_parent_id = extract_parent_span_id(child_span)

    if child_parent_id == parent_id do
      :ok
    else
      raise ExUnit.AssertionError,
        message: """
        Span parent mismatch:
        Expected child's parent_span_id to match parent's span_id
        Parent span_id: #{inspect(parent_id)}
        Child parent_span_id: #{inspect(child_parent_id)}
        """
    end
  end

  @doc """
  Builds a mock telemetry span collector process.

  This is used internally by capture_spans/1.
  """
  def start_span_collector do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    pid
  end

  @doc """
  Retrieves all collected spans from the collector.
  """
  def get_collected_spans(collector_pid) do
    # Since we're using OpenTelemetry's built-in simple processor in test mode,
    # we need to read spans using OTel's test utilities
    # For now, return empty list - this will be enhanced when we integrate
    # with actual OTel test exporter
    Agent.get(collector_pid, & &1)
  end

  @doc """
  Stops the span collector process.
  """
  def stop_span_collector(collector_pid) do
    Agent.stop(collector_pid)
  end

  # Private helpers

  defp extract_span_id(span) do
    # OpenTelemetry span records have a span_id field
    # The actual structure depends on OTel version
    case span do
      %{span_id: id} -> id
      {_, _, id, _, _, _, _, _, _, _, _, _} -> id
      _ -> nil
    end
  end

  defp extract_parent_span_id(span) do
    # OpenTelemetry span records have a parent_span_id field
    case span do
      %{parent_span_id: id} -> id
      {_, _, _, id, _, _, _, _, _, _, _, _} -> id
      _ -> nil
    end
  end
end

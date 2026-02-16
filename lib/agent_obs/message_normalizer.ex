defmodule AgentObs.MessageNormalizer do
  @moduledoc false

  # Shared message normalization helpers for LangChain and Sagents integrations.
  # Converts LangChain Message structs to plain maps with string roles
  # suitable for AgentObs telemetry metadata.

  @doc false
  def normalize_messages(messages) when is_list(messages) do
    Enum.map(messages, &normalize_message/1)
  end

  def normalize_messages(_), do: []

  @doc false
  def normalize_message(message) when is_struct(message) do
    role = normalize_role(Map.get(message, :role))
    content = normalize_content(Map.get(message, :content))

    # For tool result messages, synthesize content from tool_results when content is empty
    content =
      if content == "" and role == "tool" do
        case Map.get(message, :tool_results) do
          results when is_list(results) and results != [] ->
            Enum.map_join(results, "\n", &format_tool_result/1)

          _ ->
            content
        end
      else
        content
      end

    base = %{role: role, content: content}

    base
    |> maybe_add_tool_calls(Map.get(message, :tool_calls))
    |> maybe_add_tool_results(Map.get(message, :tool_results))
  end

  def normalize_message(%{role: _, content: _} = message), do: message
  def normalize_message(other), do: %{role: "unknown", content: inspect(other)}

  @doc false
  def format_tool_result(tool_result) when is_struct(tool_result) do
    content = Map.get(tool_result, :content)

    cond do
      is_binary(content) -> content
      is_list(content) -> format_content_parts(content)
      true -> inspect(tool_result)
    end
  end

  def format_tool_result(tool_result) when is_binary(tool_result), do: tool_result
  def format_tool_result(tool_result), do: inspect(tool_result)

  # -- Private --

  defp normalize_role(role) when is_atom(role), do: to_string(role)
  defp normalize_role(role) when is_binary(role), do: role
  defp normalize_role(_), do: "unknown"

  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content) when is_list(content), do: format_content_parts(content)
  defp normalize_content(nil), do: ""
  defp normalize_content(other), do: inspect(other)

  defp maybe_add_tool_calls(base, nil), do: base
  defp maybe_add_tool_calls(base, []), do: base

  defp maybe_add_tool_calls(base, tool_calls) when is_list(tool_calls) do
    Map.put(base, :tool_calls, Enum.map(tool_calls, &normalize_tool_call/1))
  end

  defp normalize_tool_call(tc) when is_struct(tc) do
    %{
      id: Map.get(tc, :call_id, ""),
      name: Map.get(tc, :name, ""),
      arguments: Map.get(tc, :arguments, %{})
    }
  end

  defp normalize_tool_call(tc) when is_map(tc), do: tc
  defp normalize_tool_call(tc), do: %{name: inspect(tc)}

  defp maybe_add_tool_results(base, nil), do: base
  defp maybe_add_tool_results(base, []), do: base

  defp maybe_add_tool_results(base, tool_results) when is_list(tool_results) do
    Map.put(base, :tool_results, Enum.map(tool_results, &normalize_tool_result/1))
  end

  defp normalize_tool_result(tr) when is_struct(tr) do
    %{
      tool_call_id: Map.get(tr, :tool_call_id, ""),
      content: format_tool_result(tr)
    }
  end

  defp normalize_tool_result(tr) when is_map(tr), do: tr
  defp normalize_tool_result(tr), do: %{content: inspect(tr)}

  defp format_content_parts(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{type: :text, content: text} when is_binary(text) -> text
      %{content: text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      part when is_binary(part) -> part
      _part -> ""
    end)
  end
end

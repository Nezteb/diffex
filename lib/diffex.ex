defmodule Diffex do
  @moduledoc """
  A dependency-free module for computing minimal diffs between nested maps/structs.

  Returns a diff describing operations needed to transform the first argument
  into the second argument.
  """

  @type diff_op :: :added | :removed | :changed
  @type diff_value ::
          {diff_op, any()}
          | {diff_op, any(), any()}
          | %{optional(any()) => diff_value}

  @doc """
  Computes the minimal diff between two maps or structs.

  ## Return format

  Returns a map where each key maps to one of:
  - `{:added, new_value}` - key exists only in `new`
  - `{:removed, old_value}` - key exists only in `old`
  - `{:changed, old_value, new_value}` - scalar value changed
  - `%{...}` - nested diff for nested maps/structs

  Returns an empty map `%{}` if there are no differences.

  ## Examples

      iex> MapDiff.diff(%{a: 1, b: 2}, %{a: 1, b: 3})
      %{b: {:changed, 2, 3}}

      iex> MapDiff.diff(%{a: 1}, %{a: 1, b: 2})
      %{b: {:added, 2}}

      iex> MapDiff.diff(%{a: %{x: 1, y: 2}}, %{a: %{x: 1, y: 3}})
      %{a: %{y: {:changed, 2, 3}}}
  """
  @spec diff(map(), map()) :: %{optional(any()) => diff_value()}
  def diff(old, new) when is_struct(old) and is_struct(new) do
    diff(Map.from_struct(old), Map.from_struct(new))
  end

  def diff(old, new) when is_map(old) and is_map(new) do
    old_keys = Map.keys(old) |> MapSet.new()
    new_keys = Map.keys(new) |> MapSet.new()

    removed_keys = MapSet.difference(old_keys, new_keys)
    added_keys = MapSet.difference(new_keys, old_keys)
    common_keys = MapSet.intersection(old_keys, new_keys)

    diff = %{}

    # Handle removed keys
    diff =
      Enum.reduce(removed_keys, diff, fn key, acc ->
        Map.put(acc, key, {:removed, Map.get(old, key)})
      end)

    # Handle added keys
    diff =
      Enum.reduce(added_keys, diff, fn key, acc ->
        Map.put(acc, key, {:added, Map.get(new, key)})
      end)

    # Handle common keys - check for changes
    Enum.reduce(common_keys, diff, fn key, acc ->
      old_val = Map.get(old, key)
      new_val = Map.get(new, key)

      case diff_values(old_val, new_val) do
        :equal -> acc
        change -> Map.put(acc, key, change)
      end
    end)
  end

  # Compare two values and return the appropriate diff representation
  defp diff_values(same, same), do: :equal

  defp diff_values(old_val, new_val) when is_map(old_val) and is_map(new_val) do
    nested_diff = diff(old_val, new_val)

    if map_size(nested_diff) == 0 do
      :equal
    else
      nested_diff
    end
  end

  defp diff_values(old_val, new_val) do
    {:changed, old_val, new_val}
  end

  @doc """
  Counts the number of changes between two maps/structs directly.

  ## Examples

      iex> MapDiff.count_changes(%{a: 1, b: 2}, %{a: 1, b: 3, c: 4})
      2
  """
  @spec count_changes(map(), map()) :: non_neg_integer()
  def count_changes(old, new) when is_map(old) and is_map(new) do
    diff(old, new) |> count_changes()
  end

  @doc """
  Counts the total number of changes in a diff, including nested changes.

  Each `:added`, `:removed`, or `:changed` operation counts as 1.
  Nested diffs are traversed recursively to count their leaf operations.

  ## Examples

      iex> MapDiff.diff(%{a: 1, b: 2}, %{a: 1, b: 3}) |> MapDiff.count_changes()
      1

      iex> MapDiff.diff(%{a: 1}, %{b: 2}) |> MapDiff.count_changes()
      2

      iex> MapDiff.diff(
      ...>   %{user: %{name: "Alice", age: 30}},
      ...>   %{user: %{name: "Bob", age: 31}}
      ...> ) |> MapDiff.count_changes()
      2
  """
  @spec count_changes(%{optional(any()) => diff_value()}) :: non_neg_integer()
  def count_changes(diff) when is_map(diff) do
    Enum.reduce(diff, 0, fn {_key, operation}, acc ->
      acc + count_operation(operation)
    end)
  end

  defp count_operation({:added, _value}), do: 1
  defp count_operation({:removed, _value}), do: 1
  defp count_operation({:changed, _old, _new}), do: 1
  defp count_operation(nested_diff) when is_map(nested_diff), do: count_changes(nested_diff)

  @doc """
  Applies a diff to a map/struct, returning the transformed result.

  Validates that `:changed` operations match the expected "before" value.
  Returns `{:ok, result}` on success, or `{:error, reason}` if validation fails.

  ## Examples

      iex> diff = %{b: {:changed, 2, 3}}
      iex> MapDiff.apply_diff(%{a: 1, b: 2}, diff)
      {:ok, %{a: 1, b: 3}}

      iex> diff = %{b: {:changed, 2, 3}}
      iex> MapDiff.apply_diff(%{a: 1, b: 999}, diff)
      {:error, {:value_mismatch, :b, %{expected: 2, actual: 999}}}
  """
  @spec apply_diff(map(), %{optional(any()) => diff_value()}) ::
          {:ok, map()} | {:error, {:value_mismatch, any(), map()}}

  def apply_diff(original, diff) when is_struct(original) do
    struct_module = original.__struct__

    case apply_diff(Map.from_struct(original), diff) do
      {:ok, result} -> {:ok, struct(struct_module, result)}
      {:error, _} = error -> error
    end
  end

  def apply_diff(original, diff) when is_map(original) and is_map(diff) do
    apply_diff_reduce(Map.to_list(diff), original)
  end

  defp apply_diff_reduce([], acc), do: {:ok, acc}

  defp apply_diff_reduce([{key, operation} | rest], acc) do
    case apply_operation(acc, key, operation) do
      {:ok, new_acc} -> apply_diff_reduce(rest, new_acc)
      {:error, _} = error -> error
    end
  end

  defp apply_operation(acc, key, {:added, value}) do
    {:ok, Map.put(acc, key, value)}
  end

  defp apply_operation(acc, key, {:removed, _value}) do
    {:ok, Map.delete(acc, key)}
  end

  defp apply_operation(acc, key, {:changed, expected_old, new}) do
    actual_old = Map.get(acc, key)

    if actual_old == expected_old do
      {:ok, Map.put(acc, key, new)}
    else
      {:error, {:value_mismatch, key, %{expected: expected_old, actual: actual_old}}}
    end
  end

  defp apply_operation(acc, key, nested_diff) when is_map(nested_diff) do
    old_nested = Map.get(acc, key, %{})

    case apply_diff(old_nested, nested_diff) do
      {:ok, new_nested} ->
        {:ok, Map.put(acc, key, new_nested)}

      {:error, {:value_mismatch, nested_key, details}} ->
        # Prepend the current key to create a path
        {:error, {:value_mismatch, [key | List.wrap(nested_key)], details}}
    end
  end

  @doc """
  Returns true if there are no differences between the two maps.

  ## Examples

      iex> MapDiff.equal?(%{a: 1}, %{a: 1})
      true

      iex> MapDiff.equal?(%{a: 1}, %{a: 2})
      false
  """
  @spec equal?(map(), map()) :: boolean()
  def equal?(old, new) do
    diff(old, new) |> map_size() == 0
  end

  @doc """
  Returns a human-readable summary of the diff.

  ## Examples

      iex> MapDiff.diff(%{a: 1, b: 2}, %{a: 1, c: 3}) |> MapDiff.summarize()
      ["added :c (value: 3)", "removed :b (was: 2)"]
  """
  @spec summarize(map(), list(any())) :: [String.t()]
  def summarize(diff, path \\ []) do
    Enum.flat_map(diff, fn {key, operation} ->
      current_path = path ++ [key]
      path_str = format_path(current_path)

      case operation do
        {:added, value} ->
          ["added #{path_str} (value: #{inspect(value)})"]

        {:removed, value} ->
          ["removed #{path_str} (was: #{inspect(value)})"]

        {:changed, old, new} ->
          ["changed #{path_str} from #{inspect(old)} to #{inspect(new)}"]

        nested_diff when is_map(nested_diff) ->
          summarize(nested_diff, current_path)
      end
    end)
  end

  defp format_path([single]), do: inspect(single)
  defp format_path(path), do: Enum.map_join(path, ".", &inspect/1)
end

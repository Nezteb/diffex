defmodule Diffex do
  @moduledoc """
  A dependency-free module for computing minimal diffs between nested maps/structs.

  Returns a diff describing operations needed to transform the first argument
  into the second argument.

  Lists, tuples, and other non-map values are treated as opaque scalars — they
  are compared with `==` and reported as `{:changed, old, new}` rather than
  diffed structurally.
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

      iex> Diffex.diff(%{a: 1, b: 2}, %{a: 1, b: 3})
      %{b: {:changed, 2, 3}}

      iex> Diffex.diff(%{a: 1}, %{a: 1, b: 2})
      %{b: {:added, 2}}

      iex> Diffex.diff(%{a: %{x: 1, y: 2}}, %{a: %{x: 1, y: 3}})
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

    removed = Map.new(removed_keys, fn key -> {key, {:removed, Map.fetch!(old, key)}} end)
    added = Map.new(added_keys, fn key -> {key, {:added, Map.fetch!(new, key)}} end)

    common =
      Enum.reduce(common_keys, %{}, fn key, acc ->
        case diff_values(Map.fetch!(old, key), Map.fetch!(new, key)) do
          :equal -> acc
          change -> Map.put(acc, key, change)
        end
      end)

    Map.merge(removed, Map.merge(added, common))
  end

  defp diff_values(same, same), do: :equal

  defp diff_values(old_val, new_val) when is_map(old_val) and is_map(new_val) do
    nested_diff = diff(old_val, new_val)

    if nested_diff == %{} do
      :equal
    else
      nested_diff
    end
  end

  defp diff_values(old_val, new_val) do
    {:changed, old_val, new_val}
  end

  @doc """
  Counts the total number of changes in a diff, including nested changes.

  Each `:added`, `:removed`, or `:changed` operation counts as 1.
  Nested diffs are traversed recursively to count their leaf operations.

  ## Examples

      iex> Diffex.diff(%{a: 1, b: 2}, %{a: 1, b: 3}) |> Diffex.count_changes()
      1

      iex> Diffex.diff(%{a: 1}, %{b: 2}) |> Diffex.count_changes()
      2

      iex> Diffex.diff(
      ...>   %{user: %{name: "Alice", age: 30}},
      ...>   %{user: %{name: "Bob", age: 31}}
      ...> ) |> Diffex.count_changes()
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

  Validates that `:changed` and `:removed` operations match the expected "before" value.
  Returns `{:ok, result}` on success, or `{:error, reason}` if validation fails.

  ## Examples

      iex> diff = %{b: {:changed, 2, 3}}
      iex> Diffex.apply_diff(%{a: 1, b: 2}, diff)
      {:ok, %{a: 1, b: 3}}

      iex> diff = %{b: {:changed, 2, 3}}
      iex> Diffex.apply_diff(%{a: 1, b: 999}, diff)
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
    Enum.reduce_while(diff, {:ok, original}, fn {key, operation}, {:ok, acc} ->
      case apply_operation(acc, key, operation) do
        {:ok, new_acc} -> {:cont, {:ok, new_acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_operation(acc, key, {:added, value}) do
    {:ok, Map.put(acc, key, value)}
  end

  defp apply_operation(acc, key, {:removed, expected}) do
    actual = Map.get(acc, key)

    if actual == expected do
      {:ok, Map.delete(acc, key)}
    else
      {:error, {:value_mismatch, key, %{expected: expected, actual: actual}}}
    end
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
        {:error, {:value_mismatch, [key | List.wrap(nested_key)], details}}
    end
  end

  @doc """
  Returns true if there are no differences between the two maps.

  ## Examples

      iex> Diffex.equal?(%{a: 1}, %{a: 1})
      true

      iex> Diffex.equal?(%{a: 1}, %{a: 2})
      false
  """
  @spec equal?(map(), map()) :: boolean()
  def equal?(old, new) do
    diff(old, new) |> map_size() == 0
  end

  @doc """
  Returns a human-readable summary of the diff.

  ## Examples

      iex> Diffex.diff(%{a: 1, b: 2}, %{a: 1, c: 3}) |> Diffex.summarize()
      ["added :c (value: 3)", "removed :b (was: 2)"]
  """
  @spec summarize(map()) :: [String.t()]
  def summarize(diff), do: summarize(diff, [])

  defp summarize(diff, path) do
    Enum.flat_map(diff, fn {key, operation} ->
      current_path = path ++ [key]
      path_str = current_path |> Enum.map_join(".", &inspect/1)

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
end

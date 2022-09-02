defmodule Expression.Eval do
  @moduledoc """
  Expression.Eval is responsible for taking an abstract syntax
  tree (AST) as generated by Expression.Parser and evaluating it.

  At a high level, an AST consists of a Keyword list with two top-level
  keys, either `:text` or `:expression`.

  `Expression.eval!/3` will return the output for each entry in the Keyword
  list. `:text` entries are returned as regular strings. `:expression` entries
  are returned as typed values.

  The returned value is a list containing each.

  # Example

    iex(1)> Expression.Eval.eval!([text: "hello"], %{})
    ["hello"]
    iex(2)> Expression.Eval.eval!([text: "hello", expression: [literal: 1]], %{})
    ["hello", 1]
    iex(3)> Expression.Eval.eval!([
    ...(3)>   text: "hello",
    ...(3)>   expression: [literal: 1],
    ...(3)>   text: "ok",
    ...(3)>   expression: [literal: true]
    ...(3)> ], %{})
    ["hello", 1, "ok", true]

  """
  def eval!(ast, context, mod \\ Expression.Callbacks)

  def eval!({:expression, [ast]}, context, mod) do
    eval!(ast, context, mod)
  end

  def eval!({:atom, atom}, {:not_found, history}, _mod),
    do: {:not_found, history ++ [atom]}

  def eval!({:atom, atom}, context, _mod) do
    Map.get(context, atom, {:not_found, [atom]})
  end

  def eval!({:attribute, [{:attribute, ast}, literal: literal]}, context, mod) do
    # When we receive a key for an attribute, at times this could be a literal.
    # The assumption is that all attributes are going to be string based so if we receive
    # "@foo.123.bar", `123` will be parsed as a literal but the assumption is that the
    # context will look like:
    #
    # %{"foo" => %{
    #   "123" => %{   <--- notice the string key here
    #     "bar" => "the value"
    #   }
    # }}
    eval!({:attribute, [{:attribute, ast}, atom: to_string(literal)]}, context, mod)
  end

  def eval!({:attribute, ast}, context, mod) do
    Enum.reduce(ast, context, &eval!(&1, &2, mod))
  end

  def eval!({:function, opts}, context, mod) do
    name = opts[:name] || raise "Functions need a name"
    arguments = opts[:args] || []

    case mod.handle(name, arguments, context) do
      {:ok, value} -> value
      {:error, reason} -> "ERROR: #{inspect(reason)}"
    end
  end

  def eval!({:lambda, [{:args, ast}]}, context, mod) do
    fn arguments ->
      lambda_context = Map.put(context, "__captures", arguments)

      eval!(ast, lambda_context, mod)
    end
  end

  def eval!({:capture, index}, context, _mod) do
    Enum.at(Map.get(context, "__captures"), index - 1)
  end

  def eval!({:range, [first, last]}, _context, _mod),
    do: Range.new(first, last)

  def eval!({:range, [first, last, step]}, _context, _mod),
    do: Range.new(first, last, step)

  def eval!({:list, [{:args, ast}]}, context, mod) do
    ast
    |> Enum.reduce([], &[eval!(&1, context, mod) | &2])
    |> Enum.reverse()
    |> Enum.map(&not_founds_as_nil/1)
  end

  def eval!({:key, [subject_ast, key_ast]}, context, mod) do
    subject = eval!(subject_ast, context, mod)
    key = eval!(key_ast, context, mod)

    case key do
      index when is_number(index) -> get_in(subject, [Access.at(index)])
      range when is_struct(range, Range) -> Enum.slice(subject, range)
      binary when is_binary(binary) -> Map.get(subject, binary)
    end
  end

  def eval!({:literal, literal}, _context, _mod), do: literal
  def eval!({:text, text}, _context, _mod), do: text
  def eval!({:+, [a, b]}, ctx, mod), do: eval!(a, ctx, mod, :num) + eval!(b, ctx, mod, :num)
  def eval!({:-, [a, b]}, ctx, mod), do: eval!(a, ctx, mod, :num) - eval!(b, ctx, mod, :num)
  def eval!({:*, [a, b]}, ctx, mod), do: eval!(a, ctx, mod, :num) * eval!(b, ctx, mod, :num)
  def eval!({:/, [a, b]}, ctx, mod), do: eval!(a, ctx, mod, :num) / eval!(b, ctx, mod, :num)
  def eval!({:>, [a, b]}, ctx, mod), do: eval!(a, ctx, mod, :num) > eval!(b, ctx, mod, :num)
  def eval!({:>=, [a, b]}, ctx, mod), do: eval!(a, ctx, mod, :num) >= eval!(b, ctx, mod, :num)
  def eval!({:<, [a, b]}, ctx, mod), do: eval!(a, ctx, mod, :num) < eval!(b, ctx, mod, :num)
  def eval!({:<=, [a, b]}, ctx, mod), do: eval!(a, ctx, mod, :num) <= eval!(b, ctx, mod, :num)
  def eval!({:==, [a, b]}, ctx, mod), do: eval!(a, ctx, mod) == eval!(b, ctx, mod)
  def eval!({:!=, [a, b]}, ctx, mod), do: eval!(a, ctx, mod) != eval!(b, ctx, mod)
  def eval!({:^, [a, b]}, ctx, mod), do: :math.pow(eval!(a, ctx, mod), eval!(b, ctx, mod))
  def eval!({:&, [a, b]}, ctx, mod), do: [a, b] |> Enum.map_join("", &eval!(&1, ctx, mod))

  def eval!(ast, context, mod) do
    result =
      ast
      |> Enum.reduce([], fn ast, acc -> [eval!(ast, context, mod) | acc] end)
      |> Enum.reverse()

    case result do
      [result] -> result
      chunks -> chunks
    end
  end

  def not_founds_as_nil({:not_found, _}), do: nil
  def not_founds_as_nil(other), do: other

  defp eval!(ast, ctx, mod, type), do: ast |> eval!(ctx, mod) |> guard_type!(type)

  defp guard_type!(v, :num) when is_number(v) or is_struct(v, Decimal), do: v

  defp guard_type!({:not_found, attributes}, :num),
    do: raise("attribute is not found: `#{Enum.join(attributes, ".")}`")

  defp guard_type!(v, :num), do: raise("expression is not a number: `#{inspect(v)}`")
end

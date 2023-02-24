defmodule Expression.V2.Eval do
  @moduledoc """
  An evaluator for AST returned by Expression.V2.Parser.

  This reads the AST output returned by `Expression.V2.parse/1` and
  evaluates it according to the given variable bindings and functions
  available in the callback module specified.

  It does this by emitting valid Elixir AST, mimicking what `quote/2` does.

  The Elixir AST is then supplied to `Code.eval_quoted_with_env/3` without any
  binding Elixir evaluates it for us, reducing the need for us to ensure that our 
  eval is correct and instead relying on us to generate correct AST instead.

  What is returned is an anonymous function that accepts an Expression.V2.Context.t
  struct and evaluates the code against that context.

  The callback module referenced is inserted as the module for any function
  that is called. So if an expression uses a function called `foo(1, 2, 3)`
  then the callback's `callback/3` function will be called as follows:

  ```elixir
  MyProject.Callbacks.callback(context, "foo", [1, 2, 3])
  ```

  There is some special handling of some functions that either requires lazy
  loading or have specific Elixir AST syntax requirements.

  These are documented in the `to_quoted/2` function.
  """

  @doc """
  Accepts AST as emitted by `Expression.V2.parse/1` and returns an anonymous
  & pure function that accepts a Context.t as an argument and returns the result 
  of the expression against the given Context.
  """
  @spec compile([any], callback_module :: module) ::
          (Expression.V2.Context.t() -> [any])
  def compile(ast, callback_module) do
    # convert to valid Elixir AST
    quoted = wrap_in_context(to_quoted(ast, callback_module))

    {term, _binding, _env} = Code.eval_quoted_with_env(quoted, [], Code.env_for_eval([]))

    term
  end

  @doc """
  Wrap an AST block into an anonymous function that accepts
  a single argument called context.

  This happens _after_ all the code generation completes. The code
  generated expects a variable called `context` to exist, wrapping
  it in this function ensures that it does.

  This is the anonymous function that is returned to the caller.
  The caller is then responsible to call it with the correct context
  variables.
  """
  @spec wrap_in_context(Macro.t()) :: Macro.t()
  def wrap_in_context(quoted) do
    {:fn, [],
     [
       {:->, [],
        [
          [{:context, [], nil}],
          {:__block__, [],
           [
             quoted
           ]}
        ]}
     ]}
  end

  @doc """
  Convert the AST returned from `Expression.V2.parse/1` into valid Elixir AST
  that can be used by `Code.eval_quoted_with_env/3`.

  There is some special handling here:

  1. Lists are recursed to ensure that all list items are properly quoted.
  2. "\"Quoted strings\"" are unquoted and returned as regular strings to the AST.
  3. "Normal strings" are converted into Atoms and treated as such during eval.
  4. Literals such as numbers & booleans are left as is.
  5. Range.t items are converted to valid Elixir AST.
  6. `&` and `&1` captures are generated into valid Elixir AST captures.
  7. Any functions are generated as being function calls for the given callback module.
  """
  @spec to_quoted([term] | term, callback_module :: atom) :: Macro.t()
  def to_quoted(ast, callback_module) when is_list(ast) do
    quoted_block =
      Enum.reduce(ast, [], fn element, acc ->
        [quoted(element, callback_module) | acc]
      end)

    {:__block__, [], quoted_block}
  end

  defp quoted("\"" <> _ = binary, _callback_module) when is_binary(binary),
    do: String.replace(binary, "\"", "")

  defp quoted(number, _callback_module) when is_number(number), do: number
  defp quoted(boolean, _callback_module) when is_boolean(boolean), do: boolean

  defp quoted([:__property__, [a, b]], callback_module) when is_binary(b) do
    # When the property we're trying to read is a binary then we're doing
    # `foo.bar` in an expression and we convert this to a `Map.get(foo, "bar")`
    {{:., [], [{:__aliases__, [alias: false], [:Map]}, :get]}, [],
     [
       quoted(a, callback_module),
       b
     ]}
  end

  defp quoted([:__attribute__, [a, b]], callback_module) when is_integer(b) do
    # When the attribute we're trying to read is an integer then we're
    # trying to read an index off of a list.
    # `foo[1]` becomes `Enum.at(foo, 1)`
    {{:., [], [Enum, :at]}, [],
     [
       quoted(a, callback_module),
       quoted(b, callback_module)
     ]}
  end

  defp quoted([:__attribute__, [a, b]], callback_module) do
    # For any other attributes, we're assuming we just want to read
    # a property off of a Map so
    # `foo[bar]` becomes `Map.get(foo, bar)`
    # `foo["bar"]` becomse `Map.get(foo, "bar")` etc
    {{:., [], [Access, :get]}, [],
     [
       {{:., [], [Access, :get]}, [],
        [
          context_dot_vars(),
          a
        ]},
       quoted(b, callback_module)
     ]}
  end

  defp quoted(["if", [test, yes, no]], callback_module) do
    # This is not handled as a callback function in the callback module
    # because the arguments need to be evaluated lazily.
    {:if, [],
     [
       quoted(test, callback_module),
       [
         do: quoted(yes, callback_module),
         else: quoted(no, callback_module)
       ]
     ]}
  end

  defp quoted(["&", args], callback_module) do
    # Rather than generating the regular Elixir anonymous short hand functions
    # using & and &1 etc we write out a full anonymous function and rewrite
    # the &1 place holders to `arg1` etc.
    #
    # This allows us to support nested anonymous functions when Elixir does
    # not allow that.
    function_ast = Enum.map(args, &quoted(&1, callback_module))

    {function_ast, capture_vars} =
      Macro.prewalk(function_ast, [], fn
        {:&, [], [index]}, acc when is_integer(index) ->
          var = {:"arg#{index}", [], nil}
          {var, [var | acc]}

        other, acc ->
          {other, acc}
      end)

    {:fn, [],
     [
       {:->, [],
        [
          capture_vars,
          {:__block__, [], function_ast}
        ]}
     ]}
  end

  defp quoted("&" <> index, _callback_module) do
    {:&, [], [String.to_integer(index)]}
  end

  defp quoted([function_name, arguments], callback_module)
       when is_binary(function_name) and is_list(arguments) do
    module_as_atoms =
      callback_module
      |> Module.split()
      |> Enum.map(&String.to_existing_atom/1)

    {{:., [], [{:__aliases__, [alias: false], module_as_atoms}, :callback]}, [],
     [
       {:context, [], nil},
       function_name,
       Enum.map(arguments, &quoted(&1, callback_module))
     ]}
  end

  defp quoted(list, callback_module) when is_list(list) do
    Enum.map(list, &quoted(&1, callback_module))
  end

  defp quoted(atom, _callback_module) when is_binary(atom) do
    {{:., [], [{:__aliases__, [alias: false], [:Map]}, :get]}, [],
     [
       {{:., [], [{:context, [], nil}, :vars]}, [no_parens: true], []},
       atom
     ]}
  end

  defp quoted(%Range{first: first, last: last, step: step}, _callback_module) do
    {:%, [],
     [
       {:__aliases__, [], [:Range]},
       {:%{}, [], [first: first, last: last, step: step]}
     ]}
  end

  defp context_dot_vars() do
    {{:., [], [{:context, [], nil}, :vars]}, [no_parens: true], []}
  end
end

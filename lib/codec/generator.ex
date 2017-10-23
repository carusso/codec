defmodule Codec.Generator do
  @moduledoc """
    Main module that contains the macro used to create the encode() and decode() functions

    [Documentation can be found here](https://github.com/carusso/codec/blob/master/README.md)
  """

  require Logger

  defmacro __using__(_opts) do
    quote do
      import Codec.Generator
      import Codec.BinType
    end
  end

  defmacro make_encoder_decoder(macro_opts \\ [], do: do_clause) do
    # We do a tree walk to build up some basic info, like the bit field clause list
    # as well as the bit shifting we'll need to do for split fields.
    acc = %{ previous_sizes: %{}, fields: [] } # Accumulator for prewalk
    {_block, %{ fields: fields } } = Macro.prewalk do_clause, acc, &gather_field_list/2
    {_block, current_module} = Macro.prewalk do_clause, nil, &get_module_name/2
    current_module = if !current_module, do: __MODULE__, else: current_module

    # Pull the list of non-hidden bit field names
    key_list = Enum.filter(fields, &(!&1.hidden)) |> Enum.map(&(&1.name))
    unique_key_list = Enum.uniq key_list
    # Build a count of how many times each unique bit field name is used
    kl_count = Enum.map unique_key_list, fn item -> Enum.count key_list, &(&1 == item) end
    field_counts = Enum.zip unique_key_list, kl_count

    # replace duplicate field atoms with <atom>_1, <atom>_2, etc.
    {fields, _} = Enum.map_reduce fields, %{},
                        fn(x, acc) -> update_for_splits(x, acc, field_counts) end

    # Create a map that can be used to grab any field. It will be keyed by the :name field
    fields_map = Enum.reduce fields, %{}, &(Map.put(&2, &1[:name], &1))

    # create the reassembly code for split fields <atom>_1, etc.
    # This AST is used in the decoder
    split_fields = Enum.filter(field_counts, &(elem(&1, 1) > 1)) |> Enum.map(&(elem(&1, 0)))
    split_ast_string = Enum.reduce split_fields, "", fn(x, acc) ->
                                acc <> decoder_reassembly_little(x, acc, fields) end

    # run it through Code.string_to_quoted to get {:ok, quoted_string}
    # that we can inject into the decoder before the bit field stanza
    # This code section creates temporary variables that shift and split
    # the fields in the map into separate bit fields to be injected into
    # their proper places within the bit field stanza
    {:ok, split_field_decode_decl} = Code.string_to_quoted split_ast_string

    # add a size field to any field that's missing it.  It should normally only
    # be on the payload of a given packet.  This way we can have bit fields with
    # a size after the payload, like say a crc().  Otherwise, Elixir fails to
    # compile the decoder with a " binary field without size is only allowed at
    # the end of a binary pattern" message.  It may be that I'll need to change
    # this part of the code to only worry about the size field if the payload
    # is not the last field in the pattern.
    # It's worth noting that if I discover I have to parse a variable length
    # packet where the payload varies, this code will have to be fixed.
    total_bit_size = Enum.reduce fields, 0, &((&1[:size] || 0) + &2)
    total_byte_size = div(total_bit_size, 8)
    dec_fields = Enum.map fields, fn field ->
                        elem = case field[:elem] do
                                  [{:payload, _, nil}, {:binary, _, nil}] ->
                                    [{:payload, [], nil},
                                     {:-, [], [
                                        {:binary, [], nil},
                                        {:size, [], [{:size_left, [], nil}]}
                                      ]}
                                    ]

                                  elem ->
                                    elem
                                end
                        put_in field[:elem], elem
                      end
    size_left_ast = {:=, [], [
                      {:size_left, [], nil},
                      {:-, [], [
                        {:byte_size, [], [{:packet, [], nil}]},
                        total_byte_size
                      ]}
                    ]}
    # We only need the size_left field declared if there was a payload in the decoder
    # ... that only happened where dec_fields was modified above
    size_left_ast = if fields != dec_fields, do: size_left_ast

    # reserved fields need to be replaced with _ in order to avoid parser errors
    dec_fields = Enum.map dec_fields, fn
                            %{elem: [{:reserved, _, nil}, size]}=field ->
                              put_in field[:elem], [{:_, [], nil}, size]
                            field       -> field
                          end
    # reassemble the elem fields into the bit field representation we can feed
    # back to the quote function
    new_do_clause = Enum.map dec_fields, &({:::, [], &1[:elem]})
    new_do_clause = {:<<>>, [], new_do_clause}
    do_clause_decode = {:__block__, [], [
                          size_left_ast,
                          {:=, [], [new_do_clause, {:packet, [], nil}]}
                        ]}

    # create the disassembly code for split fields in the decoder.
    # This code section creates temporary variables that rejoin multiple bit fields
    # into the fields of the returned map.
    split_ast_string = Enum.reduce split_fields, "", fn(x, acc) ->
                                acc <> encoder_splitter_little(x, acc, fields) end
    {:ok, split_field_encode_decl} = Code.string_to_quoted split_ast_string

    # Encoder functions are called at runtime and the results are put in the my map
    # so that they will be placed in the proper place in the bit stanza
    encode_func_fields = Enum.filter fields, &(get_custom_type(:encode_func, &1[:elem]))
    encode_func_calls_ast =
      if length(encode_func_fields) > 0 do
        build_set_map_string = fn (field, acc) ->
              str = field[:name]
              macro_string = Macro.to_string get_custom_type(:encode_func, field[:elem])
              acc <> " #{str}: #{macro_string},"
            end
        encode_func_calls_str = Enum.reduce(encode_func_fields, "my = %{my| ", build_set_map_string) <> "}"
        case Code.string_to_quoted encode_func_calls_str do
          {:ok, result} ->
            result
          {:error, _error} ->
            raise "Error creating map of values for encoder: #{encode_func_calls_str}"
            nil
        end
      end

    # Pull out the call_on_encoded entries for packet size and crc type calculations
    call_on_encoded_fields = Enum.filter fields, &(get_custom_type(:call_on_encoded, &1[:elem]))
    fields = fields -- call_on_encoded_fields  # Pull out custom field
    #call_on_encoded = nil
    call_on_encoded_clause =
      if length(call_on_encoded_fields) > 0 do
        if length(call_on_encoded_fields) > 1, do: raise "More than one call_on_encoded field in a codec routine is not supported"
        [call_on_encoded_field] = call_on_encoded_fields
        is_little_fn = fn
                {:little, _opts, _list}=ast, _acc -> {ast, true}
                ast, acc                          -> {ast, acc}
              end
        {_block, is_little } = Macro.prewalk call_on_encoded_field[:elem], false, is_little_fn
        endian = if is_little, do: :little, else: :big
        case get_custom_type(:call_on_encoded, call_on_encoded_field[:elem]) do
          {call_type, call_where} ->
            clauses =   [
                          {:::, [], [{call_type, [], [{:out, [], nil}]},
                              {:-, [], [{endian, [], nil}, call_on_encoded_field[:size]]}]}, #{:integer, [], nil}
                          {:::, [], [{:out, [], nil}, {:binary, [], nil}]}
                        ]
            case call_where do
              :before -> {:<<>>, [], clauses}
              :after  -> {:<<>>, [], Enum.reverse(clauses)}
            end
          _ -> nil
        end
      end

    # Add the "my." prefix to all of the encoding fields (not hidden, not split)
    enc_fields = Enum.map fields, &add_my_prefix/1
    do_clause_encode = Enum.map enc_fields, &({:::, [], &1[:elem]})
    do_clause_encode =
      if call_on_encoded_clause do
        {:=, [],
         [
          {:out, [], nil},
          {:<<>>, [], do_clause_encode}
         ]}
      else
        {:<<>>, [], do_clause_encode}
      end
    # TODO: This is a good method for eliminating the nils in the quoted parts of
    # the macro.  Maybe I should use it for all parts
    encode_block_elems = [do_clause_encode, call_on_encoded_clause]
    encode_clauses = Enum.filter encode_block_elems, &(&1)
    # If we have encode_func_calls or call_on_encoded calls, we add them to a __block__
    # for the encoder clause
    do_clause_encode = if length(encode_clauses) > 1, do: {:__block__, [], encode_clauses}, else: do_clause_encode

    # zero out any fields that aren't part of the struct... just :reserved?
    # Only put the reserved field in there if needed
    something_hidden = Enum.find_value fields, &(&1[:hidden])
    fields_fields = if something_hidden, do: [:reserved], else: []
    fields_zero_string = Enum.map_join fields_fields, "\n", &("#{&1} = 0")
    {:ok, fields_zero_decl} = Code.string_to_quoted fields_zero_string

    # create the structure declaration, including defaults
    # create the struct declaration body from the unique keys and default values
    struct_decl = Enum.map unique_key_list, &({&1, get_field_default(&1, fields)})

    # Determine the decode_func keys and code
    build_set_map_string = fn (key, acc) ->
          str = Atom.to_string key
          field = fields_map[key]
          str2 = case get_custom_type(:decode_func, field[:elem]) do
                  nil -> str
                  macro ->
                    Macro.to_string macro
                end
          acc <> " #{str}: #{str2},"
        end
    set_map_string = Enum.reduce(unique_key_list, "%{my| ", build_set_map_string) <> "}"
    set_map_decl = case Code.string_to_quoted set_map_string do
      {:ok, set_map_decl} ->
        set_map_decl
      {:error, _error} ->
        raise "Error creating map of values for decoder: #{set_map_string}"
        nil
    end
    set_map_string2 = "Map.put(bndl, #{current_module}, #{set_map_string})"
    set_map_decl2 = case Code.string_to_quoted set_map_string2 do
      {:ok, result} ->
        result
      {:error, _error} ->
        raise "Error creating map of values for decoder2: #{set_map_string}"
        nil
    end

    # This is ugly, but I didn't have an easy way to disable the payload variable
    # when it wasn't needed for some invocations of the encode() function - so
    # I create one of two different versions depending upon the need of a payload
    # variable.
    # It would be nice to clean this up a bit, but I'd have to experiment more
    # with macros TODO
    uses_payload = Enum.find_value fields, &(&1[:name] == :payload)
    quoted_encode =
      if uses_payload do
        quote do
          def encode(var!(payload), var!(my)) do
            use Bitwise
            unquote(fields_zero_decl)
            unquote(encode_func_calls_ast)
            unquote(split_field_encode_decl)
            unquote(do_clause_encode)
          end
        end
      else
          quote do
            def encode(var!(_payload), var!(my)) do
              use Bitwise
              unquote(fields_zero_decl)
              unquote(encode_func_calls_ast)
              unquote(split_field_encode_decl)
              unquote(do_clause_encode)
            end
          end
      end


    # This is the section of the macro that generates the struct as well as the
    # encode() and decode() functions.
    full_ast =
      quote do
        defmodule S do
          defstruct unquote(struct_decl)
        end

        unquote(quoted_encode)

        def decode(var!(packet), var!(my) \\ %__MODULE__.S{}) do
          use Bitwise
          unquote(do_clause_decode)
          unquote(split_field_decode_decl)
          unquote(set_map_decl)
        end

        def decode2(var!(bndl), var!(packet), var!(my) \\ %__MODULE__.S{}) do
          use Bitwise
          unquote(do_clause_decode)
          unquote(split_field_decode_decl)
          unquote(set_map_decl2)
        end
      end

    if Keyword.get(macro_opts, :debug) == :final_ast do
      Logger.debug "Encoder:\n#{inspect(full_ast, pretty: true)}"
    end
    full_ast
  end


###############  Private Functions  ################
  defp add_my_prefix(field) do
    if field[:hidden] == false and field[:split] == false and field[:name] != :payload do
      [tuple, rest] = field.elem
      field_key = elem tuple, 0
      tuple = {{:., [], [{:my, [], nil}, field_key]}, [], []}
      put_in field[:elem], [tuple, rest]
    else
      field
    end
  end

  defp get_field_default(field_key, fields) do
    Enum.find_value fields, 0, &(&1[:orig_name] == field_key && &1[:default])
  end

  defp decoder_reassemble_one_little(field) do
    if (field[:shift] > 0) do
      "(#{field[:name]} <<< #{field[:shift]})"
    else
      "#{field[:name]}"
    end
  end

  defp decoder_reassembly_little(field_key, _, fields) do
    # field = print one out <> #print the rest out \n
    fields = Enum.filter fields, &(&1.orig_name == field_key)
    "#{field_key} = " <>
      Enum.map_join(fields, " + ", &decoder_reassemble_one_little/1) <>
      "\n"
  end

  defp encoder_disassemble_one_little(field) do
    use Bitwise
    mask = 0xFFFF >>> (16 - field[:size] - field[:shift])
    if (field[:shift] > 0) do
      "#{field[:name]} = (my.#{field[:orig_name]} &&& #{mask}) >>> #{field[:shift]}"
    else
      "#{field[:name]} = my.#{field[:orig_name]} &&& #{mask}"
    end
  end

  # field_1 = my.field &&& 0x00FF
  # field_2 = (my.field &&& 0x0F00) >>> 8
  defp encoder_splitter_little(field_key, _, fields) do
    fields = Enum.filter fields, &(&1.orig_name == field_key)
    Enum.map_join(fields, "\n", &encoder_disassemble_one_little/1) <> "\n"
  end

  # When multiple keys have the same name, that's an indicator in the DSL that
  # the value for the key is split into multiple parts.  This function handles
  # renaming those duplicate keys by adding a _1, _2, _3, etc. as well as
  # updating other relevant state variables
  defp update_for_splits(field, tracker, field_counts) do
    [tuple, rest] = field.elem
    field_key = elem tuple, 0
    case field_counts[field_key] do
      count when is_integer(count) and count > 1 ->
        suffix = tracker[field_key] || 1
        orig_name = field[:name]
        new_name = Atom.to_string(orig_name) <> "_" <> Integer.to_string(suffix)
        new_key = String.to_atom(new_name)
        tuple = put_elem tuple, 0, new_key
        field = %{field | elem: [tuple, rest], name: new_key}
        field = put_in field[:split], true
        tracker = put_in tracker[field_key], suffix + 1
        {field, tracker}
      _count ->
        field = put_in field[:split], false
        {field, tracker}
    end
  end


  # {:=, [line: 5],
  # [{:module, [line: 5], nil}, {:__aliases__, [counter: 0, line: 5], [:CHCP]}]}
  defp get_module_name({:=, _opts, [{:module, _, _}, {:__aliases__, _, module_list}]}=ast, _) do
    {ast, Module.concat module_list}
  end
  defp get_module_name(ast, acc) do
    {ast, acc}
  end

  # This function is handed to the AST traversal routine and in particular pulls
  # out the clauses with the :: operator in the bitfield specifiers.  It assembles
  # some basic information for each element thus identified.
  defp gather_field_list({:::, _opts, list}=ast, acc) do
    %{ previous_sizes: previous_sizes, fields: fields } = acc
    [{field_atom, _, nil}, _] = list
    rec = %{name: field_atom,
            orig_name: field_atom,
            hidden: (field_atom == :reserved), # hide payload? || field_atom == :payload),
            elem: list,
            default: (get_custom_type(:default, list) || 0),
            size: get_size(list),
            shift: (previous_sizes[field_atom] || 0) + (get_custom_type(:add_shift, list) || 0)
          }
    previous_sizes = Map.put previous_sizes, field_atom, rec.shift + (rec.size || 0)
    fields = fields ++ [rec]
    {ast, %{acc | previous_sizes: previous_sizes, fields: fields}}
  end
  defp gather_field_list(ast, acc) do
    {ast, acc}
  end



 # Accepts an atom as a type that will match against any type specifier macro function
 # with a name that matches the atom.  Returns the arguments for that macro.  Used to
 # get the default() values, custom_type values, etc.
 defp get_custom_type(type, [head|tail]) do  # Process the top level list or sub argument lists
   get_custom_type(type, head) || get_custom_type(type, tail)
 end
 defp get_custom_type(type, {xtype, _, [custom_args]}) when xtype == type, do: custom_args # Found a custom specifier
 # more arg lists may embed custom specifier
 defp get_custom_type(type, {_, _, list}) when is_list(list), do: get_custom_type(type, list)
 defp get_custom_type(_, _), do: nil  # Nothing else matched, should be a fail on this section

  # This next function takes the argument list from the AST of the ::: atom,
  # which means that they will be the field name to the left of the :: and the
  # bit specifiers to the right of it.
  defp get_size({:size, _, [bit_size]}) when is_integer(bit_size), do: bit_size # explicit size()
  defp get_size({:-, _, [_, bit_size]}) when is_integer(bit_size), do: bit_size # size on right of -
  defp get_size({:-, _, [bit_size, _]}) when is_integer(bit_size), do: bit_size # size on left of -
  defp get_size([tuple, bit_size]) when is_tuple(tuple) and is_integer(bit_size), do: bit_size # size as only right arg to ::
  defp get_size({_, _, list}) when is_list(list), do: get_size(list) # nested tuple meaning multiple -s
  defp get_size([head|tail]) do
    result = get_size(head)
    if result, do: result, else: get_size(tail)
  end
  defp get_size(_), do: nil # Nothing else matched, should fail on this section

  def millis_since_1970() do
    {mega, sec, micro} = :erlang.timestamp()
    micros = (mega * 1_000_000 + sec) * 1_000_000 + micro
    div micros, 1_000
  end

end

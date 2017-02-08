defmodule Codec.BinType do
  use Bitwise

  @doc """
  Used in encoder/decoder definitions by the encoder maker for choosing a
  default for a given field.  That default is used to populate the struct
  created for the encoder.
  """
  defmacro default(_id) do
    quote do
      integer
    end
  end

  @doc """
  Used in encoder/decoder definitions by the encoder maker for executing
  special functions on the encoded block.  They take the form:
  call_on_encoded(:function_atom, [:before || :after])
  :function_atom is the name of a function that takes a byte array and returns
  some type of integer that can be added to the output byte stream.
  :before and :after are used to declare whether the results of the called
  function are placed at the beginning(:before) of the byte stream or at the
  rear(:after).
  """
  defmacro call_on_encoded(_type_where) do
    quote do
      integer
    end
  end

  @doc """
  Used in encoder/decoder definitions by the encoder maker for executing
  special functions within the body of the encoder.
  """
  defmacro encode_func(_type_where) do
    quote do
      integer
    end
  end

  @doc """
  Used in encoder/decoder definitions.  Adds a bit shift in order to byte-justify
  the leading bits in a bit field that spans multiple bytes and needs to be
  little endian encoded.
  For example, suppose we have a bit field of << 0x0A, 0xBC >>.  Without add_shift,
  if we throw away the 0 and then create a 12 bit field with the remaining bits,
  we will end up with a little endian reassembly of 0x0CAB.  If we add_shift(4)
  to the 8 bit field for 0xBC, we can then have 0xBC0A.  Which interpretation
  is correct depends upon the particular parser being created.
  """
  defmacro add_shift(_type_where) do
    quote do
      integer
    end
  end

  defmacro decode_func(_type_where) do
    quote do
      integer
    end
  end

end

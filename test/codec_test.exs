defmodule CodecTest do
  use ExUnit.Case

  doctest Codec.Generator

  defmodule OuterMsg do
    use Codec.Generator
    make_encoder_decoder() do
      module = __MODULE__
      <<
        escape_sequence    :: 16-default(0xABCD),
        version            :: 8,
        payload            :: binary
      >>
    end
  end

  defmodule MiddleMsg do
    use Codec.Generator
    make_encoder_decoder() do
      module = __MODULE__
      <<
        highest_bit         :: 1,
        next_highest_bit    :: 1,
        middle_nibble       :: 4,
        next_lowest_bit     :: 1,
        lowest_bit          :: 1,
        payload             :: binary
      >>
    end
  end

  defmodule InnerMsg do
    use Codec.Generator
    make_encoder_decoder() do
      module = __MODULE__
      <<
        long_value            :: 32,
        long_little_endian    :: 32-little,
      >>
    end
  end

  test "encode an OuterMsg packet" do
    version = 12
    outer = %OuterMsg.S{ version: version }
    payload = "1234"
    packet = payload
            |> OuterMsg.encode(outer)
    assert packet == <<0xAB, 0xCD, version>> <> payload
  end

  test "encode then decode an OuterMsg packet" do
    version = 12
    outer = %OuterMsg.S{ version: version }
    payload = "1234"
    packet = payload
            |> OuterMsg.encode(outer)
    new_outer = OuterMsg.decode(packet)
    assert outer.version == new_outer.version
    assert new_outer.payload == payload
  end

  test "encode then decode an InnerMsg within an OuterMsg" do
    version = 63
    value = 0x12345678
    outer = %OuterMsg.S{ version: version }
    inner = %InnerMsg.S{ long_value: value, long_little_endian: value }
    packet = ""
            |> InnerMsg.encode(inner)
            |> OuterMsg.encode(outer)
    assert packet == <<0xAB, 0xCD, version>> <> << value :: 32, value :: little-32 >>

    new_outer = OuterMsg.decode(packet)
    new_inner = InnerMsg.decode(new_outer.payload)

    assert new_outer.version == version
    assert new_inner.long_value == value
    assert new_inner.long_little_endian == value
  end

  test "encode then decode an InnerMsg within a MiddleMsg within an OuterMsg" do
    version = 99
    value = 0xFEDCBA90
    outer = %OuterMsg.S{ version: version }
    middle = %MiddleMsg.S{ highest_bit: 1, next_highest_bit: 0, middle_nibble: 0xF, next_lowest_bit: 1, lowest_bit: 0 }
    inner = %InnerMsg.S{ long_value: value, long_little_endian: value }
    packet = ""
            |> InnerMsg.encode(inner)
            |> MiddleMsg.encode(middle)
            |> OuterMsg.encode(outer)
    assert packet ==  <<0xAB, 0xCD, version>> <>
                      << 0b10111110 :: 8 >> <>
                      << value :: 32, value :: little-32 >>

    new_outer = OuterMsg.decode(packet)
    new_middle = MiddleMsg.decode(new_outer.payload)
    new_inner = InnerMsg.decode(new_middle.payload)

    assert new_outer.version == version
    assert new_middle.highest_bit == 1
    assert new_middle.next_highest_bit == 0
    assert new_middle.middle_nibble == 0xF
    assert new_middle.next_lowest_bit == 1
    assert new_middle.lowest_bit == 0
    assert new_inner.long_value == value
    assert new_inner.long_little_endian == value
  end

  defmodule ReservedMsg do
    use Codec.Generator
    make_encoder_decoder() do
      module = __MODULE__
      <<
        reserved    :: 4,
        nibble      :: 4,
        nibble2     :: 4,
        reserved    :: 4,
      >>
    end
  end
  test "use reserved fields within a message" do
    msg = %ReservedMsg.S{nibble: 0xA, nibble2: 0xC}
    packet = "" |> ReservedMsg.encode(msg)
    new_msg = ReservedMsg.decode(packet)
    assert new_msg.nibble == 0xA
    assert new_msg.nibble2 == 0xC
    assert Map.has_key?(msg, :reserved) == false
    assert Map.has_key?(new_msg, :reserved) == false
  end

  defmodule SplitFieldsMsg do
    use Codec.Generator
    make_encoder_decoder() do
      module = __MODULE__
      <<
        split_field    :: 1,  # This will be the low bit from the input value
        reserved       :: 2,
        split_field    :: 3,  # 3 bits in the middle from the input value
        split_field    :: 2,  # 2 high bits from the input value
      >>
    end
  end
  test "bit fields can be split and rejoined 1" do
    value = 0b00111010
    packet = "" |> SplitFieldsMsg.encode(%SplitFieldsMsg.S{split_field: value})
    new_msg = SplitFieldsMsg.decode(packet)
    assert new_msg.split_field == value
    assert packet == <<0b00010111>>
  end
  test "bit fields can be split and rejoined 2" do
    value = 0b00111111
    packet = "" |> SplitFieldsMsg.encode(%SplitFieldsMsg.S{split_field: value})
    new_msg = SplitFieldsMsg.decode(packet)
    assert new_msg.split_field == value
    assert packet == <<0b10011111>>
  end
  test "bit fields can be split and rejoined 3" do
    value = 0b00110101
    packet = "" |> SplitFieldsMsg.encode(%SplitFieldsMsg.S{split_field: value})
    new_msg = SplitFieldsMsg.decode(packet)
    assert new_msg.split_field == value
    assert packet == <<0b10001011>>
  end

  defmodule ShiftMsg do
    use Codec.Generator
    make_encoder_decoder() do
      module = __MODULE__
      <<
        foo         :: 3,
        important   :: 5, # These 5 bits will be in the lsB
        important   :: 8-add_shift(3), # We shift an extra 3 bits to put these
                                       # all the way in the msB
      >>
    end
  end
  @tag :skip
  test "add_shift() can be used to have elixir re-assemble bytes with bit shifting" do
    important = 0b1111111111111  # 8191 or 0x1FFF
    packet = "" |> ShiftMsg.encode(%ShiftMsg.S{important: important})
    new_msg = ShiftMsg.decode(packet)
    IO.inspect packet
    assert new_msg.important == important
    assert packet == <<0b10001011>>
  end

  defmodule EncodeFuncMsg do
    use Codec.Generator
    make_encoder_decoder() do
      module = __MODULE__
      <<
        payload_size    :: 16-encode_func(byte_size(payload)),
        payload         :: binary,
      >>
    end
  end
  test "use an encode_func() directive to put a payload size in the packet" do
    packet = "12345678" |> EncodeFuncMsg.encode(%EncodeFuncMsg.S{})
    msg = EncodeFuncMsg.decode(packet)
    assert msg.payload_size == 8
    packet = "1234567890123456" |> EncodeFuncMsg.encode(%EncodeFuncMsg.S{})
    msg = EncodeFuncMsg.decode(packet)
    assert msg.payload_size == 16
  end

  defmodule NotMsg do
    use Codec.Generator
    make_encoder_decoder() do
      module = __MODULE__
      <<
        field       :: 16-decode_func(bnot(field))
      >>
    end
  end
  test "use a decode_func() to put the bnot() of a field in its place" do
    use Bitwise
    value = 0xAACC
    packet = "" |> NotMsg.encode(%NotMsg.S{field: value})
    msg = NotMsg.decode(packet)
    assert msg.field == bnot(value)

    value = 0x9876
    packet = "" |> NotMsg.encode(%NotMsg.S{field: value})
    msg = NotMsg.decode(packet)
    assert msg.field == bnot(value)
  end

  defmodule CRCMsg do
    import TestHelper
    use Codec.Generator
    make_encoder_decoder() do
      module = __MODULE__
      <<
        key                :: 16-default(0x1234),
        payload            :: binary,
        crc                :: little-16-call_on_encoded({:crc16Lsb, :after})
      >>
    end
  end
  test "use call_on_encoded() to put a 16 bit CRC of the payload at the end of the packet" do
    crc_msg = %CRCMsg.S{}
    packet = "1234567890" |> CRCMsg.encode(crc_msg)
    assert packet == <<18, 52, 49, 50, 51, 52, 53, 54, 55, 56, 57, 48, 76, 146>>
  end

  defmodule CRC32Msg do
    import TestHelper
    use Codec.Generator
    make_encoder_decoder() do
      module = __MODULE__
      <<
        key                :: 16-default(0x1234),
        payload            :: binary,
        crc                :: little-32-call_on_encoded({:crc32Lsb, :before})
      >>
    end
  end
  test "use call_on_encoded() to put a 32 bit CRC of the payload at the beginning of the packet" do
    crc_msg = %CRC32Msg.S{}
    packet = "1234567890" |> CRC32Msg.encode(crc_msg)

    # the :before tag will actually put the crc at the beginning of the packet.  So in this case
    # the first 4 bytes in the packet are the crc32 in little endian
    assert packet == <<203, 14, 255, 255, 18, 52, 49, 50, 51, 52, 53, 54, 55, 56, 57, 48>>
  end

  defmodule SumValuesBeginTest do
    import TestHelper
    use Codec.Generator
    make_encoder_decoder() do
      module = __MODULE__
      <<
        sum                :: 16-call_on_encoded({:sum, :before}),
        payload            :: binary,
      >>
    end
  end
  test "use call_on_encoded() to sum some values in a string and put them at the beginning" do
    packet = <<1, 2, 3, 4>> |> SumValuesBeginTest.encode(%SumValuesBeginTest.S{})
    strct = SumValuesBeginTest.decode(packet)
    assert packet == <<0, 10, 1, 2, 3, 4>>
    assert strct.payload == <<1, 2, 3, 4>>
    assert strct.sum == 10
  end

  defmodule PutPayloadBeforeValueTest do
    use Codec.Generator
    make_encoder_decoder() do
      module = __MODULE__
      <<
        payload            :: binary,
        key                :: little-32-default(0xEFCDAB89)
      >>
    end
  end
  test "ensure that payload does not have to be the last field in the structure" do
    packet = <<1, 2, 3, 4>> |> PutPayloadBeforeValueTest.encode(%PutPayloadBeforeValueTest.S{})
    strct = PutPayloadBeforeValueTest.decode(packet)
    assert packet == <<1, 2, 3, 4, 0x89, 0xAB, 0xCD, 0xEF>>
    assert strct.key == 0xEFCDAB89
  end
end

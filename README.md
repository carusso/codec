# Codec

The Elixir bit field syntax is extremely useful and expressive when encoding and decoding packetized data.  In order to facilitate the development of layered binary protocols while mostly sticking with the Elixir bit field syntax, this module was created.

With a simple Elixir definition of the format of the packet, an encode() and a decode() function is created as well as an Elixir structure that will hold all of the values in that structure.

Minor additions to the existing Elixir syntax allows for special operations to occur during encoding and decoding, such as calculating payload sizes, crc's, performing bitwise operations, etc.

By "layered", it is assumed that any packet type may contain a payload which could be the encoding of another layer of the protocol.

## Installation

Simply include a dependency in your mix.exs:

```elixir
def deps do
  [{:codec, "~> 0.1.0"}]
end
```

Then run:
```sh
$ mix deps.get deps.compile
```

## Basic Use

All encoder/decoder functions are generated with the make_encoder_decoder() macro.  Within the body of the macro, a mixture of standard bit parsing syntax and some custom syntax can be used to generally describe the format of the binary blob either to be encoded or decoded.

A simple example would be:
```elixir
defmodule Packet do
  use Codec.Generator

  make_encoder_decoder() do
    <<
      packet_type           :: 8,
      version               :: 8,
      priority              :: 4,
      frequency_override    :: 2,
      front_led_setting     :: 1,
      enable_encryption     :: 1,
    >>
  end
end
```

This particular definition introduces no new syntax to Elixir.  Each of the numbers to the right of the :: is the given field size in bits.  This documentation omits the unneeded "size(x)" form and simply specifies the size as "x".  For more information on Elixir bit syntax, see the [Kernel Special Forms](https://hexdocs.pm/elixir/Kernel.SpecialForms.html#%3C%3C%3E%3E/1) documentation.

This would produce a struct (%Packet.S{}) containing all of the named fields.  It would also create two functions - one for encoding (Packet.encode/2) and one for decoding (Packet.decode/2) data of type Packet.

Following the example above for a module Packet, the following components would be produced within the Packet module:
```elixir
  defmodule S do
    defstruct(packet_type: 0, version: 0, priority: 0, frequency_override: 0,
              front_led_setting: 0, enable_encryption: 0)
  end
  encode(payload, input_struct) # returns the binary packet
    # ...
  decode(packet, base_struct \\ %Test.S{}) # returns the completed struct
    # ...
```

To use the encoder for creating a packet (unspecified struct elements default to 0):
```elixir
    input_struct = %Packet.S{packet_type: 12, version: 3, priority: 2}
    packet = Packet.encode("", input_struct)
```

To decode that same packet:
```elixir
    output_struct = Packet.decode(packet) # base_struct has a default
```

Imagine that we needed to encapsulate the Packet format within an addressed Directed format.  The Directed module would include a declaration such as:
```elixir
  make_encoder_decoder() do
    <<
      address   :: little-32-default(0xFFFFFFFF),
      payload   :: binary,
    >>
  end
```
The ```payload``` field name is reserved and only intended to contain the binary passed into the encode/2 function as the first argument.

Notice the standard little endian directive is allowed in the declaration as well as a custom "default()" that will automatically populate fields that aren't declared explicitly when the input structs are created.

Encoding could be chained (assuming above declarations already occurred):
```elixir
    directed = %Directed.S(address: 0x12345678) # overriding the default
    packet =   ""
            |> Packet.encode(input_struct)
            |> Directed.encode(directed)
```

Currently, decoding of encapsulated formats must be handled without chaining:
```elixir
    directed = Directed.decode(packet)
    test = Packet.decode(directed.payload)
```

Some fields in some protocols are split into non-contiguous bits within the packet.  These can be handled by re-declaring the same field name at each point needed.  For example, if you had a 3 bit field whose lower 2 bits were in the lower 2 bits of a byte field and whose highest bit was the high bit of the byte (with something else between), the following declaration:
```elixir
    <<
      split_field   :: 2, # High order bits in the byte (low order field bits)
      whatever      :: 6,
      split_field   :: 1, # Low order bit in the byte (high order field bit)
    >>
```

The way the encoder/decoder split fields work is fundamentally little endian where the first occurrences in the decoder definition are actually the low bits from the value.

The encode() and decode() functions would then properly handle the split field.

## Reserved Field Names
Only two reserved field names currently exist:

**reserved** The bits of any field marked with ```reserved``` are populated with 0.  Multiple ```reserved``` fields may exist in a packet definition.  No ```reserved``` member is ever created in the %__MODULE__.S{} struct created.

**payload** This field is directly populated with the first binary argument passed to the encode/1 function.

## Custom Directives

### default()
This directive sets a default value for the specified field.  Currently, only integer value fields are supported.

###  add_shift(shift_amount)
(Note that this directive is currently not passing tests.  It's not being used in production anywhere and the problem would need to be resolved)
Some bit fields longer than a byte need to be reassembled with little endian encoding.  For example:
```elixir
    <<
      foo         :: 3,
      important   :: little-13,
    >>
```

The Elixir way of handling that field is to consider the first 8 bits to be the least significant byte and the upper 5 bits to be the upper bits of the most significant byte.  Basically, the bits read in are all the high bits of the two byte value before being flipped.  Often, that's not what you want.  Instead, you'd like for the bits of the "important" field to be read in as the lower 13 bits of the value and then the little endian byte swapping occurs after that.

The add_shift(shift_amount) directive can be used along with split fields to tell the encoders and decoders a bit more about how to assemble and disassemble these fields.
```elixir
    <<
      foo         :: 3,
      important   :: 5, # These 5 bits will be in the lsB
      important   :: 8-add_shift(3), # We shift an extra 3 bits to put these
                                     # all the way in the msB
    >>
```

###  encode_func(<function call>)
For encoding, sometimes values need to be calculated at the time that the encoding is happening.  If the calculation can happen without encoding being completed, use encode_func().  For example:
```elixir
    <<
      payload_size    :: little-16-encode_func(byte_size(payload)),
      payload         :: binary,
    >>
```

After encoding, the size of the payload field would appear where payload_size was specified in the packet.  It would be a 2 byte field, little endian.

###  decode_func(<function call>)
For decoding, sometimes values need to be calculated at the time that the decoding is happening.  If the calculation can happen without decoding being completed, use decode_func().  For example:
```elixir
    <<
      field       :: 16-decode_func(bnot(field))
    >>
```

After decoding, the field value would contain the bitwise NOT of the value that was in that position of the packet.  Ensure that the "use Bitwise" declaration is in the scope where the macro would be expanded in order to have them available.

###  call_on_encoded(<function atom>, <:before | :after>)
Some fields can't be calculated until after the main packet has been built. These fields normally appear at the beginning or end of the packet.  Think CRC, message signing, some packet size fields.  Assume the existence of a crc16Lsb function that takes a binary and returns a crc integer in the following example:
```elixir
    <<
      payload_size    :: 16-encode_func(byte_size(payload)),
      payload         :: binary,
      crc16Lsb        :: 16-call_on_encoded({:crc16Lsb, :after}),
    >>
```

In this case, call_on_encode is not called until AFTER the main packet has been constructed.  The crc16Lsb field is basically pulled out of the bit layout definition by the macro that makes the ecoder.  The results of the encode are then passed to the crc16Lsb() function and that result is tacked on to the end of the packet returned by encode().  The call_on_encoded() function accepts an argument that consists of a 2 item tuple with the first item being the atom referencing a func/1 function and the second tuple item being either :before or :after.  The second argument determines whether the results of the function call are prepended to the returned packet or appended respectively.

## To Do
This module is used currently in an internal tool within my company.  Eventually, I intend to add more features.  Any assistance with these features would be appreciated.
- Allow non-integer default() specification.
- In the decoders I haven't really found the passed-in struct useful.  My original thought was that I might want to pass in a partially-populated struct that could be supplemented by the decoder, but it never ended up making sense.  It could safely be removed.
- Smarter decoding of nested protocols.  It should be possible to call a multi_decode() function on a binary packet and have a map returned that contains all of the nested packet types in decoded form.  This will require some way of specifying how packet types are related to one another.  Possibly each packet type can have a list of types from which it could be derived.  Or perhaps hierarchical module organization of packet definitions could be exploited to determine those relationships.

# Codec

The Elixir bit field syntax is extremely useful and expressive when encoding and decoding packetized data.  In order to facilitate the development of layered binary protocols while mostly sticking with the Elixir bit field syntax, this module was created.

With a simple Elixir definition of the format of the packet, encode() and decode() functions are created as well as an Elixir structure that will hold all of the values in that structure.

Minor additions to the existing Elixir syntax allows for special operations to occur during encoding and decoding, such as calculating payload sizes, crc's, performing bitwise operations, etc.

By "layered", it is assumed that any packet type may contain a payload which could be the encoding of another layer of the protocol.

## Installation

Simply include a dependency in your mix.exs:

```elixir
def deps do
  [{:codec, "~> 0.1.2"}]
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

## Split Fields
Some fields in some protocols are split into non-contiguous bits within the packet.  These can be handled by re-declaring the same field name at each point needed.  For example, if you had a 3 bit field whose lower 2 bits were in the lower 2 bits of a byte field and whose highest bit was the high bit of the byte (with something else between), the following declaration:
```elixir
    <<
      split_field   :: 2, # High order bits in the byte (low order field bits)
      whatever      :: 6,
      split_field   :: 1, # Low order bit in the byte (high order field bit)
    >>
```

The encode() and decode() functions would then properly handle the split field.

The way the encoder/decoder split fields work is fundamentally little endian where the first occurrences in the decoder definition are actually the low bits used for the computed value.  In other words, in the above definition, the first 2 bits will be the low bits in the assembled value while the latter bit will be the high order bit in the assembled value.  So if the first two bits are ~b10, and the next bit is ~b1, the assembled value will be ~b110.  The way that works is a little counter to the way that elixir bit specifiers work, but it fits in with the way the protocols I work with are specified.  Perhaps an option to the make_encoder_decoder() macro could be added to reverse the sense of the assembly.  Contact me if this is needed.  Pull requests welcome.

## Reserved Field Names
Only two reserved field names currently exist:

**reserved** The bits of any field marked with ```reserved``` are populated with 0.  Multiple ```reserved``` fields may exist in a packet definition.  No ```reserved``` member is ever created in the %__MODULE__.S{} struct created.

**payload** This field is directly populated with the first binary argument passed to the encode/1 function.

## Custom Directives
A customer directive can be specified on a given bit field.

### default()
This directive sets a default value for the specified field.  Currently, only integer value fields are supported.

###  encode_func(<function call>)
For encoding, sometimes values need to be calculated at the time that the encoding is happening.  If the calculation can happen without encoding being completed for the entire packet, use encode_func().  For example:
```elixir
    <<
      payload_size    :: little-16-encode_func(byte_size(payload)),
      payload         :: binary,
    >>
```

After encoding, the size of the payload field would appear where payload_size was specified in the packet.  It would be a 2 byte field, little endian.

###  decode_func(<function call>)
After the packet has been decoded into the corresponding struct, some field modifications can be applied automatically.  For example:
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

In this case, call_on_encode is not called until AFTER the main packet has been constructed.  The crc16Lsb field is basically pulled out of the bit layout definition by the macro that makes the encoder.  The results of the encode are then passed to the crc16Lsb() function and that result is tacked on to the end of the packet returned by encode().  The call_on_encoded() function accepts an argument that consists of a 2 item tuple with the first item being the atom referencing a func/1 function and the second tuple item being either :before or :after.  The second argument determines whether the results of the function call are prepended to the returned packet or appended respectively.  Since the field is pulled out of the packet layout, you could put its definition anywhere, but keep in mind that when a packet is decoded with this definition, the bit reservation should be in the proper place to prevent a bad decode.

## Options to the Macro
Options can be passed to the make_encoder_decoder() function as a keyword list.

### Default substitutions
Any keyword that isn't an existing option can be used in default() entries.  Keep in mind that default() values can only be integers at this time.  Ensure that the bit size of the default is sufficient to hold the value specified or the behavior will be undefined.

```elixir
    <<
      number    :: 16-default(:favorite_number),
    >>

    ...

    make_encoder_decoder(favorite_number: 42)
```

## Debugging Help
Options can be passed to the make_encoder_decoder() function in order to facilitate debugging.

### debug: :final_ast
allows you to view the AST representation created by the macro.  If you're unfamiliar with Elixir's AST (Abstract Syntax Notation), you can learn about the concept by reading [Quote and unquote](https://elixir-lang.org/getting-started/meta/quote-and-unquote.html)

### debug: :final_code
allows you to view the final code created by the macro.

## To Do
This module is used currently in an internal tool within my company.  Eventually, I intend to add more features.  Any assistance with these features would be appreciated.
- In the decoders I haven't really found the passed-in struct useful.  My original thought was that I might want to pass in a partially-populated struct that could be supplemented by the decoder, but it never ended up making sense.  It could safely be removed.
- Smarter decoding of nested protocols.  It should be possible to call a multi_decode() function on a binary packet and have a map returned that contains all of the nested packet types in decoded form.  This will require some way of specifying how packet types are related to one another.  Possibly each packet type can have a list of types from which it could be derived.  Or perhaps hierarchical module organization of packet definitions could be exploited to determine those relationships.
- The whole %Blah.S{} struct declaration happened because I didn't see a way to create a %Blah{} struct for a module within the macro definition.  I'd like to eliminate the need for the ".S", if possible.
- The type for fields is integer and codec tends to assume that.  In some situations, I'd like to have non-integer values, like say a string default().  That will require a bit of reworking the macro.
- I've found that I sometimes want virtual fields in the generated decoder struct that weren't in the original data.  I need some use cases and ideas for how to specify those fields - and naturally, the implementation.

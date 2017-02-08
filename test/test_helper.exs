ExUnit.start()

defmodule TestHelper do
  use Bitwise
  
  def crc16Lsb(input, crc \\ 0xFFFF)
  def crc16Lsb(input, crc) when bit_size(input) == 0, do: (~~~crc) &&& 0xFFFF
  def crc16Lsb(<< head :: size(8), tail :: binary >>, crc) do
    crc = shifter(crc ^^^ head, 0)
    crc16Lsb(tail, crc)
  end

  def crc32Lsb(input, crc \\ 0xFFFFFFFF)
  def crc32Lsb(input, crc) when bit_size(input) == 0, do: (~~~crc) &&& 0xFFFFFFFF
  def crc32Lsb(<< head :: size(8), tail :: binary >>, crc) do
    crc = shifter(crc ^^^ head, 0)
    crc32Lsb(tail, crc)
  end

  defp shifter(crc, count) do
    crc = case crc &&& 0x0001 do
      0 -> crc >>> 1
      1 -> (crc >>> 1) ^^^ 0x8408;
    end
    case count do
      7 ->
        crc
      _ ->
        shifter(crc, count+1)
    end
  end
end

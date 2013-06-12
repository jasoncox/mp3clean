
# This file contains a sketchy implementation of an MP3 frame header parser

# It can also remove the ID3, Xing and VBRI tags, and add a Xing tag
# with ToC

# The Xing stuff is not documented well
#
#     MPEG Audio Frame Header
#     By Konrad Windszus
#     http://www.codeproject.com/KB/audio-video/mpegaudioinfo.aspx
#
# The ToC for Xing is not described there but is documented in the
# code here
#     XING Header SDK from Real Networks
#     http://docs.real.com/docs/xingtech/vbrheadersdk.zip

# The main MP3 header format is well documented. For example
#
#     MPEG Audio Frame Header
#     http://www.mpgedit.org/mpgedit/mpeg_format/mpeghdr.htm

module Mp3Utils
end

class Mp3Utils::Mp3Parser

  def self.frame_start_offset(data, offset=0)
    while offset < data.size - 4
      offset = data.index(0xff,offset)
      return offset if !offset || (7 == (data[offset + 1] >> 5))
      offset += 1
    end
    nil
  end

  def self.frame_start_offset_backwards(data, offset=data.size)
    offset = [offset, data.size-4].min
    while offset >= 0
      offset = data.rindex(0xff,offset)
      return offset if !offset || (7 == (data[offset + 1] >> 5))
      offset -= 1
    end
    nil
  end


  def self.crop_data_from_end_if_tag_matches(data,tag,length)
    return data if data.size < length
    return data[0..-length] if data[-length,tag.size]==tag
    return data
  end

  # string.unpack("b1b1") returns one bit from the first and one bit
  # from the second character in string so it is useless

  # Given data, a string, and a list of bit-lengths return a list of
  # integers corresponding to the data split into those bit lengths,
  # assuming MSB first.
  def self.unpack(data,bits)
    pos = 0
    res = []
    bit_pos = 0
    for total_bits in bits
      val = 0

      done_bits = 0
      while done_bits < total_bits
        bits_available = 8 - bit_pos
        bits_todo = [bits_available, total_bits-done_bits].min
        val <<= bits_todo
        val |= (data[pos] >> (8-(bit_pos+bits_todo)))  & ((1 << bits_todo)-1)
        done_bits += bits_todo

        bit_pos += bits_todo
        if bit_pos == 8
          bit_pos = 0
          pos += 1
        end
      end
      res << val
    end
    return res
  end


  # This table is from http://www.mp3-tech.org/programmer/frame_header.html
  BITRATE_VERSION_LAYER = [
                           [
                            nil,
                            [nil, 32, 40, 48,  56,  64,  80,  96, 112, 128, 160, 192, 224, 256, 320],
                            [nil, 32, 48, 56,  64,  80,  96, 112, 128, 160, 192, 224, 256, 320, 384],
                            [nil, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
                           ],
                           [
                            nil,
                            [nil, 8, 16, 24,  32,  40,  48,  56,  64,  80,  96, 112, 128, 144, 160],
                            [nil, 8, 16, 24,  32,  40,  48,  56,  64,  80,  96, 112, 128, 144, 160],
                            [nil, 32, 48, 56,  64,  80,  96, 112, 128, 144, 160, 176, 192, 224, 256],
                           ]]


  SAMPLERATES = [44100, 48000, 32100]

  class Frame
    attr_accessor(
                  :version_index,
                  :layer_index,
                  :crc_protected,
                  :bitrate_index,
                  :freq_index,
                  :padding,
                  :private_bit,
                  :channel_mode_index)

    def initialize(data, offset=Mp3Utils::Mp3Parser.frame_start_offset(data))
      frame_sync,
      self.version_index,
      self.layer_index,
      self.crc_protected,
      self.bitrate_index,
      self.freq_index,
      self.padding,
      self.private_bit,
      self.channel_mode_index = Mp3Utils::Mp3Parser.unpack(data[offset,4],[11,2,2,1,4,2,1,1,2])

      ((1 << 11)-1) == frame_sync or raise "Not at frame boundary; internal error"
    end

    def sample_rate
      SAMPLERATES[freq_index]/([4,nil,2,1][version_index])
    end

    def frame_length
      if :LAYER_I == layer
        ((12 * bitrate) / sample_rate + padding) * 4
      else
        (((:LAYER_II == layer || :MPEG1 == version) ? 144 : 72) * bitrate) / sample_rate + padding
      end
    end

    def frame_length_or_nil
      begin
        return frame_length
      rescue
        nil
      end
    end

    def channel_mode
      [:STEREO,
       :JOINT_STEREO,
       :DUAL_CHANNEL,
       :MONO][channel_mode_index]
    end

    def bitrate
      1000*BITRATE_VERSION_LAYER[:MPEG1 == version ? 0 : 1][layer_index][bitrate_index]
    end

    def version
      [:MPEG25, :MPEG_RESERVED, :MPEG2, :MPEG1] [version_index]
    end

    def layer
      [nil,:LAYER_III,:LAYER_II,:LAYER_I][layer_index]
    end

    def xing_offset
      4 +
        [
         [17, 32],
         [9, 17]
        ] [:MPEG1 == version ? 0 : 1][:MONO == channel_mode ? 0 : 1]
    end

    def next_frame_offset(data,offset)
      step = frame_length_or_nil

      step = [4 + 2*crc_protected, step || 0].max

#      puts  "#{layer} #{bitrate} #{sample_rate} #{padding} frame length is #{step}"

      Mp3Utils::Mp3Parser.frame_start_offset(data,offset+step)
    end
  end

  def self.end_of_last_valid_frame(data)
    offset = data.size
    while offset >= 0
      offset = frame_start_offset_backwards(data, offset)
      len = Frame.new(data, offset).frame_length_or_nil
      if len
        return offset + len
      end
      offset -= 1
    end
    raise 'No valid frames found'
  end

  def self.remove_xing_header_and_all_tags(data)
    offset = frame_start_offset(data)
    frame = Frame.new(data, offset)

    xo = frame.xing_offset

    if (["Xing","Info"].include? data[xo+offset,4]) || ('VBRI' == data[offset+32+4,4])
      return remove_xing_header_and_all_tags(data[frame.next_frame_offset(data,offset)..-1])
    end

    data = data[offset..-1]
    # Now we have removed the Xing, VBRI, LAME and any ID3v2 tag that occurs
    # at the start of the file.


    # Wipe any other trailing garbage
    data = data[0..(end_of_last_valid_frame(data)-1)]

    # These tags are probably already removed
    data = crop_data_from_end_if_tag_matches(data,"TAG+",227+128)
    data = crop_data_from_end_if_tag_matches(data,"TAG",128)
    # Now we have removed the ID3v1 tags

    data
  end

  def self.big_endian_string(val)
    val = val.to_i
    [val >> 24,val >> 16, val >> 8, val].pack('C*')
  end

  module Xing
    Frames = 1
    Bytes = 2
    ToC = 4
  end

  def self.frame_offsets(data, offset=0)
    data_end = data.size
    offsets = []

    while offset
      offsets << offset

      frame = Frame.new(data, offset)

      len = frame.frame_length_or_nil
      data_end = offset + len if len

      offset = frame.next_frame_offset(data,offset)
    end
    [offsets, data_end]
  end

  def self.add_xing_header(data)
    return data if !data || data.size == 0

    first_frame = frame_start_offset(data)

    xo = Frame.new(data, first_frame).xing_offset

    frame = data[first_frame,xo]
    frame[1] |= 1  # disable  CRC

    frame << "Xing"
    frame << [0,0,0,Xing::Frames|Xing::Bytes|Xing::ToC].pack('C*')


    offsets, data_end = frame_offsets(data, first_frame)
    frames = offsets.size
    total_frames = frames+1

    frame << big_endian_string(total_frames)

    total_bytes_offset = frame.size
    toc_offset = total_bytes_offset + 4

    target_frame_size = toc_offset + 100

    # Now we sloppily try to find the lowest bitrate that will give us the right frame length
    (1..15).each do |bitrate|
      frame[2] &= ~(0x80|0x40|0x20|0x10)
      frame[2] |= bitrate << 4

      len = Frame.new(frame).frame_length

      if len >= target_frame_size
        frame << "\0" * (len - frame.size)
        break
      end
    end

    total_size = data_end + frame.size
    frame[total_bytes_offset,4] = big_endian_string(total_size)

    (0..99).each do |i|
      frame[toc_offset+i] = ((offsets[(frames*i)/100]+frame.size)*256)/total_size
    end

    data[first_frame,0] = frame

    data[0..(total_size-1)]
  end

  def self.mp3_type(data)
    frame = Frame.new(data)
    [frame.sample_rate, frame.channel_mode == :MONO ? :MONO : :STEREO ]
  end
end

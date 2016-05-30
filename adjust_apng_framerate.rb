#!/usr/bin/env ruby
require 'fileutils'
require 'optparse'

# https://www.w3.org/TR/PNG-CRCAppendix.html
module CRC
  CRC_TABLE = Array.new(256, 0)

  begin
    256.times do |n|
      c = n
      8.times do |k|
        c = c & 1 == 1 ? (0xED_B8_83_20 ^ (c >> 1)) : c >> 1
      end
      CRC_TABLE[n] = c
    end
  end

  def self.update_crc(crc, buffer, len = buffer.size)
    len.times.reduce(crc) do |c, n|
      CRC_TABLE[(c ^ buf[n].ord) & 0xFF] ^ (c >> 8)
    end
  end

  def self.crc(buf, len = buf.size)
    update_crc(0xFF_FF_FF_FF, buf, len) ^ 0xFF_FF_FF_FF
  end
end

class ByteBuf
  def initialize(stream, **options)
    @stream = stream
    @endian = options.fetch(:endian, :native)
  end

  def pos
    @stream.pos
  end

  def eof?
    @stream.eof?
  end

  def goto(pos)
    @stream.seek(pos, :SET)
  end

  def step(len = 1)
    @stream.seek(len, :CUR)
  end

  def step_back(len = 1)
    step(-len)
  end

  def read_bytes(len)
    @stream.readpartial(len)
  end

  def write_bytes(len, str)
    @stream.write(str.slice(0, len))
  end

  [
    [1, "c", [:int8, :byte]],
    [1, "C", [:uint8, :ubyte]],
    [2, "s", [:int16, :short]],
    [2, "S", [:uint16, :ushort, :word]],
    [4, "l", [:int32, :int]],
    [4, "L", [:uint32, :uint, :dword]],
    [8, "q", [:int64, :long]],
    [8, "Q", [:uint64, :ulong, :qword]],
  ].each do |(len, unpacker, aliases)|
    aliases.each do |ali|
      read_name = "read_#{ali}".to_sym
      write_name = "write_#{ali}".to_sym
      define_method(read_name) do
        read_bytes(len)
      end

      define_method(write_name) do |value|
        write_bytes(len, value)
      end

      [
        [:native, ''],
        [:big, '>'],
        [:little, '<']
      ].each do |(endian, suffix)|
        pack_str = len > 1 ? unpacker + suffix : unpacker
        basename = "#{endian}_#{ali}"

        define_method("decode_#{basename}") do |value|
          value.unpack(pack_str).first
        end

        define_method("load_#{basename}") do
          send("decode_#{basename}", send(read_name))
        end

        define_method("encode_#{basename}") do |value|
          [value].pack(pack_str)
        end

        define_method("dump_#{basename}") do |value|
          send(write_name, send("encode_#{basename}", value))
        end
      end

      define_method("load_#{ali}") do
        send("load_#{@endian}_#{ali}")
      end

      define_method("dump_#{ali}") do |value|
        send("dump_#{@endian}_#{ali}", value)
      end

      define_method("encode_#{ali}") do
        send("encode_#{@endian}_#{ali}")
      end

      define_method("decode_#{ali}") do |value|
        send("decode_#{@endian}_#{ali}", value)
      end
    end
  end
end

class BinSchema
  attr_reader :fields

  def initialize(&block)
    @fields = []
    instance_exec(&block)
  end

  def field(name, **options)
    @fields << { name: name, options: options }
  end

  def include(schema)
    @fields.concat(schema.fields)
  end

  def each_field(&block)
    @fields.each(&block)
  end

  def read(buf)
    each_field.each_with_object({}) do |field, result|
      opts = field[:options]
      type = opts[:type]
      params = opts[:parameters] || []
      if opts[:raw]
        result[field[:name]] = buf.send("read_#{type}", *params)
      else
        result[field[:name]] = buf.send("load_#{type}", *params)
      end
    end
  end

  def encode(buf)
    each_field.each_with_object({}) do |field, result|
      field_name = field[:name]
      value = obj[field_name]
      if before_write = obj[field[:options][:before_write]]
        value = instance_exec(before_write).call(value)
      end
      result[field_name] = buf.send("encode_#{field[:options][:type]}", value)
    end
  end

  def write(buf, obj)
    each_field do |field|
      value = obj[field[:name]]
      if before_write = obj[field[:options][:before_write]]
        value = instance_exec(value, obj, &before_write)
      end
      buf.send("dump_#{field[:options][:type]}", value)
    end
  end
end

Crc = BinSchema.new do
  bfw = lambda do |value, data|
    e = encode(data)
    CRC.crc(e, e.size - 4)
  end
  field :crc, type: :uint32, before_write: bfw
end

PNGSignature = BinSchema.new do
  field :signature, type: 'bytes', parameters: [8], raw: true
end

ChunkHead = BinSchema.new do
  field :len, type: 'uint32'
  field :name, type: 'bytes', parameters: [4], raw: true
end

IDATChunk = BinSchema.new do
end

IHDRChunk = BinSchema.new do
  field :width,              type: 'uint32'
  field :height,             type: 'uint32'
  field :bit_depth,          type: 'byte'
  field :colour_type,        type: 'byte'
  field :compression_method, type: 'byte'
  field :filter_method,      type: 'byte'
  field :interlace_method,   type: 'byte'
  include Crc
end

ACTLChunk = BinSchema.new do
  field :num_frames, type: 'uint32'
  field :num_plays,  type: 'uint32'
  include Crc
end

FTCLChunk = BinSchema.new do
  field :sequence_number, type: 'uint32'
  field :width, type: 'uint32'
  field :height, type: 'uint32'
  field :x_offset, type: 'uint32'
  field :y_offset, type: 'uint32'
  field :delay_num, type: 'uint16'
  field :delay_den, type: 'uint16'
  field :dispose_op, type: 'byte'
  field :blend_op, type: 'byte'
  include Crc
end

FDATChunk = BinSchema.new do
  field :sequence_number, type: 'unit32'
  field :frame_data, type: 'byte_array'
end

def skip_chunk(buf, chunk)
  #puts "Skipping Chunk #{chunk[:name]}"
  buf.step(chunk[:len])
  # skip CRC
  buf.step(4)
end

settings = {
  delay: nil
}

argv = OptionParser.new do |opts|
  opts.on '-d', '--delay NUM', Integer, 'Sets the new delay' do |d|
    settings[:delay] = d
  end
end.parse(ARGV)

argv.each do |filename|
  frames = []
  src_filename = "#{filename}.bak"
  unless File.exist?(src_filename)
    FileUtils::Verbose.cp(filename, src_filename)
  end
  target_filename = filename

  File.open(src_filename, 'rb') do |file|
    buf = ByteBuf.new(file, endian: :big)
    png_head = PNGSignature.read(buf)
    loop do
      break if buf.eof?
      head = ChunkHead.read(buf)
      case head[:name]
      when 'IHDR'
        #p IHDRChunk.read(buf)
        skip_chunk buf, head
      when 'acTL'
        #p ACTLChunk.read(buf)
        skip_chunk buf, head
      when 'tRNS', 'IDAT', 'fdAT', 'tEXt'
        skip_chunk buf, head
      when 'fcTL'
        pos = buf.pos
        frames << { pos: pos, data: FTCLChunk.read(buf) }
      when 'IEND'
        skip_chunk buf, head
      else
        raise "Unhandled chunk #{head[:name]}"
      end
    end
  end

  File.delete(target_filename) if File.exist?(target_filename)
  FileUtils::Verbose.cp(src_filename, target_filename)

  File.open(target_filename, 'rb+') do |file|
    buf = ByteBuf.new(file, endian: :big)
    frames.each do |frame|
      new_frame_data = frame[:data].dup
      new_frame_data[:delay_num] = settings[:delay] || new_frame_data[:delay_num]
      puts "GOTO: #{frame[:pos]}"
      buf.goto(frame[:pos])
      puts "WRITE: #{new_frame_data}"
      FTCLChunk.write(buf, new_frame_data)
    end
  end
end

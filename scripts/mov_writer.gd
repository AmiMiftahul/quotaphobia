class_name MovWriter
extends RefCounted
## Builds a QuickTime .mov video from JPEG frames. Godot can't save video while a
## game is running, and this format is simple enough to write directly. The tests
## open the result with Apple's own video framework.

const TIMESCALE := 600 # Ticks per second, the QuickTime standard.


## durations holds how long each frame stays on screen, in ticks.
static func build(frames: Array, durations: PackedInt32Array, width: int, height: int) -> PackedByteArray:
	var header := _atom("ftyp", _text("qt  ") + _u32(0x20050300) + _text("qt  "))
	var pixels := PackedByteArray()
	var sizes := PackedByteArray()
	var total_ticks := 0
	var timing := _u32(0) + _u32(frames.size())
	for index in frames.size():
		var frame: PackedByteArray = frames[index]
		pixels.append_array(frame)
		sizes.append_array(_u32(frame.size()))
		timing.append_array(_u32(1) + _u32(durations[index]))
		total_ticks += durations[index]
	var first_frame_at := header.size() + 8
	var data := _atom("mdat", pixels)
	var table := _atom("stsd", _u32(0) + _u32(1) + _sample_description(width, height))
	table.append_array(_atom("stts", timing))
	table.append_array(_atom("stsc", _u32(0) + _u32(1) + _u32(1) + _u32(frames.size()) + _u32(1)))
	table.append_array(_atom("stsz", _u32(0) + _u32(0) + _u32(frames.size()) + sizes))
	table.append_array(_atom("stco", _u32(0) + _u32(1) + _u32(first_frame_at)))
	var data_ref := _atom("dref", _u32(0) + _u32(1) + _atom("url ", _u32(1)))
	var media_info := _atom("vmhd", _u32(1) + _zeros(8))
	media_info.append_array(_handler("dhlr", "url ", "DataHandler"))
	media_info.append_array(_atom("dinf", data_ref))
	media_info.append_array(_atom("stbl", table))
	var media := _atom("mdhd", _u32(0) + _u32(0) + _u32(0) + _u32(TIMESCALE) + _u32(total_ticks) + _zeros(4))
	media.append_array(_handler("mhlr", "vide", "VideoHandler"))
	media.append_array(_atom("minf", media_info))
	var track := _atom("tkhd", _u32(0xF) + _u32(0) + _u32(0) + _u32(1) + _zeros(4) + _u32(total_ticks) + _zeros(16) + _matrix() + _u32(width << 16) + _u32(height << 16))
	track.append_array(_atom("mdia", media))
	var overview := _u32(0) + _u32(0) + _u32(0) + _u32(TIMESCALE) + _u32(total_ticks) + _u32(0x00010000) + _u16(0x0100) + _zeros(10) + _matrix() + _zeros(24) + _u32(2)
	var movie := _atom("mvhd", overview)
	movie.append_array(_atom("trak", track))
	return header + data + _atom("moov", movie)


static func _sample_description(width: int, height: int) -> PackedByteArray:
	var name_bytes := "Photo - JPEG".to_ascii_buffer()
	var compressor := PackedByteArray([name_bytes.size()]) + name_bytes
	compressor.resize(32)
	var body := _zeros(6) + _u16(1) + _zeros(8) + _u32(512) + _u32(512)
	body.append_array(_u16(width) + _u16(height) + _u32(0x00480000) + _u32(0x00480000) + _u32(0) + _u16(1))
	body.append_array(compressor)
	body.append_array(_u16(24) + _u16(0xFFFF))
	return _atom("jpeg", body)


static func _handler(kind: String, subtype: String, label: String) -> PackedByteArray:
	var label_bytes := label.to_ascii_buffer()
	return _atom("hdlr", _u32(0) + _text(kind) + _text(subtype) + _zeros(12) + PackedByteArray([label_bytes.size()]) + label_bytes)


static func _matrix() -> PackedByteArray:
	return _u32(0x00010000) + _zeros(12) + _u32(0x00010000) + _zeros(12) + _u32(0x40000000)


static func _atom(tag: String, payload: PackedByteArray) -> PackedByteArray:
	return _u32(payload.size() + 8) + _text(tag) + payload


static func _text(value: String) -> PackedByteArray:
	return value.to_ascii_buffer()


static func _zeros(count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(count)
	return bytes


static func _u16(value: int) -> PackedByteArray:
	return PackedByteArray([(value >> 8) & 255, value & 255])


static func _u32(value: int) -> PackedByteArray:
	return PackedByteArray([(value >> 24) & 255, (value >> 16) & 255, (value >> 8) & 255, value & 255])

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = mem.Allocator;

const frame = @import("read_frame_header.zig");
const block = @import("read_block.zig");


pub const Decompressor = struct {
    //allocator : *Allocator,
    frame_header: frame.FrameHeader,
    const Self = @This();

    pub fn init() void {

    }

    pub fn decompressAlloc(self: *Self, allocator: *Allocator, compressed: []const u8) ![]u8 {
        var read: usize = 0;
        var written: usize = 0;
        var decompressed: []u8 = try allocator.alloc(u8, 0);
        errdefer {
            allocator.free(decompressed);
        }
        //std.debug.warn("Decompressing data of {} bytes\n", compressed.len);
        while (read < compressed.len) {
            read = try frame.readFrameHeader(compressed, &self.frame_header);
            //std.debug.warn("FrameHeader: {}\n", self.frame_header);
            switch(self.frame_header) {
                frame.FrameHeader.General => |frame_header| {
                    var frame_read: usize = 0;
                    var frame_written: usize = 0;
                    defer {
                        read += frame_read;
                        written += frame_written;
                    }
                    if (frame_header.flags.ContentSize == 0) {
                        return error.CantHandle;
                    }
                    const new_size = frame_header.content_size.?;
                    decompressed = try allocator.realloc(decompressed, new_size);
                    try self.decompressGeneralFrame(compressed[read..], &frame_read, decompressed[written..], &frame_written);
                },
                frame.FrameHeader.Skippable => |value| {
                    read += value.size;
                },
            }
            //std.debug.warn("Read {}, written {}\n", read, written);
        }
        return if (written == decompressed.len) decompressed else try allocator.realloc(decompressed, written);
    }

    pub fn decompress(self: *Self, compressed: []const u8, read_out: *usize, decompressed: []u8, written_out: *usize) !void {
        var read: usize = 0;
        var written: usize = 0;
        while (read < compressed.len and written < decompressed.len) {
            read = try frame.readFrameHeader(compressed, &self.frame_header);
            defer {
                read_out.* = read;
                written_out.* = written;
            }
            switch(self.frame_header) {
                frame.FrameHeader.General => {
                    var frame_read: usize = 0;
                    var frame_written: usize = 0;
                    defer {
                        read += frame_read;
                        written += frame_written;
                    }
                    try self.decompressGeneralFrame(compressed[read..], &frame_read, decompressed[written..], &frame_written);
                },
                frame.FrameHeader.Skippable => |value| {
                    read += value.size;
                },
            }
        }
    }

    fn decompressGeneralFrame(self: Self, compressed: []const u8, read_out: *usize, decompressed: []u8, written_out: *usize) !void {
        const frame_descriptor = &self.frame_header.General;
        var read = usize(0);
        var written = usize(0);
        defer {
            read_out.* = read;
            written_out.* = written;
        }
        var header = block.BlockHeader{ .size = 0x7fffffff, .compressed = 1 };
        while (header.size != 0) {
            //std.debug.warn("Start reading block at {} writing at {}\n", read, written);
            read += try block.readBlockHeader(compressed[read..], &header);
            //std.debug.warn("Read {} bytes: {}\n", read, header);
            if (header.compressed == 1) {
                var decode_read: usize = undefined;
                var decode_written: usize = undefined;
                defer {
                    read += decode_read;
                    written += decode_written;
                }
                try block.decodeBlock(compressed[read..read+header.size], &decode_read, decompressed[written..], &decode_written);
            } else {
                std.mem.copy(u8, decompressed[written..], compressed[read..read+header.size]);
                read += header.size;
                written += header.size;
            }
        }
        if (frame_descriptor.flags.ContentChecksum == 1) {
            _ = try frame.readContentChecksum(compressed[read..]);
            read += 4;
        }
    }
};


test "decompress simple" {
    const block1 = []u8{0x8F, 1, 2, 3, 4, 5, 6, 7, 8, 0x02, 0x00, 0xFF, 0x04};
    const compressed = [4]u8{0x04, 0x22, 0x4D, 0x18} ++ [3]u8{0x40, 0x40, 0xFE} ++ []u8{@intCast(u8, block1.len), 0x00, 0x00, 0x00} ++ block1 ++ []u8{0x00, 0x00, 0x00, 0x00};
    var data = []u8{0} ** 512;
    const expected_data = []u8{1,2,3,4,5,6,7,8} ++ []u8{7,8} ** 139;
    var decompressor: Decompressor = undefined;
    var read: usize = undefined;
    var written: usize = undefined;
    try decompressor.decompress(compressed, &read, data[0..], &written);
    testing.expectEqual(compressed.len, read);
    testing.expectEqual(expected_data.len, written);
    testing.expectEqualSlices(u8, expected_data, data[0..expected_data.len]);
}

test "decompress small lorem ipsum" {
    const compressed = @embedFile("lorem.txt.lz4");
    const expected = @embedFile("lorem.txt");
    var data = []u8{0} ** 1024;
    var decompressor: Decompressor = undefined;
    var read: usize = undefined;
    var written: usize = undefined;
    try decompressor.decompress(compressed, &read, data[0..], &written);
    testing.expectEqual(compressed.len, read);
    testing.expectEqual(expected.len, written);
    testing.expectEqualSlices(u8, expected, data[0..expected.len]);
}

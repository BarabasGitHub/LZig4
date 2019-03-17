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

    pub fn decompress(self: *Self, compressed: []const u8, read_out: *usize, decompressed: []u8, written_out: *usize) !void {
        var read = try frame.readFrameHeader(compressed, &self.frame_header);
        var written: usize = 0;
        defer {
            read_out.* = read;
            written_out.* = written;
        }
        switch(self.frame_header) {
            frame.FrameHeader.General => |value| {
                var size: u32 = 0xffff;
                while (size != 0) {
                    read += try block.readBlockSize(compressed[read..], &size);
                    var decode_read: usize = undefined;
                    var decode_written: usize = undefined;
                    defer {
                        read += decode_read;
                        written += decode_written;
                    }
                    try block.decodeBlock(compressed[read..read+size], &decode_read, decompressed[written..], &decode_written);
                }
            },
            frame.FrameHeader.Skippable => |value| {
                read += value.size;
            },
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

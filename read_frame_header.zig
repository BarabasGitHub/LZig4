const std = @import("std");
const testing = std.testing;
const mem = std.mem;

pub const FrameType = enum(u1) {
    General,
    Skippable,
};

// returns the frame type, will always read 4 bytes if available
fn handleMagic(data: []const u8) !FrameType {
    if (data.len < 4) {
        return error.NotEnoughData;
    }
    const magic = mem.readIntSliceLittle(u32, data);
    const general_magic: u32 = 0x184D2204;
    if (magic == general_magic)
        return FrameType.General;
    const skippable_magic: u32 = 0x184D2A50; // up to 0x184D2A5F
    if (magic & 0xFFFFFFF0 == skippable_magic)
        return FrameType.Skippable;
    return error.InvalidMagic;
}

pub const FrameFlags = struct {
    Version: u2,
    BlockIndependence: u1,
    BlockChecksum: u1,
    ContentSize: u1,
    ContentChecksum: u1,
    _reserved: u1,
    DictionaryId: u1,
};

pub const BlockMaximumSize = enum(u3) {
    _64KB = 4,
    _256KB = 5,
    _1MB = 6,
    _4MB = 7,
};

pub const BlockData = struct {
    _reserved: u1,
    BlockMaximumSize: BlockMaximumSize,
    _reserved2: u4,
};

pub const FrameDescriptor = struct {
    flags: FrameFlags,
    block_data: BlockData,
    content_size: ?u64,
    dictionary_id: ?u32,
    header_checksum: u8,
};

pub const SkippableFrameDescriptor = struct {
    size: u32,
};

pub const FrameHeader = union(FrameType) {
    General: FrameDescriptor,
    Skippable: SkippableFrameDescriptor,
};

fn readFrameFlags(data: u8) !FrameFlags {
    var flags: FrameFlags = undefined;
    flags.Version = @intCast(u2, (data & 0xC0) >> 6);
    if (flags.Version != 1)
        return error.UnsupportedVersion;
    flags.BlockIndependence = @intCast(u1, (data & 0x20) >> 5);
    flags.BlockChecksum = @intCast(u1, (data & 0x10) >> 4);
    flags.ContentSize = @intCast(u1, (data & 0x08) >> 3);
    flags.ContentChecksum = @intCast(u1, (data & 0x04) >> 2);
    flags._reserved = @intCast(u1, (data & 0x02) >> 1);
    if (flags._reserved != 0)
        return error.UnableToDecode;
    flags.DictionaryId = @intCast(u1, (data & 0x01) >> 0);
    return flags;
}

fn readBlockData(data: u8) !BlockData {
    var block: BlockData = undefined;
    block._reserved = @intCast(u1, (data & 0x80) >> 7);
    block._reserved2 = @intCast(u4, data & 0x0F);
    if (block._reserved != 0 or block._reserved2 != 0)
        return error.UnableToDecode;
    block.BlockMaximumSize = @bitCast(BlockMaximumSize, @intCast(u3, (data & 0x70) >> 4));
    if (block.BlockMaximumSize != BlockMaximumSize._256KB and
        block.BlockMaximumSize != BlockMaximumSize._64KB and
        block.BlockMaximumSize != BlockMaximumSize._1MB and
        block.BlockMaximumSize != BlockMaximumSize._4MB)
        return error.InvalidBlockSize;
    return block;
}

// returns how much data is has read from the input
fn readFrameDescriptor(data: []const u8, frame_descriptor: *FrameDescriptor) !usize {
    if (data.len < 3){
        return error.NotEnoughData;
    }
    frame_descriptor.flags = try readFrameFlags(data[0]);
    frame_descriptor.block_data = try readBlockData(data[1]);
    var read = usize(2);
    if (frame_descriptor.flags.ContentSize == 1) {
        if (data.len < read + 9)
            return error.NotEnoughData;
        frame_descriptor.content_size = mem.readIntSliceLittle(u64, data[read..read + 8]);
        read += 8;
    }
    if (frame_descriptor.flags.DictionaryId == 1) {
        if (data.len < read + 5)
            return error.NotEnoughData;
        frame_descriptor.dictionary_id = mem.readIntSliceLittle(u32, data[read..read + 4]);
        read += 4;
    }
    frame_descriptor.header_checksum = data[read];
    read += 1;
    return read;
}

// returns how many data is has read from the input
fn readSkippableFrameDescriptor(data: []const u8, frame_descriptor: *SkippableFrameDescriptor) !usize {
    if (data.len < 4)
        return error.NotEnoughData;
    frame_descriptor.size = mem.readIntSliceLittle(u32, data[0..4]);
    return 4;
}

// returns how many data is has read from the input
pub fn readFrameHeader(data: []const u8, frame_header: *FrameHeader) !usize {
    const read = switch(try handleMagic(data)) {
        FrameType.General => blk: {
            frame_header.* = FrameHeader{ .General = undefined };
            break: blk try readFrameDescriptor(data[4..], &frame_header.General);
        },
        FrameType.Skippable => blk: {
            frame_header.* = FrameHeader{ .Skippable = undefined };
            break: blk try readSkippableFrameDescriptor(data[4..], &frame_header.Skippable);
        },
    };
    return read + 4;
}

pub fn readContentChecksum(data: []const u8) !u32 {
    if (data.len < 4)
        return error.NotEnoughData;
    return mem.readIntSliceLittle(u32, data[0..4]);
}

test "magic" {
    const dataShort = [3]u8{1,2,3};
    testing.expectError(error.NotEnoughData, handleMagic(dataShort));
    const dataInvalid = [4]u8{1,2,3,4};
    testing.expectError(error.InvalidMagic, handleMagic(dataInvalid));
    const dataCorrect = [4]u8{0x04, 0x22, 0x4D, 0x18};
    testing.expectEqual(FrameType.General, try handleMagic(dataCorrect));
    const dataCorrectAndMore = [8]u8{0x04, 0x22, 0x4D, 0x18, 1, 2, 3, 4};
    testing.expectEqual(FrameType.General, try handleMagic(dataCorrectAndMore[0..4]));
    inline for ([]u8{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}) |i| {
        const dataSkippable = [4]u8{0x50 + i, 0x2A, 0x4D, 0x18};
        testing.expectEqual(FrameType.Skippable, try handleMagic(dataSkippable[0..4]));
    }
}

test "frame descriptor errors" {
    const dataShort: [2]u8 = undefined;
    var frame_descriptor: FrameDescriptor = undefined;
    testing.expectError(error.NotEnoughData, readFrameDescriptor(dataShort, &frame_descriptor));
}

test "frame version" {
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const dataInvalidVersion = [3]u8{0x00, 0x00, 0x00};
        testing.expectError(error.UnsupportedVersion, readFrameDescriptor(dataInvalidVersion, &frame_descriptor));
    }

    {
        var frame_descriptor: FrameDescriptor = undefined;
        const dataValidVersion = [3]u8{0x40, 0x40, 0x00};
        _ = try readFrameDescriptor(dataValidVersion, &frame_descriptor);
        testing.expectEqual(u2(0x01), frame_descriptor.flags.Version);
    }
}

test "frame flags" {
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{0x42, 0x40, 0x00};
        testing.expectError(error.UnableToDecode, readFrameDescriptor(data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{0x40, 0x40, 0x00};
        _ = try readFrameDescriptor(data, &frame_descriptor);
        testing.expectEqual(u1(0), frame_descriptor.flags.BlockIndependence);
        testing.expectEqual(u1(0), frame_descriptor.flags.BlockChecksum);
        testing.expectEqual(u1(0), frame_descriptor.flags.ContentSize);
        testing.expectEqual(u1(0), frame_descriptor.flags.ContentChecksum);
        testing.expectEqual(u1(0), frame_descriptor.flags._reserved);
        testing.expectEqual(u1(0), frame_descriptor.flags.DictionaryId);
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{0x60, 0x40, 0x00};
        _ = try readFrameDescriptor(data, &frame_descriptor);
        testing.expectEqual(u1(1), frame_descriptor.flags.BlockIndependence);
        testing.expectEqual(u1(0), frame_descriptor.flags.BlockChecksum);
        testing.expectEqual(u1(0), frame_descriptor.flags.ContentSize);
        testing.expectEqual(u1(0), frame_descriptor.flags.ContentChecksum);
        testing.expectEqual(u1(0), frame_descriptor.flags._reserved);
        testing.expectEqual(u1(0), frame_descriptor.flags.DictionaryId);
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{0x50, 0x40, 0x00};
        _ = try readFrameDescriptor(data, &frame_descriptor);
        testing.expectEqual(u1(0), frame_descriptor.flags.BlockIndependence);
        testing.expectEqual(u1(1), frame_descriptor.flags.BlockChecksum);
        testing.expectEqual(u1(0), frame_descriptor.flags.ContentSize);
        testing.expectEqual(u1(0), frame_descriptor.flags.ContentChecksum);
        testing.expectEqual(u1(0), frame_descriptor.flags._reserved);
        testing.expectEqual(u1(0), frame_descriptor.flags.DictionaryId);
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [11]u8{0x48, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
        _ = try readFrameDescriptor(data, &frame_descriptor);
        testing.expectEqual(u1(0), frame_descriptor.flags.BlockIndependence);
        testing.expectEqual(u1(0), frame_descriptor.flags.BlockChecksum);
        testing.expectEqual(u1(1), frame_descriptor.flags.ContentSize);
        testing.expectEqual(u1(0), frame_descriptor.flags.ContentChecksum);
        testing.expectEqual(u1(0), frame_descriptor.flags._reserved);
        testing.expectEqual(u1(0), frame_descriptor.flags.DictionaryId);
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{0x44, 0x40, 0x00};
        _ = try readFrameDescriptor(data, &frame_descriptor);
        testing.expectEqual(u1(0), frame_descriptor.flags.BlockIndependence);
        testing.expectEqual(u1(0), frame_descriptor.flags.BlockChecksum);
        testing.expectEqual(u1(0), frame_descriptor.flags.ContentSize);
        testing.expectEqual(u1(1), frame_descriptor.flags.ContentChecksum);
        testing.expectEqual(u1(0), frame_descriptor.flags.DictionaryId);
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [7]u8{0x41, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00};
        _ = try readFrameDescriptor(data, &frame_descriptor);
        testing.expectEqual(u1(0), frame_descriptor.flags.BlockIndependence);
        testing.expectEqual(u1(0), frame_descriptor.flags.BlockChecksum);
        testing.expectEqual(u1(0), frame_descriptor.flags.ContentSize);
        testing.expectEqual(u1(0), frame_descriptor.flags.ContentChecksum);
        testing.expectEqual(u1(0), frame_descriptor.flags._reserved);
        testing.expectEqual(u1(1), frame_descriptor.flags.DictionaryId);
    }
}

test "block data" {
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{0x40, 0x00, 0x00};
        testing.expectError(error.InvalidBlockSize, readFrameDescriptor(data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{0x40, 0x80, 0x00};
        testing.expectError(error.UnableToDecode, readFrameDescriptor(data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        for ([]u2{0,1,2,3}) |i| {
            const data = [3]u8{0x40, u8(1) << i, 0x00};
            testing.expectError(error.UnableToDecode, readFrameDescriptor(data, &frame_descriptor));
        }
    }
    inline for (@typeInfo(BlockMaximumSize).Enum.fields) |field| {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{0x40, u8(field.value) << 4, 0x00};
        _ = try readFrameDescriptor(data, &frame_descriptor);
        testing.expectEqual(@intToEnum(BlockMaximumSize, field.value), frame_descriptor.block_data.BlockMaximumSize);
    }
}

test "Content Size" {
    var frame_descriptor: FrameDescriptor = undefined;
    const data = [11]u8{0x48, 0x40, 0xFE, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12, 0x00};
    _ = try readFrameDescriptor(data, &frame_descriptor);
    testing.expectEqual(u64(0x123456789ABCDEFE), frame_descriptor.content_size.?);
}

test "Dictionary Id" {
    var frame_descriptor: FrameDescriptor = undefined;
    const data = [7]u8{0x41, 0x40, 0xFE, 0xDE, 0xBC, 0x9A, 0x00};
    _ = try readFrameDescriptor(data, &frame_descriptor);
    testing.expectEqual(u32(0x9ABCDEFE), frame_descriptor.dictionary_id.?);
}

test "Header Checksum" {
    var frame_descriptor: FrameDescriptor = undefined;
    const data = [3]u8{0x40, 0x40, 0xFE};
    _ = try readFrameDescriptor(data, &frame_descriptor);
    testing.expectEqual(u8(0xFE), frame_descriptor.header_checksum);
}

test "Content Size, Dictionary Id and Header Checksum" {
    var frame_descriptor: FrameDescriptor = undefined;
    const data = [15]u8{0x49, 0x40, 0xFE, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12, 0x21, 0x43, 0x65, 0x87, 0xF1};
    _ = try readFrameDescriptor(data, &frame_descriptor);
    testing.expectEqual(u64(0x123456789ABCDEFE), frame_descriptor.content_size.?);
    testing.expectEqual(u32(0x87654321), frame_descriptor.dictionary_id.?);
    testing.expectEqual(u8(0xF1), frame_descriptor.header_checksum);
}

test "Bytes read" {
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{0x40, 0x40, 0xFE};
        testing.expectEqual(usize(3), try readFrameDescriptor(data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [3]u8{0x40, 0x40, 0xFE} ++ []u8{0x00} ** 100;
        testing.expectEqual(usize(3), try readFrameDescriptor(data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [2]u8{0x48, 0x40} ++ []u8{0x00} ** 100;
        testing.expectEqual(usize(11), try readFrameDescriptor(data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [2]u8{0x41, 0x40} ++ []u8{0x00} ** 100;
        testing.expectEqual(usize(7), try readFrameDescriptor(data, &frame_descriptor));
    }
    {
        var frame_descriptor: FrameDescriptor = undefined;
        const data = [2]u8{0x49, 0x40} ++ []u8{0x00} ** 100;
        testing.expectEqual(usize(15), try readFrameDescriptor(data, &frame_descriptor));
    }
}

test "Skippable frame" {
    const data = [4]u8{0x01, 0x02, 0x03, 0x04};
    var frame_descriptor: SkippableFrameDescriptor = undefined;
    _ = try readSkippableFrameDescriptor(data, &frame_descriptor);
    testing.expectEqual(u32(0x04030201), frame_descriptor.size);
    const dataShort: [3]u8 = undefined;
    testing.expectError(error.NotEnoughData, readSkippableFrameDescriptor(dataShort, &frame_descriptor));
}

test "Read Frame Header" {
    {
        const skippableData = [4]u8{0x50, 0x2A, 0x4D, 0x18} ++ [4]u8{0x01, 0x02, 0x03, 0x04};
        var frame_header: FrameHeader = undefined;
        const read = try readFrameHeader(skippableData, &frame_header);
        testing.expectEqual(usize(8), read);
        testing.expectEqual(FrameType.Skippable, FrameType(frame_header));
        testing.expectEqual(u32(0x04030201), frame_header.Skippable.size);
    }
    {
        var frame_header: FrameHeader = undefined;
        const data = [4]u8{0x04, 0x22, 0x4D, 0x18} ++ [3]u8{0x40, 0x40, 0xFE};
        const read = try readFrameHeader(data, &frame_header);
        testing.expectEqual(usize(7), read);
        testing.expectEqual(FrameType.General, FrameType(frame_header));
        testing.expectEqual(u8(0xFE), frame_header.General.header_checksum);
    }
}

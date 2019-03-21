const std = @import("std");
const clap = @import("clap");
const debug = std.debug;
const io = std.io;
const decompress = @import("decompress.zig");

pub fn main() !void {
    var direct_allocator = std.heap.DirectAllocator.init();
    var allocator = &direct_allocator.allocator;
    defer direct_allocator.deinit();

    // First we specify what parameters our program can take.
    const params = []clap.Param(u8){
        clap.Param(u8).flag('h', clap.Names.both("help")),
        clap.Param(u8).option('i', clap.Names.both("input")),
        clap.Param(u8).option('o', clap.Names.both("output")),
    };

    // We then initialize an argument iterator. We will use the OsIterator as it nicely
    // wraps iterating over arguments the most efficient way on each os.
    var iter = clap.args.OsIterator.init(allocator);
    defer iter.deinit();

    // Consume the exe arg.
    const exe = try iter.next();

    // Finally we initialize our streaming parser.
    var parser = clap.StreamingClap(u8, clap.args.OsIterator).init(params, &iter);

    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    // Because we use a streaming parser, we have to consume each argument parsed individually.
    while (try parser.next()) |arg| {
        // arg.param will point to the parameter which matched the argument.
        switch (arg.param.id) {
            'h' => {
                debug.warn("Help!\n");
                return;
                },
            'i' => input = arg.value,
            'o' => output = arg.value.?,
            else => unreachable,
        }
    }

    if (output) |_| {
    } else {
        output = try std.mem.join(allocator, ".", []const []const u8{input.?, "out"});
    }

    const stdout_file = try std.io.getStdOut();

    const compressed = try io.readFileAlloc(allocator, input.?);

    var decompressor: decompress.Decompressor = undefined;
    const decompressed = try decompressor.decompressAlloc(allocator, compressed);

    try io.writeFile(output.?, decompressed);

    debug.warn("Input: {}\nOutput: {}\n", input, output);
}

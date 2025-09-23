const std = @import("std");
const clap = @import("clap");
const debug = std.debug;
const io = std.io;
const decompress = @import("lzig4").decompress;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // First we specify what parameters our program can take.
    const params = comptime clap.parseParamsComptime(
        \\-h, --help         display this help and exit
        \\-i, --input  <str> input file path
        \\-o, --output <str> output file path
        \\
        \\<str>...
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});
    }

    const input = res.args.input;
    const output = res.args.output;

    const cwd = std.fs.cwd();
    var input_file = try cwd.openFile(input.?, .{});
    var output_file = try cwd.createFile(output.?, .{});
    defer input_file.close();
    defer output_file.close();

    var input_buffer: [1024]u8 = undefined;
    var input_file_reader = input_file.reader(&input_buffer);
    const reader = &input_file_reader.interface;
    const compressed = try reader.readAlloc(allocator, 1024 * 1024 * 8);
    defer allocator.free(compressed);

    const data: []u8 = try allocator.alloc(u8, 1024 * 1024 * 16);
    defer allocator.free(data);
    var decompressor: decompress.Decompressor = undefined;
    var read: usize = undefined;
    var written: usize = undefined;
    try decompressor.decompress(compressed, &read, data[0..], &written);

    var output_buffer: [1024]u8 = undefined;
    var output_file_writer = output_file.writer(&output_buffer);
    const writer = &output_file_writer.interface;
    try writer.writeAll(data[0..written]);

    std.debug.print("Input: {?s}\nOutput: {?s}\n", .{ input, output });
}

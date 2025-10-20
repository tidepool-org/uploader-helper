// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const config = @import("config");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const windows = if (is_windows) std.os.windows else struct {};

const MAX_PATH = if (is_windows) std.os.windows.MAX_PATH + 1 else 260;

const HandleType = if (is_windows) std.os.windows.HANDLE else usize;

// Windows-specific external functions
const WindowsExterns = if (is_windows) struct {
    extern "kernel32" fn FindFirstVolumeW(lpBuffer: [*]u16, bufferLength: u32) ?std.os.windows.HANDLE;
    extern "kernel32" fn FindNextVolumeW(hFindVolume: std.os.windows.HANDLE, lpBuffer: [*]u16, bufferLength: u32) bool;
    extern "kernel32" fn FindVolumeClose(hFindVolume: std.os.windows.HANDLE) bool;
    extern "kernel32" fn GetVolumePathNamesForVolumeNameW(volumeName: [*]const u16, volumePathNames: [*]u16, bufferLength: u32, returnLength: *u32) bool;
} else struct {};

const Allocator = std.mem.allocator;

const OpenError = error{
    InvalidHandle,
    LockFailed,
    ReadFailed,
};

const FindError = error{
    FirstFailed,
    ConvertFailed,
    FindFailed,
    UnsupportedPlatform,
};

fn findDevice() ![:0]u16 {
    if (!is_windows) {
        try sendReply("error", "Device scanning not supported on this platform");
        return FindError.UnsupportedPlatform;
    }
    const IOCTL_STORAGE_QUERY_PROPERTY = 0x2D1400;

    const STORAGE_DEVICE_DESCRIPTOR = extern struct { Version: u32, Size: u32, DeviceType: u8, DeviceTypeModifier: u8, RemovableMedia: bool, CommandQueueing: bool, VendorIdOffset: u32, ProductIdOffset: u32, ProductRevisionOffset: u32, SerialNumberOffset: u32, BusType: u8, RawPropertiesLength: u32, RawDeviceProperties: [1]u8 };

    var volume_name_buffer: [MAX_PATH]u16 = undefined;
    var volume_path_names_buffer: [MAX_PATH]u16 = undefined;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const printAllocator = gpa.allocator();

    const find_volume_handle = WindowsExterns.FindFirstVolumeW(&volume_name_buffer, volume_name_buffer.len) orelse {
        try sendReply("error", "Failed to find first volume");
        return FindError.FirstFailed;
    };

    defer _ = WindowsExterns.FindVolumeClose(find_volume_handle);

    while (true) {
        // Convert volume name from UTF-16 to UTF-8 for printing
        const volume_name = std.unicode.utf16leToUtf8Alloc(std.heap.page_allocator, volume_name_buffer[0..]) catch {
            try sendReply("error", "Failed to convert volume name to UTF-8");
            return FindError.ConvertFailed;
        };
        std.debug.print("Volume Name: {s}\n", .{std.mem.sliceTo(volume_name[0..], 0)});

        // Get volume path names
        var return_length: u32 = 0;
        if (WindowsExterns.GetVolumePathNamesForVolumeNameW(&volume_name_buffer, &volume_path_names_buffer, volume_path_names_buffer.len, &return_length)) {
            const volume_path_names = try std.unicode.utf16leToUtf8Alloc(std.heap.page_allocator, volume_path_names_buffer[0..]);

            const path = std.mem.sliceTo(volume_path_names, 0);
            std.debug.print("Volume Path Names: {s}\n", .{path});

            if (path.len == 0) {
                if (!WindowsExterns.FindNextVolumeW(find_volume_handle, &volume_name_buffer, volume_name_buffer.len)) {
                    break;
                }
                continue;
            }

            const devicePath = try std.fmt.allocPrint(std.heap.page_allocator, "\\\\.\\{s}", .{path[0..2]});
            std.debug.print("Device Path: {s}\n", .{devicePath});

            const path_utf16 = try std.unicode.utf8ToUtf16LeWithNull(std.heap.page_allocator, devicePath);

            const volumeHandle = std.os.windows.kernel32.CreateFileW(path_utf16, std.os.windows.GENERIC_READ, std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE, null, std.os.windows.OPEN_EXISTING, std.os.windows.FILE_ATTRIBUTE_NORMAL, null);

            if (volumeHandle == std.os.windows.INVALID_HANDLE_VALUE) {
                std.log.err("Failed to open volume", .{});
                if (!WindowsExterns.FindNextVolumeW(find_volume_handle, &volume_name_buffer, volume_name_buffer.len)) {
                    break;
                }
                continue;
            }
            defer std.os.windows.CloseHandle(volumeHandle);

            const StoragePropertyQuery = packed struct { propertyId: u32, queryType: u32, parameters: u8 = undefined };

            const spq = StoragePropertyQuery{ .propertyId = 0, .queryType = 0 };
            var deviceDescriptor: [1024]u8 = undefined;

            std.os.windows.DeviceIoControl(
                volumeHandle,
                IOCTL_STORAGE_QUERY_PROPERTY,
                std.mem.asBytes(&spq),
                &deviceDescriptor,
            ) catch {
                std.log.err("Storage query failed", .{});
                continue;
            };

            const descriptor = std.mem.bytesAsSlice(STORAGE_DEVICE_DESCRIPTOR, deviceDescriptor[0..@sizeOf(STORAGE_DEVICE_DESCRIPTOR)]);
            std.debug.print("VendorIdOffset: {d}\n", .{descriptor[0].VendorIdOffset});
            std.debug.print("Size: {d}\n", .{descriptor[0].Size});

            const offset = descriptor[0].VendorIdOffset;
            const vendorID = std.mem.sliceTo(deviceDescriptor[offset..], 0);

            const slice = try std.fmt.allocPrint(printAllocator, "Vendor ID: {s}\n", .{vendorID});
            defer printAllocator.free(slice);
            try sendReply("info", slice);

            if (std.mem.eql(u8, vendorID, "LifeScan")) {
                return path_utf16;
            }
        } else {
            std.log.err("Failed to get volume path names", .{});
        }

        if (!WindowsExterns.FindNextVolumeW(find_volume_handle, &volume_name_buffer, volume_name_buffer.len)) {
            break;
        }
    }

    try sendReply("error", "Could not find device");
    return FindError.FindFailed;
}

fn openDevice() !HandleType {
    if (!is_windows) {
        try sendReply("error", "Device opening not supported on this platform");
        return OpenError.InvalidHandle;
    }

    const FSCTL_LOCK_VOLUME = 0x00090018;

    const devicePath = findDevice() catch |err| {
        try sendReply("error", "Could not find device");
        return err;
    };

    // Open the volume
    const handle = std.os.windows.kernel32.CreateFileW(devicePath, std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE, std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE, null, std.os.windows.OPEN_EXISTING, std.os.windows.FILE_FLAG_NO_BUFFERING, null);

    if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
        try sendReply("error", "Failed to open file");
        return OpenError.InvalidHandle;
    }

    // Lock the volume
    std.os.windows.DeviceIoControl(
        handle,
        FSCTL_LOCK_VOLUME,
        null,
        null,
    ) catch {
        try sendReply("error", "Failed to lock volume");
        std.os.windows.CloseHandle(handle);
        return OpenError.LockFailed;
    };

    try sendReply("success", "Volume locked successfully");
    return handle;
}

fn checkDevice(handle: HandleType) !void {
    if (!is_windows) {
        try sendReply("error", "Device checking not supported on this platform");
        return OpenError.ReadFailed;
    }

    const allocator = std.heap.page_allocator;
    const alignment = 4096;
    const size = 512;

    const buffer = try allocator.alignedAlloc(u8, alignment, size);
    defer allocator.free(buffer);

    @memset(buffer, 0);

    try sendReply("info", "Reading from volume..");

    var bytesRead: std.os.windows.DWORD = 0;
    const readSuccess = std.os.windows.kernel32.ReadFile(handle, buffer.ptr, size, &bytesRead, null);
    if (readSuccess == 0) {
        try sendReply("error", "Failed to read from volume");
        return OpenError.ReadFailed;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const printAllocator = gpa.allocator();

    const slice = try std.fmt.allocPrint(printAllocator, "Read {d} bytes from volume.", .{bytesRead});
    defer printAllocator.free(slice);
    try sendReply("info", slice);
    try sendReply("data", buffer[0x2b..0x3b]);
}

fn retrieveData(seekOffset: u64, linkLayerFrame: []const u8, handle: HandleType) !void {
    if (!is_windows) {
        try sendReply("error", "Data retrieval not supported on this platform");
        return OpenError.ReadFailed;
    }

    const allocator = std.heap.page_allocator;
    const alignment = 4096;
    const size = 512;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const printAllocator = gpa.allocator();

    const buffer = try allocator.alignedAlloc(u8, alignment, size);
    defer allocator.free(buffer);

    @memset(buffer, 0);
    @memcpy(buffer[0..linkLayerFrame.len], linkLayerFrame);

    try sendReply("info", "Sending request");

    _ = try std.os.windows.WriteFile(handle, buffer, seekOffset);

    @memset(buffer, 0);

    const bytesRead = try std.os.windows.ReadFile(handle, buffer, seekOffset);

    const slice = try std.fmt.allocPrint(printAllocator, "Read {d} bytes from volume.", .{bytesRead});
    defer printAllocator.free(slice);
    try sendReply("info", slice);
    try sendReply("data", buffer);
}

pub fn main() !void {
    const stdin = std.io.getStdIn().reader();
    var buffer: [4096]u8 = undefined;
    var handle: HandleType = undefined;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const Message = struct {
        command: []u8,
        request: [512]u8 = undefined,
        seekOffset: u64 = 0,
    };

    while (true) {
        // Read the length of the incoming message
        _ = try stdin.read(&buffer);

        const length = std.mem.readInt(u32, buffer[0..4], .little);

        // Read the message based on the length
        const message = std.mem.bytesAsSlice(u8, buffer[4..(length + 4)]);

        const parsed = try std.json.parseFromSlice(
            Message,
            allocator,
            message,
            .{},
        );

        const data = parsed.value;

        if (std.mem.eql(u8, data.command, "openDevice")) {
            try sendReply("info", "Trying to open device");
            handle = try openDevice();
        }

        if (std.mem.eql(u8, data.command, "checkDevice")) {
            try sendReply("info", "Checking device");
            try checkDevice(handle);
        }

        if (std.mem.eql(u8, data.command, "retrieveData")) {
            try sendReply("info", "Retrieving data");
            try retrieveData(data.seekOffset, &data.request, handle);
        }

        if (std.mem.eql(u8, data.command, "closeDevice")) {
            try sendReply("info", "Closing device");
            break;
        }

        if (std.mem.eql(u8, data.command, "getAppVersion")) {
            try sendReply("version", config.version);
        }

        parsed.deinit();
    }

    // exit gracefully
    if (is_windows) {
        std.os.windows.CloseHandle(handle);
    }
    std.process.exit(0);
}

fn sendReply(msgtype: []const u8, result: []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();

    const Reply = struct {
        msgType: []const u8,
        details: []const u8,
    };

    const x = Reply{
        .msgType = msgtype,
        .details = result,
    };

    try std.json.stringify(x, .{}, string.writer());

    var response_length: [4]u8 = undefined;
    std.mem.writeInt(u32, &response_length, @intCast(string.items.len), .little);
    _ = try stdout.write(&response_length);
    _ = try stdout.writeAll(string.items);
}

// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const config = @import("config");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const is_macos = builtin.os.tag == .macos;

const HandleType = if (is_windows) std.os.windows.HANDLE else i32;

// Windows-specific external functions
const WindowsExterns = if (is_windows) struct {
    extern "kernel32" fn FindFirstVolumeW(lpBuffer: [*]u16, bufferLength: u32) ?std.os.windows.HANDLE;
    extern "kernel32" fn FindNextVolumeW(hFindVolume: std.os.windows.HANDLE, lpBuffer: [*]u16, bufferLength: u32) bool;
    extern "kernel32" fn FindVolumeClose(hFindVolume: std.os.windows.HANDLE) bool;
    extern "kernel32" fn GetVolumePathNamesForVolumeNameW(volumeName: [*]const u16, volumePathNames: [*]u16, bufferLength: u32, returnLength: *u32) bool;
} else struct {};

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

// Helper function to allocate aligned buffers for device I/O
fn allocateAlignedBuffer(size: usize) ![]u8 {
    const allocator = std.heap.page_allocator;
    const buffer = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(Constants.DEVICE_BUFFER_ALIGNMENT), size);
    @memset(buffer, 0);
    return buffer;
}

// Helper function to send formatted reply messages
fn sendReplyFormatted(comptime msgtype: []const u8, comptime fmt: []const u8, args: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try sendReply(msgtype, message);
}

// Constants for device I/O and platform-specific operations
const Constants = struct {
    // Buffer allocation settings
    pub const DEVICE_BUFFER_ALIGNMENT = 4096;
    pub const DEVICE_BUFFER_SIZE = 512;
    pub const MAIN_BUFFER_SIZE = 4096;

    // Buffer sizes for device enumeration
    pub const DEVICE_PATH_BUFFER_SIZE = 256;
    pub const VENDOR_INFO_BUFFER_SIZE = 256;
    pub const REMOVABLE_CHECK_BUFFER_SIZE = 2;

    // Device data slicing (for extracting relevant portions)
    pub const DEVICE_DATA_START = 0x2b;
    pub const DEVICE_DATA_END = 0x3b;

    // Linux ioctl codes
    pub const LINUX_BLKFLSBUF = 0x1261;

    // macOS fcntl codes
    pub const MACOS_F_NOCACHE = 48;

    // Windows ioctl codes
    pub const WINDOWS_IOCTL_STORAGE_QUERY_PROPERTY = 0x2D1400;
    pub const WINDOWS_FSCTL_LOCK_VOLUME = 0x00090018;

    // Device path prefix for macOS
    pub const MACOS_DEV_PREFIX = "/dev/r";
    pub const MACOS_DEV_PREFIX_LEN = 6;
};

// Unix-like device structure (used on Linux and macOS)
const UnixDevice = struct {
    path: [:0]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *UnixDevice) void {
        self.allocator.free(self.path);
    }
};

fn findDeviceLinux() !UnixDevice {
    const allocator = std.heap.page_allocator;

    // Open /sys/block to enumerate block devices
    var sys_block_dir = std.fs.openDirAbsolute("/sys/block", .{ .iterate = true }) catch {
        try sendReply("error", "Failed to open /sys/block directory");
        return FindError.FindFailed;
    };
    defer sys_block_dir.close();

    var iterator = sys_block_dir.iterate();

    while (try iterator.next()) |entry| {
        if (entry.kind != .sym_link) continue;

        // Skip loop devices, ram disks, etc - focus on sd* devices (USB mass storage typically shows as sd*)
        if (!std.mem.startsWith(u8, entry.name, "sd")) continue;

        // Check if it's a removable device
        const removable_path = try std.fmt.allocPrint(allocator, "/sys/block/{s}/removable", .{entry.name});
        defer allocator.free(removable_path);

        const removable_file = std.fs.openFileAbsolute(removable_path, .{}) catch continue;
        defer removable_file.close();

        var removable_buf: [Constants.REMOVABLE_CHECK_BUFFER_SIZE]u8 = undefined;
        const bytes_read = try removable_file.readAll(&removable_buf);
        if (bytes_read == 0 or removable_buf[0] != '1') continue;

        // Try to find vendor information through USB device hierarchy
        const device_path = try std.fmt.allocPrint(allocator, "/sys/block/{s}/device", .{entry.name});
        defer allocator.free(device_path);

        // Read the vendor file
        const vendor_path = try std.fmt.allocPrint(allocator, "{s}/vendor", .{device_path});
        defer allocator.free(vendor_path);

        const vendor_file = std.fs.openFileAbsolute(vendor_path, .{}) catch continue;
        defer vendor_file.close();

        var vendor_buf: [Constants.VENDOR_INFO_BUFFER_SIZE]u8 = undefined;
        const vendor_bytes = try vendor_file.readAll(&vendor_buf);
        if (vendor_bytes == 0) continue;

        // Trim whitespace from vendor string
        const vendor = std.mem.trim(u8, vendor_buf[0..vendor_bytes], &std.ascii.whitespace);

        try sendReplyFormatted("info", "Found device {s} with vendor: {s}", .{ entry.name, vendor });

        // Check if this is a LifeScan device
        if (std.mem.eql(u8, vendor, "LifeScan")) {
            // Return the device path (e.g., /dev/sdb)
            const dev_path = try std.fmt.allocPrintSentinel(allocator, "/dev/{s}", .{entry.name}, 0);

            try sendReplyFormatted("info", "Found LifeScan device at {s}", .{dev_path});

            return UnixDevice{
                .path = dev_path,
                .allocator = allocator,
            };
        }
    }

    try sendReply("error", "Could not find LifeScan device");
    return FindError.FindFailed;
}

fn findDeviceMacOS() !UnixDevice {
    const allocator = std.heap.page_allocator;

    // On macOS, we look for disk devices in /dev
    // LifeScan devices typically appear as external USB drives

    var dev_dir = std.fs.openDirAbsolute("/dev", .{ .iterate = true }) catch |err| {
        try sendReply("error", "Failed to open /dev directory");
        return err;
    };
    defer dev_dir.close();

    var iterator = dev_dir.iterate();

    // First pass: collect all disk devices without trying to open them
    // Use a simpler approach: just collect the disk names and reconstruct paths as needed
    var disk_names = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (disk_names.items) |name| {
            allocator.free(name);
        }
        disk_names.deinit();
    }

    try sendReply("info", "Starting device enumeration in /dev");

    while (try iterator.next()) |entry| {
        // Only look at entries that start with "disk"
        if (!std.mem.startsWith(u8, entry.name, "disk")) continue;

        // Skip partitions for now, look for raw disks
        // Partitions have patterns like disk0s1, disk1s2, etc.
        // Raw disks are just disk0, disk1, disk2, etc.
        // Check if there's an 's' after "disk" and some digits
        var is_partition = false;
        if (entry.name.len > 4) { // "disk" is 4 chars
            for (entry.name[4..]) |char| {
                if (char == 's') {
                    is_partition = true;
                    break;
                }
            }
        }

        if (is_partition) {
            continue;
        }

        // Store a copy of the name
        const name_copy = try allocator.dupe(u8, entry.name);
        try disk_names.append(name_copy);
    }

    // Log summary
    try sendReplyFormatted("info", "Enumeration complete: found {d} raw disk devices", .{disk_names.items.len});

    // If we found any disk devices, verify they are LifeScan devices
    if (disk_names.items.len > 0) {
        // Try each disk, starting with non-system disks (disk1 or higher)
        for (disk_names.items) |disk_name| {
            // Skip disk0 and disk1 (typically system drives on macOS)
            if (std.mem.eql(u8, disk_name, "disk0") or std.mem.eql(u8, disk_name, "disk1")) {
                continue;
            }

            // Build the path manually to avoid allocPrintZ issues
            var path_buf: [Constants.DEVICE_PATH_BUFFER_SIZE]u8 = undefined;
            @memcpy(path_buf[0..Constants.MACOS_DEV_PREFIX_LEN], Constants.MACOS_DEV_PREFIX);
            @memcpy(path_buf[Constants.MACOS_DEV_PREFIX_LEN .. Constants.MACOS_DEV_PREFIX_LEN + disk_name.len], disk_name);
            path_buf[Constants.MACOS_DEV_PREFIX_LEN + disk_name.len] = 0;
            const dev_path = path_buf[0 .. Constants.MACOS_DEV_PREFIX_LEN + disk_name.len :0];

            // Try to verify it's a LifeScan device by reading from it
            const verify_file = std.fs.openFileAbsolute(dev_path, .{ .mode = .read_only }) catch {
                continue;
            };
            defer verify_file.close();

            // Try with aligned buffer for device I/O
            var aligned_buffer = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(Constants.DEVICE_BUFFER_ALIGNMENT), Constants.MAIN_BUFFER_SIZE);
            defer allocator.free(aligned_buffer);

            const bytes_read = std.posix.read(verify_file.handle, aligned_buffer) catch {
                continue;
            };

            // Look for LifeScan identifiers in the data
            if (bytes_read > 0) {
                const data = aligned_buffer[0..bytes_read];

                // Check for LifeScan string anywhere in the data
                if (std.mem.containsAtLeast(u8, data, 1, "LIFESCAN")) {
                    try sendReply("info", "Found LifeScan device");

                    const result_path = try allocator.dupeZ(u8, dev_path);
                    return UnixDevice{
                        .path = result_path,
                        .allocator = allocator,
                    };
                }
            }
        }
    }

    try sendReply("error", "Could not find any LifeScan devices");
    return FindError.FindFailed;
}

fn findDevice() ![:0]u16 {
    if (!is_windows) {
        try sendReply("error", "Device scanning not supported on this platform");
        return FindError.UnsupportedPlatform;
    }

    const MAX_PATH = std.os.windows.MAX_PATH + 1;
    const STORAGE_DEVICE_DESCRIPTOR = extern struct { Version: u32, Size: u32, DeviceType: u8, DeviceTypeModifier: u8, RemovableMedia: bool, CommandQueueing: bool, VendorIdOffset: u32, ProductIdOffset: u32, ProductRevisionOffset: u32, SerialNumberOffset: u32, BusType: u8, RawPropertiesLength: u32, RawDeviceProperties: [1]u8 };

    var volume_name_buffer: [MAX_PATH]u16 = undefined;
    var volume_path_names_buffer: [MAX_PATH]u16 = undefined;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const printAllocator = gpa.allocator();
    defer _ = gpa.deinit();

    const find_volume_handle = WindowsExterns.FindFirstVolumeW(&volume_name_buffer, volume_name_buffer.len) orelse {
        try sendReply("error", "Failed to find first volume");
        return FindError.FindFailed;
    };

    defer _ = WindowsExterns.FindVolumeClose(find_volume_handle);

    while (true) {
        // Convert volume name from UTF-16 to UTF-8 for printing
        const volume_name = std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, volume_name_buffer[0..]) catch {
            try sendReply("error", "Failed to convert volume name to UTF-8");
            return FindError.ConvertFailed;
        };
        defer std.heap.page_allocator.free(volume_name);
        std.debug.print("Volume Name: {s}\n", .{std.mem.sliceTo(volume_name[0..], 0)});

        // Get volume path names
        var return_length: u32 = 0;
        if (WindowsExterns.GetVolumePathNamesForVolumeNameW(&volume_name_buffer, &volume_path_names_buffer, volume_path_names_buffer.len, &return_length)) {
            const volume_path_names = try std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, volume_path_names_buffer[0..]);
            defer std.heap.page_allocator.free(volume_path_names);

            const path = std.mem.sliceTo(volume_path_names, 0);
            std.debug.print("Volume Path Names: {s}\n", .{path});

            if (path.len == 0) {
                if (!WindowsExterns.FindNextVolumeW(find_volume_handle, &volume_name_buffer, volume_name_buffer.len)) {
                    break;
                }
                continue;
            }

            const devicePath = try std.fmt.allocPrint(std.heap.page_allocator, "\\\\.\\{s}", .{path[0..2]});
            defer std.heap.page_allocator.free(devicePath);
            std.debug.print("Device Path: {s}\n", .{devicePath});

            const path_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, devicePath);

            const volumeHandle = std.os.windows.kernel32.CreateFileW(path_utf16, std.os.windows.GENERIC_READ, std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE, null, std.os.windows.OPEN_EXISTING, std.os.windows.FILE_ATTRIBUTE_NORMAL, null);

            if (volumeHandle == std.os.windows.INVALID_HANDLE_VALUE) {
                std.log.err("Failed to open volume", .{});
                std.heap.page_allocator.free(path_utf16);
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
                Constants.WINDOWS_IOCTL_STORAGE_QUERY_PROPERTY,
                std.mem.asBytes(&spq),
                &deviceDescriptor,
            ) catch {
                std.log.err("Storage query failed", .{});
                std.heap.page_allocator.free(path_utf16);
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
            std.heap.page_allocator.free(path_utf16);
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

var unix_device: ?UnixDevice = null;

fn openDeviceLinux() !std.fs.File {
    const device = try findDeviceLinux();

    // Store device info for later cleanup
    unix_device = device;

    // Open the device with O_DIRECT flag (equivalent to Windows FILE_FLAG_NO_BUFFERING)
    // This bypasses the page cache and ensures reads get fresh data from the device
    const flags = std.posix.O{
        .ACCMODE = .RDWR,
        .DIRECT = true,
    };

    const fd = std.posix.open(device.path, flags, 0) catch {
        try sendReply("error", "Failed to open device file");
        return error.OutOfMemory;
    };

    const file = std.fs.File{ .handle = fd };

    // Flush any cached data
    _ = std.os.linux.ioctl(file.handle, Constants.LINUX_BLKFLSBUF, 0);

    try sendReply("success", "Device opened successfully");
    return file;
}

fn openDeviceMacOS() !std.fs.File {
    const device = try findDeviceMacOS();

    // Store device info for later cleanup
    unix_device = device;

    // Try opening with std.fs which handles the flags better
    const file = std.fs.openFileAbsolute(device.path, .{
        .mode = .read_write,
    }) catch {
        const file2 = std.fs.openFileAbsolute(device.path, .{
            .mode = .read_only,
        }) catch {
            try sendReply("error", "Failed to open device file");
            return OpenError.InvalidHandle;
        };
        return file2;
    };

    // On macOS, use F_NOCACHE to disable caching (equivalent to O_DIRECT on Linux)
    _ = std.posix.fcntl(file.handle, Constants.MACOS_F_NOCACHE, 1) catch {
        try sendReply("error", "Failed to set F_NOCACHE flag");
        file.close();
        return OpenError.InvalidHandle;
    };

    try sendReply("success", "Device opened successfully");
    return file;
}

fn openDevice() !HandleType {
    if (is_macos) {
        const file = try openDeviceMacOS();
        return file.handle;
    }

    if (!is_windows) {
        const file = try openDeviceLinux();
        return file.handle;
    }

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
        Constants.WINDOWS_FSCTL_LOCK_VOLUME,
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

fn checkDeviceUnix(handle: HandleType) !void {
    const buffer = try allocateAlignedBuffer(Constants.DEVICE_BUFFER_SIZE);
    defer std.heap.page_allocator.free(buffer);

    try sendReply("info", "Reading from device..");

    // Create a File from the handle to use standard read operations
    const file = std.fs.File{ .handle = handle };

    // Seek to the beginning of the device
    try file.seekTo(0);

    // Read data from the device
    const bytesRead = try file.read(buffer);

    try sendReplyFormatted("info", "Read {d} bytes from device.", .{bytesRead});
    try sendReply("data", buffer[Constants.DEVICE_DATA_START..Constants.DEVICE_DATA_END]);
}

fn checkDevice(handle: HandleType) !void {
    if (!is_windows) {
        try checkDeviceUnix(handle);
        return;
    }

    const buffer = try allocateAlignedBuffer(Constants.DEVICE_BUFFER_SIZE);
    defer std.heap.page_allocator.free(buffer);

    try sendReply("info", "Reading from volume..");

    var bytesRead: std.os.windows.DWORD = 0;
    const readSuccess = std.os.windows.kernel32.ReadFile(handle, buffer.ptr, 512, &bytesRead, null);
    if (readSuccess == 0) {
        try sendReply("error", "Failed to read from volume");
        return OpenError.ReadFailed;
    }

    try sendReplyFormatted("info", "Read {d} bytes from volume.", .{bytesRead});
    try sendReply("data", buffer[Constants.DEVICE_DATA_START..Constants.DEVICE_DATA_END]);
}

fn retrieveDataUnix(seekOffset: u64, linkLayerFrame: []const u8, handle: HandleType) !void {
    const buffer = try allocateAlignedBuffer(Constants.DEVICE_BUFFER_SIZE);
    defer std.heap.page_allocator.free(buffer);

    @memcpy(buffer[0..linkLayerFrame.len], linkLayerFrame);

    try sendReply("info", "Sending request");

    // Use pwrite/pread to write/read at specific offset without changing file position
    // This matches the Windows behavior where WriteFile/ReadFile with offset don't move the pointer
    _ = try std.posix.pwrite(handle, buffer, seekOffset);

    @memset(buffer, 0);

    const bytesRead = try std.posix.pread(handle, buffer, seekOffset);

    try sendReplyFormatted("info", "Read {d} bytes from device.", .{bytesRead});
    try sendReply("data", buffer);
}

fn retrieveData(seekOffset: u64, linkLayerFrame: []const u8, handle: HandleType) !void {
    if (!is_windows) {
        try retrieveDataUnix(seekOffset, linkLayerFrame, handle);
        return;
    }

    const buffer = try allocateAlignedBuffer(Constants.DEVICE_BUFFER_SIZE);
    defer std.heap.page_allocator.free(buffer);

    @memcpy(buffer[0..linkLayerFrame.len], linkLayerFrame);

    try sendReply("info", "Sending request");

    _ = try std.os.windows.WriteFile(handle, buffer, seekOffset);

    @memset(buffer, 0);

    const bytesRead = try std.os.windows.ReadFile(handle, buffer, seekOffset);

    try sendReplyFormatted("info", "Read {d} bytes from volume.", .{bytesRead});
    try sendReply("data", buffer);
}

pub fn main() !void {
    const stdin = std.fs.File.stdin();
    var buffer: [Constants.MAIN_BUFFER_SIZE]u8 = undefined;
    var handle: ?HandleType = null;

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
            if (handle) |h| {
                try checkDevice(h);
            }
        }

        if (std.mem.eql(u8, data.command, "retrieveData")) {
            try sendReply("info", "Retrieving data");
            if (handle) |h| {
                try retrieveData(data.seekOffset, &data.request, h);
            }
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
        if (handle) |h| {
            std.os.windows.CloseHandle(h);
        }
    } else {
        // Close the file handle on Unix-like systems (Linux and macOS)
        if (handle) |h| {
            const file = std.fs.File{ .handle = h };
            file.close();
        }

        // Cleanup the device path allocation
        if (unix_device) |*dev| {
            dev.deinit();
        }
    }
    std.process.exit(0);
}

fn sendReply(msgtype: []const u8, result: []const u8) !void {
    const stdout = std.fs.File.stdout();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const Reply = struct {
        msgType: []const u8,
        details: []const u8,
    };

    const x = Reply{
        .msgType = msgtype,
        .details = result,
    };

    const json_string = try std.json.Stringify.valueAlloc(allocator, x, .{});
    defer allocator.free(json_string);

    var response_length: [4]u8 = undefined;
    std.mem.writeInt(u32, &response_length, @intCast(json_string.len), .little);
    _ = try stdout.write(&response_length);
    try stdout.writeAll(json_string);
}

// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const config = @import("config");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const is_macos = builtin.os.tag == .macos;

const HandleType = if (is_windows) std.os.windows.HANDLE else i32;

// Windows SetupAPI / storage types
const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

// {53F56307-B6BF-11D0-94F2-00A0C91EFB8B}
const GUID_DEVINTERFACE_DISK = GUID{
    .Data1 = 0x53F56307,
    .Data2 = 0xB6BF,
    .Data3 = 0x11D0,
    .Data4 = .{ 0x94, 0xF2, 0x00, 0xA0, 0xC9, 0x1E, 0xFB, 0x8B },
};

const SP_DEVINFO_DATA = extern struct {
    cbSize: u32,
    ClassGuid: GUID,
    DevInst: u32,
    Reserved: usize,
};

const SP_DEVICE_INTERFACE_DATA = extern struct {
    cbSize: u32,
    InterfaceClassGuid: GUID,
    Flags: u32,
    Reserved: usize,
};

const STORAGE_DEVICE_NUMBER = extern struct {
    DeviceType: u32,
    DeviceNumber: u32,
    PartitionNumber: u32,
};

const DIGCF_PRESENT: u32 = 0x2;
const DIGCF_DEVICEINTERFACE: u32 = 0x10;
// sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W): always 6 for Unicode builds
const SP_DEVICE_INTERFACE_DETAIL_DATA_CBSIZE: u32 = 6;

// Windows-specific external functions
const WindowsExterns = if (is_windows) struct {
    extern "kernel32" fn GetLogicalDrives() u32;
    extern "setupapi" fn SetupDiGetClassDevsW(
        ClassGuid: *const GUID,
        Enumerator: ?[*:0]const u16,
        hwndParent: ?std.os.windows.HANDLE,
        Flags: u32,
    ) std.os.windows.HANDLE;
    extern "setupapi" fn SetupDiEnumDeviceInterfaces(
        DeviceInfoSet: std.os.windows.HANDLE,
        DeviceInfoData: ?*SP_DEVINFO_DATA,
        InterfaceClassGuid: *const GUID,
        MemberIndex: u32,
        DeviceInterfaceData: *SP_DEVICE_INTERFACE_DATA,
    ) c_int;
    extern "setupapi" fn SetupDiGetDeviceInterfaceDetailW(
        DeviceInfoSet: std.os.windows.HANDLE,
        DeviceInterfaceData: *SP_DEVICE_INTERFACE_DATA,
        DeviceInterfaceDetailData: ?*anyopaque,
        DeviceInterfaceDetailDataSize: u32,
        RequiredSize: ?*u32,
        DeviceInfoData: ?*SP_DEVINFO_DATA,
    ) c_int;
    extern "setupapi" fn SetupDiDestroyDeviceInfoList(DeviceInfoSet: std.os.windows.HANDLE) c_int;
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
    const allocator = std.heap.page_allocator;
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
    pub const WINDOWS_IOCTL_STORAGE_GET_DEVICE_NUMBER: u32 = 0x002D1080;
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

// Use SetupAPI to enumerate disk device interfaces and find the LifeScan physical disk number.
// Avoids FindFirstVolumeW/FindNextVolumeW which trigger AV heuristics.
fn findLifeScanDiskNumber() !u32 {
    if (!is_windows) return FindError.UnsupportedPlatform;

    const STORAGE_DEVICE_DESCRIPTOR = extern struct { Version: u32, Size: u32, DeviceType: u8, DeviceTypeModifier: u8, RemovableMedia: bool, CommandQueueing: bool, VendorIdOffset: u32, ProductIdOffset: u32, ProductRevisionOffset: u32, SerialNumberOffset: u32, BusType: u8, RawPropertiesLength: u32, RawDeviceProperties: [1]u8 };
    const StoragePropertyQuery = packed struct { propertyId: u32, queryType: u32, parameters: u8 = undefined };

    const hDevInfo = WindowsExterns.SetupDiGetClassDevsW(&GUID_DEVINTERFACE_DISK, null, null, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (hDevInfo == std.os.windows.INVALID_HANDLE_VALUE) {
        try sendReply("error", "SetupDiGetClassDevsW failed");
        return FindError.FindFailed;
    }
    defer _ = WindowsExterns.SetupDiDestroyDeviceInfoList(hDevInfo);

    var memberIndex: u32 = 0;
    var ifaceData: SP_DEVICE_INTERFACE_DATA = undefined;
    while (true) : (memberIndex += 1) {
        ifaceData.cbSize = @sizeOf(SP_DEVICE_INTERFACE_DATA);
        if (WindowsExterns.SetupDiEnumDeviceInterfaces(hDevInfo, null, &GUID_DEVINTERFACE_DISK, memberIndex, &ifaceData) == 0) break;

        // Two-pass: first call gets required buffer size
        var requiredSize: u32 = 0;
        _ = WindowsExterns.SetupDiGetDeviceInterfaceDetailW(hDevInfo, &ifaceData, null, 0, &requiredSize, null);
        if (requiredSize < SP_DEVICE_INTERFACE_DETAIL_DATA_CBSIZE or requiredSize > 4096) continue;

        // Allocate and zero the detail buffer; set cbSize = 6 (Unicode SP_DEVICE_INTERFACE_DETAIL_DATA_W)
        const detailBuf = try std.heap.page_allocator.alloc(u8, requiredSize);
        defer std.heap.page_allocator.free(detailBuf);
        @memset(detailBuf, 0);
        std.mem.writeInt(u32, detailBuf[0..4], SP_DEVICE_INTERFACE_DETAIL_DATA_CBSIZE, .little);

        if (WindowsExterns.SetupDiGetDeviceInterfaceDetailW(hDevInfo, &ifaceData, detailBuf.ptr, requiredSize, null, null) == 0) continue;

        // DevicePath is UTF-16LE starting at byte offset 4; read char-by-char to avoid alignment issues
        const pathBytes = detailBuf[4..];
        var charCount: usize = 0;
        while (charCount * 2 + 2 <= pathBytes.len) : (charCount += 1) {
            if (std.mem.readInt(u16, pathBytes[charCount * 2 ..][0..2], .little) == 0) break;
        }

        var pathW: [512:0]u16 = undefined;
        const copyLen = @min(charCount, pathW.len - 1);
        for (0..copyLen) |i| {
            pathW[i] = std.mem.readInt(u16, pathBytes[i * 2 ..][0..2], .little);
        }
        pathW[copyLen] = 0;

        // Open device with read access for IOCTL queries
        const devHandle = std.os.windows.kernel32.CreateFileW(
            &pathW,
            std.os.windows.GENERIC_READ,
            std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE,
            null,
            std.os.windows.OPEN_EXISTING,
            std.os.windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (devHandle == std.os.windows.INVALID_HANDLE_VALUE) continue;
        defer std.os.windows.CloseHandle(devHandle);

        // Check vendor ID via storage property query
        const spq = StoragePropertyQuery{ .propertyId = 0, .queryType = 0 };
        var deviceDescriptor: [1024]u8 = undefined;
        std.os.windows.DeviceIoControl(
            devHandle,
            Constants.WINDOWS_IOCTL_STORAGE_QUERY_PROPERTY,
            std.mem.asBytes(&spq),
            &deviceDescriptor,
        ) catch continue;

        const desc = std.mem.bytesAsSlice(STORAGE_DEVICE_DESCRIPTOR, deviceDescriptor[0..@sizeOf(STORAGE_DEVICE_DESCRIPTOR)]);
        const vendorOffset = desc[0].VendorIdOffset;
        if (vendorOffset == 0 or vendorOffset >= deviceDescriptor.len) continue;
        const vendorID = std.mem.sliceTo(deviceDescriptor[vendorOffset..], 0);
        try sendReplyFormatted("info", "SetupAPI disk vendor: {s}", .{vendorID});

        if (!std.mem.eql(u8, vendorID, "LifeScan")) continue;

        // Get physical disk number for later drive-letter matching
        var sdn = std.mem.zeroes(STORAGE_DEVICE_NUMBER);
        std.os.windows.DeviceIoControl(
            devHandle,
            Constants.WINDOWS_IOCTL_STORAGE_GET_DEVICE_NUMBER,
            null,
            std.mem.asBytes(&sdn),
        ) catch continue;

        try sendReplyFormatted("info", "LifeScan disk number: {d}", .{sdn.DeviceNumber});
        return sdn.DeviceNumber;
    }

    try sendReply("error", "Could not find LifeScan disk via SetupAPI");
    return FindError.FindFailed;
}

fn findDevice() ![:0]u16 {
    if (!is_windows) {
        try sendReply("error", "Device scanning not supported on this platform");
        return FindError.UnsupportedPlatform;
    }

    // Find the LifeScan physical disk number via SetupAPI device interface enumeration
    const targetDiskNumber = try findLifeScanDiskNumber();

    // Match the disk number to a drive letter using GetLogicalDrives bitmask
    const driveMask = WindowsExterns.GetLogicalDrives();
    if (driveMask == 0) {
        try sendReply("error", "GetLogicalDrives failed");
        return FindError.FindFailed;
    }

    for (0..26) |i| {
        const bit: u5 = @intCast(i);
        if (driveMask & (@as(u32, 1) << bit) == 0) continue;

        const driveLetter: u8 = 'A' + @as(u8, @intCast(i));

        // Build \\.\X: as a sentinel-terminated UTF-16 buffer
        var drivePath: [6:0]u16 = .{ '\\', '\\', '.', '\\', 0, ':' };
        drivePath[4] = @as(u16, @intCast(driveLetter));

        const volHandle = std.os.windows.kernel32.CreateFileW(
            &drivePath,
            std.os.windows.GENERIC_READ,
            std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE,
            null,
            std.os.windows.OPEN_EXISTING,
            std.os.windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (volHandle == std.os.windows.INVALID_HANDLE_VALUE) continue;
        defer std.os.windows.CloseHandle(volHandle);

        var sdn = std.mem.zeroes(STORAGE_DEVICE_NUMBER);
        std.os.windows.DeviceIoControl(
            volHandle,
            Constants.WINDOWS_IOCTL_STORAGE_GET_DEVICE_NUMBER,
            null,
            std.mem.asBytes(&sdn),
        ) catch continue;

        if (sdn.DeviceNumber != targetDiskNumber) continue;

        try sendReplyFormatted("info", "Found LifeScan volume at {c}:", .{driveLetter});
        const resultPath = try std.heap.page_allocator.allocSentinel(u16, 6, 0);
        resultPath[0] = '\\';
        resultPath[1] = '\\';
        resultPath[2] = '.';
        resultPath[3] = '\\';
        resultPath[4] = @as(u16, @intCast(driveLetter));
        resultPath[5] = ':';
        return resultPath;
    }

    try sendReply("error", "Could not match LifeScan disk to a drive letter");
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
        return OpenError.InvalidHandle;
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
    defer std.heap.page_allocator.free(devicePath);

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
        defer parsed.deinit();

        const data = parsed.value;

        if (std.mem.eql(u8, data.command, "openDevice")) {
            try sendReply("info", "Trying to open device");
            handle = try openDevice();
        }

        if (std.mem.eql(u8, data.command, "checkDevice")) {
            if (handle) |h| {
                try sendReply("info", "Checking device");
                try checkDevice(h);
            } else {
                try sendReply("error", "Device not open");
            }
        }

        if (std.mem.eql(u8, data.command, "retrieveData")) {
            if (handle) |h| {
                try sendReply("info", "Retrieving data");
                try retrieveData(data.seekOffset, &data.request, h);
            } else {
                try sendReply("error", "Device not open");
            }
        }

        if (std.mem.eql(u8, data.command, "closeDevice")) {
            try sendReply("info", "Closing device");
            break;
        }

        if (std.mem.eql(u8, data.command, "getAppVersion")) {
            try sendReply("version", config.version);
        }
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
    _ = gpa.deinit();
    std.process.exit(0);
}

fn sendReply(msgtype: []const u8, result: []const u8) !void {
    const stdout = std.fs.File.stdout();
    const allocator = std.heap.page_allocator;

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

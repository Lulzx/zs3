const std = @import("std");

pub const Role = enum {
    Admin,
    Reader,
    Writer,
    Unknown,
};

pub const Credential = struct {
    access_key: []const u8,
    secret_key: []const u8,
    role: Role,
};

// Function to convert string to Role enum
pub fn stringToRole(role_str: []const u8) !Role {
    if (std.mem.eql(u8, role_str, "admin")) {
        return Role.Admin;
    } else if (std.mem.eql(u8, role_str, "reader")) {
        return Role.Reader;
    } else if (std.mem.eql(u8, role_str, "writer")) {
        return Role.Writer;
    } else {
        return error.BadCredentialRole;
    }
}

// Function to parse a single credential string: "role:access_key:secret_key"
pub fn parseCredential(cred_str: []const u8) !Credential {
    var itr = std.mem.splitScalar(u8, cred_str, ':');

    const role_str = itr.next() orelse return error.BadCredentialFormat;
    const access_key = itr.next() orelse return error.BadCredentialFormat;
    const secret_key = itr.next() orelse return error.BadCredentialFormat;

    // Reject extra fields
    if (itr.next() != null) return error.BadCredentialFormat;

    // Reject empty fields
    if (role_str.len == 0 or access_key.len == 0 or secret_key.len == 0)
        return error.BadCredentialFormat;

    return Credential{
        .role = try stringToRole(role_str),
        .access_key = access_key,
        .secret_key = secret_key,
    };
}

// Function to parse a list of credential strings
pub fn parseCredentials(allocator: std.mem.Allocator, input: []const u8) ![]Credential {
    if (input.len == 0) {
        return error.BadCredentialInputFormat;
    }

    var credentials = std.ArrayListUnmanaged(Credential){};
    errdefer credentials.deinit(allocator);

    var itr = std.mem.splitScalar(u8, input, ',');
    while (itr.next()) |record| {
        if (record.len == 0) continue;

        const pc = try parseCredential(record);

        try credentials.append(allocator, pc);
    }

    if (credentials.items.len == 0) return error.BadCredentialInputFormat;

    return credentials.toOwnedSlice(allocator);
}

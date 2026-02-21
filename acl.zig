const std = @import("std");

pub const Role = enum {
    Admin,
    Reader,
    Writer,
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
    if (std.mem.count(u8, cred_str, ":") != 2) {
        return error.BadCredentialFormat;
    }

    var itr = std.mem.tokenizeSequence(u8, cred_str, ":");

    return Credential{
        .role = try stringToRole(itr.next().?),
        .access_key = itr.next().?,
        .secret_key = itr.next().?,
    };
}

// Function to parse a list of credential strings
pub fn parseCredentials(allocator: std.mem.Allocator, input: []const u8) ![]Credential {
    const count = std.mem.count(u8, input, ":");

    if (count < 2) {
        return error.BadCredentialInputFormat;
    }

    var credentials = try std.ArrayList(Credential).initCapacity(allocator, count / 2);

    var itr = std.mem.tokenizeSequence(u8, input, ",");

    if (itr.peek() == null) {
        const pc = try parseCredential(input);
        try credentials.append(allocator, pc);
    } else {
        while (itr.next()) |record| {
            const pc = try parseCredential(record);
            try credentials.append(allocator, pc);
        }
    }

    return credentials.toOwnedSlice(allocator);
}

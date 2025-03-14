const std = @import("std");
const Allocator = std.mem.Allocator;
const zopengl = @import("zopengl");
const gl = zopengl.bindings;
const Shader = @This();

// The program ID
ID: c_uint,

pub fn create(gpa: Allocator, vs_path: []const u8, fs_path: []const u8) Shader {
    var arena_allocator_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator_state.deinit();
    const arena = arena_allocator_state.allocator();

    // Create vertex shader
    var vertexShader: c_uint = undefined;
    vertexShader = gl.createShader(gl.VERTEX_SHADER);
    defer gl.deleteShader(vertexShader);

    const vs_file = std.fs.cwd().openFile(vs_path, .{}) catch unreachable;
    defer vs_file.close();
    const vs_code = vs_file.readToEndAllocOptions(arena, (10 * 1024), null, @alignOf(u8), 0) catch unreachable;

    const fs_file = std.fs.cwd().openFile(fs_path, .{}) catch unreachable;
    defer fs_file.close();
    const fs_code = fs_file.readToEndAllocOptions(arena, (10 * 1024), null, @alignOf(u8), 0) catch unreachable;

    // Attach the shader source to the vertex shader object and compile it
    gl.shaderSource(vertexShader, 1, @as([*c]const [*c]const u8, @ptrCast(&vs_code)), 0);
    gl.compileShader(vertexShader);

    // Check if vertex shader was compiled successfully
    var success: c_int = undefined;
    var infoLog: [512]u8 = [_]u8{0} ** 512;

    gl.getShaderiv(vertexShader, gl.COMPILE_STATUS, &success);

    if (success == 0) {
        gl.getShaderInfoLog(vertexShader, 512, 0, &infoLog);
        std.log.err("{s}", .{infoLog});
    }

    // Fragment shader
    var fragmentShader: c_uint = undefined;
    fragmentShader = gl.createShader(gl.FRAGMENT_SHADER);
    defer gl.deleteShader(fragmentShader);

    gl.shaderSource(fragmentShader, 1, @as([*c]const [*c]const u8, @ptrCast(&fs_code)), 0);
    gl.compileShader(fragmentShader);

    gl.getShaderiv(fragmentShader, gl.COMPILE_STATUS, &success);

    if (success == 0) {
        gl.getShaderInfoLog(fragmentShader, 512, 0, &infoLog);
        std.log.err("{s}", .{infoLog});
    }

    // create a program object
    const shaderProgram = gl.createProgram();

    // attach compiled shader objects to the program object and link
    gl.attachShader(shaderProgram, vertexShader);
    gl.attachShader(shaderProgram, fragmentShader);
    gl.linkProgram(shaderProgram);

    // check if shader linking was successfull
    gl.getProgramiv(shaderProgram, gl.LINK_STATUS, &success);
    if (success == 0) {
        gl.getProgramInfoLog(shaderProgram, 512, 0, &infoLog);
        std.log.err("{s}", .{infoLog});
    }
    return Shader{ .ID = shaderProgram };
}

pub fn use(self: Shader) void {
    gl.useProgram(self.ID);
}

pub fn setBool(self: Shader, name: [*c]const u8, value: bool) void {
    gl.uniform1i(gl.getUniformLocation(self.ID, name), @intFromBool(value));
}

pub fn setInt(self: Shader, name: [*c]const u8, value: u32) void {
    gl.uniform1i(gl.getUniformLocation(self.ID, name), @intCast(value));
}

pub fn setFloat(self: Shader, name: [*c]const u8, value: f32) void {
    gl.uniform1f(gl.getUniformLocation(self.ID, name), value);
}

pub fn setVec3f(self: Shader, name: [*c]const u8, value: [3]f32) void {
    gl.uniform3f(gl.getUniformLocation(self.ID, name), value[0], value[1], value[2]);
}

pub fn setMat4f(self: Shader, name: [*c]const u8, value: [16]f32) void {
    const matLoc = gl.getUniformLocation(self.ID, name);
    gl.uniformMatrix4fv(matLoc, 1, gl.FALSE, &value);
}
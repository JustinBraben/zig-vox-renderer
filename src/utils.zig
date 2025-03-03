const std = @import("std");
const math = std.math;
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const zstbi = @import("zstbi");
const zm = @import("zmath");
const gl = zopengl.bindings;

pub const ConfigOptions = struct {
    width: i32 = 1280,
    height: i32 = 720,
    gl_major: i32 = 4,
    gl_minor: i32 = 1,
};

pub fn initOpenGL(window_title: []const u8,  config: ConfigOptions) !*glfw.Window {
	try glfw.init();
    glfw.windowHintTyped(.context_version_major, config.gl_major);
    glfw.windowHintTyped(.context_version_minor, config.gl_minor);
    glfw.windowHintTyped(.opengl_profile, .opengl_core_profile);
    glfw.windowHintTyped(.opengl_forward_compat, true);
    glfw.windowHintTyped(.client_api, .opengl_api);
    glfw.windowHintTyped(.doublebuffer, true);

    var window = glfw.Window.create(config.width, config.height, window_title, null) catch |e| {
        std.io.getStdErr().writer().print("Failed to create GLFW window\n", .{}) catch {};
        return e;
    };
    _ = &window;

    glfw.makeContextCurrent(window);
    try zopengl.loadCoreProfile(glfw.getProcAddress, @intCast(config.gl_major), @intCast(config.gl_minor));
    glfw.swapInterval(1);

    gl.viewport(0, 0, config.width, config.height);

	return window;
}

pub fn deinitOpenGL(window: *glfw.Window) void {
    window.destroy();
    glfw.terminate();
}

/// Helper function to flatten the matrices
pub fn flattenMatrices(matrices: []const [16]f32, allocator: std.mem.Allocator) ![]f32 {
    var flattened = try allocator.alloc(f32, matrices.len * 16);
    for (matrices, 0..) |matrix, i| {
        @memcpy(flattened[i * 16 .. (i + 1) * 16], &matrix);
    }
    return flattened;
}

pub fn SaveTexture(path: []const u8, texture: gl.UInt) void {
    var image1 = zstbi.Image.loadFromFile(path, 0) catch unreachable;
    defer image1.deinit();

    var width: gl.Int = undefined;
    var height: gl.Int = undefined;
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.getTexLevelParameteriv(gl.TEXTURE_2D, 0, gl.TEXTURE_WIDTH, &width);
    gl.getTexLevelParameteriv(gl.TEXTURE_2D, 0, gl.TEXTURE_HEIGHT, &height);
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.getTexImage(gl.TEXTURE_2D, 0, gl.RGBA, gl.UNSIGNED_BYTE, @ptrCast(image1.data));
    zstbi.Image.writeToFile(image1, path, .png) catch unreachable;
}

pub fn loadTexture(path: [:0]const u8) !gl.Uint {
    var textureID: gl.Uint = undefined;
    gl.genTextures(1, &textureID);
    gl.bindTexture(gl.TEXTURE_2D, textureID);

    var texture_image = try zstbi.Image.loadFromFile(path, 0);
    defer texture_image.deinit();

    const format: gl.Enum = switch (texture_image.num_components) {
        1 => gl.RED,
        3 => gl.RGB,
        4 => gl.RGBA,
        else => unreachable,
    };

    std.debug.print("{s} is {}\n", .{path, format});

    // set the texture1 wrapping parameters
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT); // set texture wrapping to GL_REPEAT (default wrapping method)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
    // set textureID filtering parameters
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

    // Generate the textureID
    gl.texImage2D(
        gl.TEXTURE_2D, 
        0, 
        format, 
        @as(c_int, @intCast(texture_image.width)), 
        @as(c_int, @intCast(texture_image.height)), 
        0, 
        format, 
        gl.UNSIGNED_BYTE, 
        @ptrCast(texture_image.data));
    gl.generateMipmap(gl.TEXTURE_2D);

    return textureID;
}

/// loads a cubemap texture from 6 individual texture faces
/// order:
/// +X (right)
/// -X (left)
/// +Y (top)
/// -Y (bottom)
/// +Z (front) 
/// -Z (back)
pub fn loadCubemap(faces: []const [:0]const u8) !gl.Uint {
    var textureID: gl.Uint = undefined;
    gl.genTextures(1, &textureID);
    gl.bindTexture(gl.TEXTURE_CUBE_MAP, textureID);

    for (faces, 0..) |face, i| {
        var texture_image = try zstbi.Image.loadFromFile(face, 0);
        defer texture_image.deinit();

        const format: gl.Enum = switch (texture_image.num_components) {
            1 => gl.RED,
            3 => gl.RGB,
            4 => gl.RGBA,
            else => unreachable,
        };

        // Generate the textureID
        gl.texImage2D(
            gl.TEXTURE_CUBE_MAP_POSITIVE_X + @as(c_uint, @intCast(i)), 
            0, 
            format, 
            @as(c_int, @intCast(texture_image.width)), 
            @as(c_int, @intCast(texture_image.height)), 
            0, 
            format, 
            gl.UNSIGNED_BYTE, 
            @ptrCast(texture_image.data));
        gl.generateMipmap(gl.TEXTURE_2D);

    }

    // std.debug.print("{s} is {}\n", .{path, format});

    // set the texture1 wrapping parameters

    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE);

    return textureID;
}

/// To use certain opengl and glfw functions
/// tests need to start with this
pub fn SetupGlfwForTests() !*glfw.Window {
    try glfw.init();
    glfw.windowHintTyped(.context_version_major, 4);
    glfw.windowHintTyped(.context_version_minor, 1);
    glfw.windowHintTyped(.opengl_profile, .opengl_core_profile);
    glfw.windowHintTyped(.opengl_forward_compat, true);
    glfw.windowHintTyped(.client_api, .opengl_api);
    glfw.windowHintTyped(.doublebuffer, true);
    var window = glfw.Window.create(800, 600, "LearnOpenGL", null) catch |e| {
        std.io.getStdErr().writer().print("Failed to create GLFW window\n", .{}) catch {};
        return e;
    };
    _ = &window;
    glfw.makeContextCurrent(window);
    try zopengl.loadCoreProfile(glfw.getProcAddress, 4, 1);

    return window;
}

/// Clean up for tests
pub fn DeinitGlfwForTests(window: *glfw.Window) void {
    window.destroy();
    glfw.terminate();
}

/// Create the transformation matrices:
/// Degree to radians conversion factor
pub const RAD_CONVERSION = math.pi / 180.0;

pub fn radians(input: f32) f32 {
    return RAD_CONVERSION * input;
}
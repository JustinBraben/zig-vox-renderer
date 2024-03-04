const std = @import("std");

// Relative to root folder
// Use with std.fs.cwd().openFile(assets.some_file_path)
const root_path = "assets/";
const sprites_path = root_path ++ "images/";

pub const sprites_sheet_png = @embedFile("assets/images/sheet.png");
pub const animation_sheet_png = @embedFile("assets/images/AnimationSheet_Character.png");

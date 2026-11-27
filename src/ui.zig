//! On-screen UI: the in-game HUD and the dvui debug panel. The dvui SDL/Vulkan backend
//! (ui/SdlVkBackend.zig) is its own build module, imported as `sdl_vk_backend`.

pub const hud = @import("ui/hud.zig");
pub const debug_ui = @import("ui/debug_ui.zig");

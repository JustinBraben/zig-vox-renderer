const std = @import("std");
const BlockType = @import("block.zig").BlockType;

// Constants for chunk dimensions
pub const chunk_size = 16;
pub const chunk_height = chunk_size * chunk_size;
pub const chunk_volume = chunk_size * chunk_size * chunk_size;
pub const section_height = 16;
pub const sections_per_chunk = chunk_height / section_height;

/// Block position within a chunk
const BlockPos = struct {
    x: u4, // 4 bits for 0-15
    y: u8, // 8 bits for 0-255
    z: u4, // 4 bits for 0-15
};

/// Section represents a 16x16x16 cube of blocks
pub const Section = struct {
    /// Palette-based block storage
    blocks: [section_height][chunk_size][chunk_size]u16,
    /// Palette maps block IDs to actual block types
    palette: std.ArrayList(BlockType),
    /// Bit indicating if section contains any non-air blocks
    is_empty: bool,

    pub fn init(allocator: std.mem.Allocator) !Section {
        var section = Section{
            .blocks = std.mem.zeroes([section_height][chunk_size][chunk_size]u16),
            .palette = std.ArrayList(BlockType).init(allocator),
            .is_empty = true,
        };
        // Add air as first palette entry
        try section.palette.append(.Air);
        return section;
    }

    pub fn getBlock(self: *const Section, x: u4, y: u4, z: u4) BlockType {
        const palette_id = self.blocks[y][z][x];
        return self.palette.items[palette_id];
    }
};

// Chunk contains multiple sections
const Chunk = struct {
    sections: [SECTIONS_PER_CHUNK]?Section,
    // World position of chunk
    chunk_x: i32,
    chunk_z: i32,
    
    pub fn init(allocator: std.mem.Allocator, x: i32, z: i32) !Chunk {
        var chunk = Chunk{
            .sections = std.mem.zeroes([sections_per_chunk]?Section),
            .chunk_x = x,
            .chunk_z = z,
        };
        
        // Initialize only non-empty sections
        for (0..sections_per_chunk) |i| {
            chunk.sections[i] = null;
        }
        
        return chunk;
    }

    // Get section, initializing it if needed
    pub fn getOrCreateSection(self: *Chunk, y: u8, allocator: std.mem.Allocator) !*Section {
        const section_index = y / section_height;
        if (self.sections[section_index] == null) {
            self.sections[section_index] = try Section.init(allocator);
        }
        return &self.sections[section_index].?;
    }
};

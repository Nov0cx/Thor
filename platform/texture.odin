package platform

import "core:c"
import "core:log"
import "core:strings"
import rl "vendor:raylib"

import ui "../vendor/loom/loom"

// The pixel layouts Thor uploads.
Pixel_Format :: enum u8 {
    Gray,
    Gray_Alpha,
    RGBA,
}

// How a texture is sampled when it is drawn at another size.
Filter :: enum u8 {
    Point,
    Bilinear,
    Trilinear,
}

// A texture on the GPU. `id` is 0 for none. `levels` and `format` are backend data.
Texture :: struct {
    id:            u32,
    width, height: i32,
    levels:        i32,
    format:        i32,
}

// A decoded image in CPU memory, owned by this package: free it with image_free.
Image :: struct {
    data:          rawptr,
    width, height: i32,
    levels:        i32,
    format:        i32,
}

@(private)
to_rl_texture :: proc(t: Texture) -> rl.Texture2D {
    return {id = c.uint(t.id), width = t.width, height = t.height, mipmaps = t.levels, format = rl.PixelFormat(t.format)}
}

@(private)
from_rl_texture :: proc(t: rl.Texture2D) -> Texture {
    return {id = u32(t.id), width = t.width, height = t.height, levels = t.mipmaps, format = i32(t.format)}
}

@(private)
to_rl_image :: proc(i: Image) -> rl.Image {
    return {data = i.data, width = i.width, height = i.height, mipmaps = i.levels, format = rl.PixelFormat(i.format)}
}

@(private)
from_rl_image :: proc(i: rl.Image) -> Image {
    return {data = i.data, width = i.width, height = i.height, levels = i.mipmaps, format = i32(i.format)}
}

@(private)
to_rl_rect :: proc(r: ui.Rect) -> rl.Rectangle {
    return {r.x, r.y, r.w, r.h}
}

@(private)
to_rl_format :: proc(f: Pixel_Format) -> rl.PixelFormat {
    switch f {
    case .Gray:
        return .UNCOMPRESSED_GRAYSCALE
    case .Gray_Alpha:
        return .UNCOMPRESSED_GRAY_ALPHA
    case .RGBA:
        return .UNCOMPRESSED_R8G8B8A8
    }
    return .UNCOMPRESSED_R8G8B8A8
}

// Decodes an encoded image (`ext` names the format, ".png"). Safe on a worker
// thread: it touches no GPU state.
image_decode :: proc(ext: string, data: []u8) -> (Image, bool) {
    if len(data) == 0 {
        return {}, false
    }
    ext_c := strings.clone_to_cstring(ext, context.temp_allocator)
    image := rl.LoadImageFromMemory(ext_c, raw_data(data), c.int(len(data)))
    if !rl.IsImageValid(image) {
        rl.UnloadImage(image)
        return {}, false
    }
    return from_rl_image(image), true
}

// Loads and decodes an image file.
image_load :: proc(path: string) -> (Image, bool) {
    image := rl.LoadImage(strings.clone_to_cstring(path, context.temp_allocator))
    if !rl.IsImageValid(image) {
        rl.UnloadImage(image)
        return {}, false
    }
    return from_rl_image(image), true
}

image_free :: proc(image: ^Image) {
    if image.data != nil {
        rl.UnloadImage(to_rl_image(image^))
    }
    image^ = {}
}

// Uploads `image` to the GPU. The image stays owned by the caller.
texture_from_image :: proc(image: Image) -> (Texture, bool) {
    tex := rl.LoadTextureFromImage(to_rl_image(image))
    if tex.id == 0 {
        return {}, false
    }
    return from_rl_texture(tex), true
}

// Uploads `width` × `height` pixels in `format`. The pixels stay owned by the caller.
texture_from_pixels :: proc(pixels: rawptr, width, height: i32, format: Pixel_Format) -> (Texture, bool) {
    image := rl.Image{data = pixels, width = width, height = height, mipmaps = 1, format = to_rl_format(format)}
    tex   := rl.LoadTextureFromImage(image)
    if tex.id == 0 {
        return {}, false
    }
    return from_rl_texture(tex), true
}

// Loads an image file straight into a texture.
texture_load :: proc(path: string) -> (Texture, bool) {
    tex := rl.LoadTexture(strings.clone_to_cstring(path, context.temp_allocator))
    if tex.id == 0 {
        log.warnf("Could not load texture %q", path)
        return {}, false
    }
    return from_rl_texture(tex), true
}

// Overwrites `rect` of `tex` with `pixels`, laid out in the texture's own format.
texture_update :: proc(tex: Texture, rect: ui.Rect, pixels: rawptr) {
    rl.UpdateTextureRec(to_rl_texture(tex), to_rl_rect(rect), pixels)
}

texture_free :: proc(tex: Texture) {
    if tex.id != 0 {
        rl.UnloadTexture(to_rl_texture(tex))
    }
}

texture_set_filter :: proc(tex: Texture, filter: Filter) {
    f: rl.TextureFilter
    switch filter {
    case .Point:
        f = .POINT
    case .Bilinear:
        f = .BILINEAR
    case .Trilinear:
        f = .TRILINEAR
    }
    rl.SetTextureFilter(to_rl_texture(tex), f)
}

// Builds the mipmap chain of `tex`, so it stays smooth when drawn far below its size.
texture_gen_mipmaps :: proc(tex: ^Texture) {
    t := to_rl_texture(tex^)
    rl.GenTextureMipmaps(&t)
    tex^ = from_rl_texture(t)
}

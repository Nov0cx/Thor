package widgets

import "core:math"
import "core:testing"

// Only the pure helpers are testable headlessly: everything else in
// model_view.odin needs a GL context. Run from the repository root:
// odin test widgets

// need passes through under one step, else rounds up to a whole step clamped
// to MODEL_TARGET_MAX; the result is always >= need, and stays under 2x need
// once it does round up (see model_view_target_size's comment for why that
// bound is what keeps model_view_fovy's compensation small).
@(test)
test_model_target_size_rounds_up_and_clamps :: proc(t: ^testing.T) {
    cases := [?][2]i32{{1, 1}, {127, 127}, {128, 128}, {129, 256}, {4090, 4096}}
    for c in cases {
        need, want := c[0], c[1]
        got := model_view_target_size(need)
        testing.expectf(t, got == want, "model_view_target_size(%d) = %d, want %d", need, got, want)
        testing.expectf(t, got >= need, "model_view_target_size(%d) = %d must be >= need", need, got)
        if got > MODEL_TARGET_STEP {
            testing.expectf(t, got < 2 * need, "model_view_target_size(%d) = %d must stay under 2x need", need, got)
        }
    }
}

// model_view_fovy must widen the camera by exactly the ratio a centred crop
// needs to still span MODEL_FOV: tan(fovy'/2) * need_h/target_h must recover
// tan(MODEL_FOV/2), and an exact match must pass MODEL_FOV through unchanged.
@(test)
test_model_fovy_keeps_the_crop_framing :: proc(t: ^testing.T) {
    want_half := math.tan(math.to_radians(MODEL_FOV) * 0.5)

    testing.expect_value(t, model_view_fovy(512, 512), MODEL_FOV)

    pairs := [?][2]i32{{256, 200}, {384, 257}, {4096, 1080}, {150, 149}}
    for p in pairs {
        target_h, need_h := p[0], p[1]
        fovy := model_view_fovy(target_h, need_h)
        got_half := math.tan(math.to_radians(fovy) * 0.5) * f32(need_h) / f32(target_h)
        testing.expectf(
            t, abs(got_half - want_half) < 1e-5,
            "model_view_fovy(%d, %d) = %f does not keep the crop's framing (got %f, want %f)",
            target_h, need_h, fovy, got_half, want_half,
        )
    }
}

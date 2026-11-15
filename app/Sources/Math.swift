import simd

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self.init(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(t.x, t.y, t.z, 1)
        ))
    }

    /// Reverse-Z perspective with an infinite far plane: depth is 1 at `near` and 0 at infinity.
    init(perspectiveFovY fovY: Float, aspect: Float, near: Float) {
        let f = 1 / tan(fovY / 2)
        self.init(columns: (
            SIMD4(f / aspect, 0, 0, 0),
            SIMD4(0, f, 0, 0),
            SIMD4(0, 0, 0, -1),
            SIMD4(0, 0, near, 0)
        ))
    }
}

import simd

/// Model: an oriented box describing a measured object, in world space (meters).
/// `xAxis` is the length direction and `zAxis` the width direction; both are
/// horizontal. The vertical axis is always world-up (0,1,0).
struct BoxMeasurement {
    var center: SIMD3<Float>
    var xAxis: SIMD3<Float>
    var zAxis: SIMD3<Float>
    var length: Float
    var width: Float
    var height: Float
}

import QtQuick

// The rest of a swipe, after the fingers lift.
//
// A fixed-length eased animation starts from a standstill, so however fast the
// hand was moving, the overview visibly stops and then sets off again — the
// hitch you feel at the end of a gesture that otherwise tracked perfectly. A
// spring starts at the speed the fingers left it with and decelerates into
// place, so the hand-off is invisible.
//
// Critically damped, and stopped on the frame it reaches its target rather
// than allowed to wobble through it: an overview that bounces past "open"
// would drop the keyboard and pick it up again.
FrameAnimation {
  id: spring

  property real value: 0
  property real velocity: 0          // per second
  property real target: 0
  // How stiff. Settles in about 4.7 / stiffness seconds from a standstill.
  property real stiffness: 17

  signal settled()

  function launch(from, to, speed) {
    spring.value = from
    spring.target = to
    spring.velocity = speed || 0
    if (Math.abs(from - to) < 0.0005 && Math.abs(spring.velocity) < 0.01) {
      spring.value = to
      spring.stop()
      spring.settled()
      return
    }
    spring.restart()
  }

  onTriggered: {
    // Small fixed steps, so a dropped frame does not become a jump.
    let left = Math.min(spring.frameTime, 1 / 30)
    const w = spring.stiffness
    let x = spring.value
    let v = spring.velocity
    const to = spring.target
    const before = x - to
    while (left > 0) {
      const dt = Math.min(left, 1 / 240)
      const a = -w * w * (x - to) - 2 * w * v
      v += a * dt
      x += v * dt
      left -= dt
    }
    const after = x - to
    if ((before !== 0 && Math.sign(after) !== Math.sign(before))
        || (Math.abs(after) < 0.0005 && Math.abs(v) < 0.02)) {
      // Settled is said while still running, so anything that hands the
      // position over to something else does it before anyone sees the
      // animation as finished.
      spring.value = to
      spring.velocity = 0
      spring.settled()
      spring.stop()
      return
    }
    spring.velocity = v
    spring.value = x
  }
}

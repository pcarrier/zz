package surf.zz.browser.tab

/**
 * Pure page-zoom level math: defaults, clamping, and stepping. Kept free of any
 * WebView/UI state so the clamp/step behavior is unit-testable in isolation.
 *
 * Direct port of the Swift `enum PageZoom` (Tab.swift:126).
 */
object PageZoom {
    const val defaultLevel: Double = 1.0
    const val minLevel: Double = 0.5
    const val maxLevel: Double = 3.0
    const val step: Double = 0.1

    fun clamp(level: Double): Double = level.coerceIn(minLevel, maxLevel)

    fun zoomedIn(level: Double): Double = clamp(level + step)

    fun zoomedOut(level: Double): Double = clamp(level - step)
}

package surf.zz.ui.tile

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.unit.IntSize
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Drop-hover state for a single tile: the currently highlighted [zone] and the
 * pane's last-known [size]. Mirrors `TileView.swift`'s `TileDropState`.
 *
 * The hover highlight is transient. Drag frameworks do not always deliver a
 * clean "exit" event, so every [update] (re)arms a 900ms debounced auto-clear:
 * if no further update arrives within that window the [zone] is reset to `null`
 * on its own. An explicit [clear] (drop performed or drag ended) cancels the
 * pending auto-clear immediately.
 *
 * Ported 1:1 from the Swift `@Observable final class TileDropState`. Where Swift
 * used `CGSize` this stores [IntSize] (per the Android binding conventions); the
 * conversion to the float [Size] expected by [dropZone] happens at the call site.
 *
 * All mutation happens on the main thread (the Swift class is `@MainActor`).
 */
class TileDropState {
    /** The zone the drag currently hovers, or `null` when nothing is highlighted. */
    var zone by mutableStateOf<DropZone?>(null)
        private set

    /** The pane's most recently observed size, used to resolve a location to a zone. */
    var size by mutableStateOf(IntSize.Zero)

    /**
     * Scope for the debounced auto-clear. Not snapshot state — the Swift original
     * marks `clearTask` `@ObservationIgnored`. Main-thread confined to match the
     * `@MainActor` source.
     */
    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())

    /** The pending auto-clear job, cancelled and relaunched on every update. */
    private var clearJob: Job? = null

    /**
     * Records a fresh [size] and resolves [location] to a [zone], then arms the
     * auto-clear. Mirrors `update(location:size:)`.
     */
    fun update(location: Offset, size: IntSize) {
        this.size = size
        zone = dropZone(at = location, size = size.toSize())
        scheduleClear()
    }

    /**
     * Resolves [location] against the last-known [size] and arms the auto-clear.
     * Mirrors the `update(location:)` overload used by drag-update callbacks that
     * do not carry a size.
     */
    fun update(location: Offset) {
        zone = dropZone(at = location, size = size.toSize())
        scheduleClear()
    }

    /**
     * Clears the highlight immediately and cancels any pending auto-clear.
     * Mirrors `clear()`.
     */
    fun clear() {
        clearJob?.cancel()
        clearJob = null
        zone = null
    }

    /**
     * Cancels any in-flight auto-clear and schedules a new one 900ms out, after
     * which [zone] resets to `null`. Mirrors `scheduleClear()` /
     * `Task { sleep(900ms); zone = nil }`.
     */
    private fun scheduleClear() {
        clearJob?.cancel()
        clearJob = scope.launch {
            delay(900)
            zone = null
            clearJob = null
        }
    }
}

private fun IntSize.toSize(): Size = Size(width.toFloat(), height.toFloat())

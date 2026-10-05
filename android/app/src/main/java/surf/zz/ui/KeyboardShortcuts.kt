package surf.zz.ui

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import surf.zz.layout.BspNode
import surf.zz.layout.Direction
import surf.zz.store.BrowserStore

/**
 * Single keyboard-shortcut handler — the Android analog of iOS `ShortcutLayer`
 * (a `ZStack` of invisible `Button`s carrying `.keyboardShortcut(...)`) plus the
 * macOS `NSEvent` local key monitors (`CloseTileKeyLayer`).
 *
 * On iOS/macOS the shortcuts use the **Command** modifier. On Android there is no
 * Command key; per ANDROID_ARCH.md §10 we accept **either Ctrl or Meta** as the
 * "Cmd" stand-in so the same chords work on hardware keyboards regardless of how
 * the platform maps the modifier. Shift / Alt(Option) requirements are matched
 * exactly as on iOS.
 *
 * Attach to the focusable root composable in `BrowserScreen` via
 * `Modifier.onPreviewKeyEvent(keyboardShortcutHandler(store, urlFocused))`.
 * The handler returns `true` to consume an event (so it does not fall through to
 * the focused WebView), `false` otherwise.
 *
 * Intentionally dropped vs. iOS (see arch doc §10):
 *  - **New Window** (Cmd-N): multi-window is deferred in v1 — handled as a no-op
 *    here (consumes the chord so it does nothing rather than leaking a 'n').
 *  - **Close Window** (Cmd-Shift-W): no per-window concept in v1 — no-op consume.
 *  - **Mouse back/forward** (`HistoryMouseButtonLayer`): no equivalent.
 *  - **Cmd-W tile-close interceptor** (`CloseTileKeyLayer`): on Android Cmd-W is a
 *    plain shortcut (no competing main-menu "Close Window" item to beat), so it is
 *    just another entry in this handler.
 *  - **System Back gesture**: routed to `store.backFocused()` via `BackHandler`
 *    in `BrowserScreen`, NOT here.
 *
 * `urlFocused` gates the bindings that iOS also gates behind `!urlFocused`: the
 * bare arrow Back/Forward and the Cmd-Opt directional pane-focus arrows. While the
 * URL bar is being edited these must not fire so arrow keys edit text / move the
 * caret instead of moving pane focus out from under the edit.
 */
fun keyboardShortcutHandler(
    store: BrowserStore,
    urlFocused: Boolean,
): (KeyEvent) -> Boolean = handler@{ event ->
    // Only act on key-down; key-up of a consumed chord is swallowed so the
    // platform does not see a dangling release (mirrors NSEvent .keyDown handling).
    if (event.type != KeyEventType.KeyDown) {
        // Swallow the matching key-up so a chord we consume on the way down does
        // not surface a stray key-up to the WebView.
        return@handler event.type == KeyEventType.KeyUp && wouldConsume(event, store, urlFocused)
    }
    dispatch(event, store, urlFocused)
}

/** "Command" on Android == Ctrl OR Meta (see class doc). */
private val KeyEvent.isCmd: Boolean
    get() = isCtrlPressed || isMetaPressed

/**
 * Pure predicate: would this (modifiers + key) match one of our bindings? Used to
 * decide whether to also swallow the corresponding key-up. Kept in sync with
 * [dispatch] by sharing the same match structure.
 */
private fun wouldConsume(event: KeyEvent, store: BrowserStore, urlFocused: Boolean): Boolean =
    matchedAction(event, store, urlFocused) != null

/**
 * Run the action for a key-down and report whether it was consumed.
 */
private fun dispatch(event: KeyEvent, store: BrowserStore, urlFocused: Boolean): Boolean {
    val action = matchedAction(event, store, urlFocused) ?: return false
    action()
    return true
}

/**
 * Resolve a key event to its action, or `null` if no binding matches.
 *
 * Ordering and modifier requirements mirror iOS `ShortcutLayer` exactly. Note the
 * Cmd-Opt-Ctrl group bindings must be checked BEFORE the plainer Cmd bindings on
 * the same key (`=`, `r`, `f`) so the more-specific chord wins, just as SwiftUI
 * resolves the most specific `.keyboardShortcut` first.
 */
private fun matchedAction(
    event: KeyEvent,
    store: BrowserStore,
    urlFocused: Boolean,
): (() -> Unit)? {
    val cmd = event.isCmd
    val shift = event.isShiftPressed
    val alt = event.isAltPressed
    // On Android both Ctrl and Meta may be physically held to mean "Cmd"; for the
    // "Cmd+Ctrl" style chords iOS uses `.control` as an ADDITIONAL modifier beyond
    // Command. We model the group chords as Cmd+Alt (Option) without trying to also
    // require a separate Ctrl, because Ctrl is already a valid "Cmd" alias here and
    // requiring it again is unrepresentable. This collapses iOS `[.command,
    // .option, .control]` to Cmd+Alt — documented deviation.

    if (!cmd) {
        // Bare-arrow Back/Forward (gated behind !urlFocused on iOS).
        if (!urlFocused && !shift && !alt) {
            when (event.key) {
                Key.DirectionLeft -> return store::backFocused
                Key.DirectionRight -> return store::forwardFocused
                else -> {}
            }
        }
        return null
    }

    val key = event.key

    // ---- Group ops: Cmd + Alt(+Shift/none). Most specific — checked first. ----
    if (alt) {
        // Cmd-Opt directional pane focus (gated behind !urlFocused on iOS).
        if (!shift && !urlFocused) {
            when (key) {
                Key.DirectionUp -> return { store.moveFocus(Direction.UP) }
                Key.DirectionDown -> return { store.moveFocus(Direction.DOWN) }
                Key.DirectionLeft -> return { store.moveFocus(Direction.LEFT) }
                Key.DirectionRight -> return { store.moveFocus(Direction.RIGHT) }
                else -> {}
            }
        }
        // None of the iOS Cmd-Opt(+Ctrl) group ops carry Shift, so a held Shift
        // means no match here — let the chord fall through rather than over-consume.
        if (!shift) {
            when (key) {
                // Park Tile: Cmd-Opt-P.
                Key.P -> return store::parkFocused
                // Group ops (iOS Cmd-Opt-Ctrl-*; Ctrl folded into Cmd alias here).
                Key.Equals -> return store::equalizeSelectedGroup       // Equalize Group
                Key.R -> return store::rotateSelectedGroup              // Rotate Group
                Key.F -> return store::toggleZoom                       // Toggle Zoom
                else -> {}
            }
        }
        // Select Parent Group is iOS Cmd-Opt-Ctrl-P; same chord-family as Park
        // (Cmd-Opt-P) but with Ctrl. Since Ctrl is a Cmd alias, both collapse onto
        // Cmd-Opt-P; Park wins (handled above). Documented deviation: Select Parent
        // Group has no distinct chord on Android and is reachable via the group menu.
        return null
    }

    // ---- Cmd (optionally +Shift), no Alt ----
    when (key) {
        Key.N -> return if (shift) null else ::noop                     // New Window (Cmd-N) — no-op (multi-window deferred)
        Key.W -> return if (shift) {
            ::noop                                                      // Close Window — no-op in v1
        } else {
            { store.focusedTabID?.let(store::close) }                  // Close Tile (iOS CloseTileKeyLayer)
        }
        Key.L -> return if (shift) null else store::focusURLBar         // Focus URL Bar
        Key.R -> return if (shift) store::forceReloadFocused else store::reloadFocused
        Key.F -> return if (shift) null else store::findInFocused       // Find on Page
        Key.LeftBracket -> return if (shift) null else store::backFocused
        Key.RightBracket -> return if (shift) null else store::forwardFocused
        Key.Equals -> return if (shift) null else store::zoomInFocused  // Cmd-= zoom in
        Key.Plus -> return if (shift) null else store::zoomInFocused    // Cmd-+ zoom in
        Key.Minus -> return if (shift) null else store::zoomOutFocused  // Cmd-- zoom out
        Key.Zero -> return if (shift) null else store::resetZoomFocused // Cmd-0 actual size
        Key.Backslash -> return {
            // Cmd-\ split horizontal; Cmd-Shift-\ split vertical.
            store.splitSelection(if (shift) BspNode.Axis.VERTICAL else BspNode.Axis.HORIZONTAL)
        }
        else -> {}
    }
    return null
}

private fun noop() {}

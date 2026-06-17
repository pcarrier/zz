package surf.zz

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.core.view.WindowCompat
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.runtime.CompositionLocalProvider
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import surf.zz.model.WindowID
import surf.zz.store.BrowserStore
import surf.zz.ui.App
import surf.zz.ui.LocalBrowserStore
import surf.zz.ui.LocalFaviconStore
import surf.zz.ui.LocalHistoryStore
import surf.zz.ui.LocalLayoutPresetStore
import surf.zz.ui.theme.ZzTheme
import java.util.UUID

// Activity-scoped DataStore holding the single restored WindowID (see §9: v1 is a
// single Activity / single window; the id is persisted so the same window restores
// across relaunches).
private val android.content.Context.windowDataStore by preferencesDataStore(name = "zz_window")
private val WINDOW_ID_KEY = stringPreferencesKey("window_id")

/**
 * Single Activity hosting the Compose content root.
 *
 * Derived from `zzApp.swift` + `ContentView.swift`. v1 is a single Activity /
 * single window (ANDROID_ARCH.md §9). `android:configChanges` (set in the manifest)
 * prevents recreation on rotation/keyboard/uiMode changes so the in-memory
 * [BrowserStore] and its WebViews survive.
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Edge-to-edge: maps the iOS top-safe-area handling (§13).
        WindowCompat.setDecorFitsSystemWindows(window, false)
        enableEdgeToEdge()

        val app = ZzApplication.from(application)

        // Resolve (or create + persist) the single WindowID before composing.
        val windowId = loadOrCreateWindowId()

        setContent {
            // Per-window store, created once at the composition root and surviving
            // recomposition (mirrors `_store = State(initialValue: BrowserStore(...))`).
            val store = remember {
                BrowserStore(
                    windowId = windowId,
                    history = app.historyStore,
                    favicons = app.faviconStore,
                    context = applicationContext,
                )
            }

            // Forward inbound ACTION_VIEW deep links to the store. `intentState`
            // is bumped from onNewIntent so a re-delivered intent re-fires.
            LaunchedEffect(store, intentState) {
                consumeViewIntent(intent)?.let { store.openExternalURL(it) }
            }

            // Flush all stores when this Activity stops (the per-window store is
            // owned here; the app-global stores are also flushed by
            // ProcessLifecycleOwner in ZzApplication — flushing here is idempotent
            // and covers the case where only this Activity stops).
            val lifecycleOwner = LocalLifecycleOwner.current
            DisposableFlushEffect(lifecycleOwner) {
                store.flushSave()
                app.historyStore.flushSave()
                app.faviconStore.flushSave()
                app.layoutPresetStore.flushSave()
            }

            // Explicit CompositionLocal dependency injection (§3, Locals.kt).
            // The per-window store is provided here; App and its children read it
            // via LocalBrowserStore.current.
            CompositionLocalProvider(
                LocalBrowserStore provides store,
                LocalHistoryStore provides app.historyStore,
                LocalFaviconStore provides app.faviconStore,
                LocalLayoutPresetStore provides app.layoutPresetStore,
            ) {
                ZzTheme {
                    // System Back maps to in-app back navigation (§10).
                    BackHandler(enabled = true) { store.backFocused() }

                    App(
                        windowId = windowId,
                        history = app.historyStore,
                        favicons = app.faviconStore,
                        layouts = app.layoutPresetStore,
                    )
                }
            }
        }
    }

    // Re-delivered while the Activity is alive (launchMode=singleTask): keep the
    // current intent and bump the trigger so the LaunchedEffect re-runs.
    private var intentState by mutableIntStateOf(0)

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intentState++
    }

    private fun loadOrCreateWindowId(): WindowID = runBlocking {
        val store = windowDataStore
        val existing = store.data.first()[WINDOW_ID_KEY]

        val id = existing
            ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
            ?: UUID.randomUUID().also { fresh ->
                store.edit { it[WINDOW_ID_KEY] = fresh.toString() }
            }

        WindowID(id)
    }
}

/** Extracts an http/https deep-link URL from an ACTION_VIEW intent, if present. */
private fun consumeViewIntent(intent: Intent?): String? {
    if (intent?.action != Intent.ACTION_VIEW) return null
    val data = intent.data ?: return null
    return when (data.scheme?.lowercase()) {
        "http", "https" -> data.toString()
        else -> null
    }
}

/**
 * Registers an [androidx.lifecycle.LifecycleObserver] that runs [onStop] when the
 * Activity stops, removing it on dispose. The Android analog of reacting to
 * `scenePhase` leaving `.active` (§6).
 */
@androidx.compose.runtime.Composable
private fun DisposableFlushEffect(owner: LifecycleOwner, onStop: () -> Unit) {
    androidx.compose.runtime.DisposableEffect(owner) {
        val observer = object : DefaultLifecycleObserver {
            override fun onStop(o: LifecycleOwner) = onStop()
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
}

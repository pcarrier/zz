package surf.zz

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import surf.zz.favicon.FaviconStore
import surf.zz.prefs.AppPreferences
import surf.zz.prefs.BrowserPreferences
import surf.zz.search.SearchPreferences
import surf.zz.store.HistoryStore
import surf.zz.store.LayoutPresetStore

/**
 * Process-lifetime singletons.
 *
 * Ports the app-global `@State` stores from `zzApp.swift`
 * (`history`, `favicons`, `layouts`). In SwiftUI these live for the lifetime of
 * the `App`; on Android the [Application] instance is the natural owner.
 *
 * The per-window [surf.zz.store.BrowserStore] is NOT created here — it is created
 * and `remember`ed at the Activity composition root (see [MainActivity]), keyed by
 * the window's [surf.zz.model.WindowID].
 *
 * Each store builds its disk paths from [filesDir]. A [ProcessLifecycleOwner]
 * observer calls `flushSave()` on every app-global store when the whole process
 * goes to the background — the Android analog of SwiftUI's
 * `scenePhase != .active` (see ANDROID_ARCH.md §6).
 */
class ZzApplication : Application() {

    lateinit var historyStore: HistoryStore
        private set
    lateinit var faviconStore: FaviconStore
        private set
    lateinit var layoutPresetStore: LayoutPresetStore
        private set

    override fun onCreate() {
        super.onCreate()

        val root = applicationContext.filesDir

        // Wire the synchronous scalar-preference layer before any omnibox /
        // browser-preference accessor runs. A SharedPreferences instance is a
        // process-wide singleton, so a single AppPreferences is shared by both
        // SearchPreferences and BrowserPreferences.
        val appPreferences = AppPreferences(applicationContext)
        SearchPreferences.init(appPreferences)
        BrowserPreferences.init(appPreferences)

        historyStore = HistoryStore(root)
        faviconStore = FaviconStore(root)
        layoutPresetStore = LayoutPresetStore(root)

        ProcessLifecycleOwner.get().lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                // ON_STOP: the whole app moved to the background. Persist
                // synchronously before the process can be killed.
                override fun onStop(owner: LifecycleOwner) {
                    historyStore.flushSave()
                    faviconStore.flushSave()
                    layoutPresetStore.flushSave()
                }
            },
        )
    }

    companion object {
        /** Convenience accessor for the typed [Application] instance. */
        fun from(application: Application): ZzApplication = application as ZzApplication
    }
}

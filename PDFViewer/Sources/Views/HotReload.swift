#if HOT_RELOAD
    @_exported import Inject
#endif

import SwiftUI

extension View {
    /// Opts the view into hot reloading when the app is built with the
    /// `HOT_RELOAD` compilation condition (Xcode Debug only).
    @ViewBuilder
    func hotReload() -> some View {
        #if HOT_RELOAD
            self.enableInjection()
        #else
            self
        #endif
    }
}

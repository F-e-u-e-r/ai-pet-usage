import Foundation

/// Usage-M3 A1 — Projects **bottom inspector** selection (owner ruling 2026-09-29, Phase 1; replaces the abandoned
/// floating-hover mechanism).
///
/// Stateless, pure transitions over the inspector's single selected project id. The View (`ProjectsView`) owns the
/// one `@State selectedProjectID` and applies every lifecycle clear directly (timeframe change before reload, leaving
/// Projects, Esc); these functions only compute the next value for the two transitions that carry logic, so the
/// keyboard and refresh contracts are unit-testable without SwiftUI.
///
/// Invariant: neither function ever turns `nil` into a non-nil id — a cleared selection is never resurrected.
public enum ProjectInspectorSelection {

    public enum Step: Sendable {
        case previous   // ↑
        case next       // ↓
    }

    /// ↑ / ↓ over the CURRENT ordered project list (a refresh that reorders projects changes what "next" means).
    /// Boundaries stop — no wrap. No selection → `nil` (keys are inert without one). A selected id that is not in
    /// `ordered` → `nil`: fail closed (close the inspector) rather than jump to an arbitrary row.
    public static func step(_ step: Step, from selected: String?, in ordered: [String]) -> String? {
        guard let selected, let i = ordered.firstIndex(of: selected) else { return nil }
        switch step {
        case .previous: return ordered[max(i - 1, 0)]
        case .next:     return ordered[min(i + 1, ordered.count - 1)]
        }
    }

    /// Same-timeframe data refresh: keep the selection only while that project is still in the refreshed list
    /// (the inspector then re-reads the new `projectModels` slice); otherwise clear it.
    public static func retained(_ selected: String?, in ordered: [String]) -> String? {
        guard let selected, ordered.contains(selected) else { return nil }
        return selected
    }
}

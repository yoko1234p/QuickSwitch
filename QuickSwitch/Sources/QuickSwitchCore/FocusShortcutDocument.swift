import Foundation

/// Independent single-action documents using Apple's documented file container and
/// the Set DND action identifier/Enabled key observed in the original's public Apple
/// shared shortcuts. No original workflow, artwork, identifier or signed file is copied.
public enum FocusShortcutDocument {
    public static func make(enabled: Bool) throws -> Data {
        let document: [String: Any] = [
            "WFWorkflowName": enabled ? FocusControlPolicy.ownedOnName : FocusControlPolicy.ownedOffName,
            "WFWorkflowActions": [
                [
                    "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
                    "WFWorkflowActionParameters": ["Enabled": enabled],
                ]
            ],
            "WFWorkflowClientRelease": "6.0",
            "WFWorkflowClientVersion": "3600",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowInputContentItemClasses": [],
            "WFWorkflowOutputContentItemClasses": [],
            "WFWorkflowTypes": [],
            "WFQuickActionSurfaces": [],
        ]
        return try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
    }
}

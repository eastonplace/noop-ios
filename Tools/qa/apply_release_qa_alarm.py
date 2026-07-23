#!/usr/bin/env python3
from release_qa_patch_common import replace_once, regex_once, insert_before_last
import re

# ---------------------------------------------------------------------------
# Smart alarm: one registration owner, exactly-once completion, bad payload cleanup.
# ---------------------------------------------------------------------------
replace_once(
    "StrandiOS/App/SmartAlarmRuntimeController.swift",
    '''    private static let requestKey = "smartAlarm.runtime.backgroundRequest"\n''',
    '''    static let requestKey = "smartAlarm.runtime.backgroundRequest"\n''',
)
regex_once(
    "StrandiOS/App/SmartAlarmRuntimeController.swift",
    r'''    private static weak var runtime: SmartAlarmRuntimeController\?\n    private static var registered = false\n\n    static func install\(_ runtime: SmartAlarmRuntimeController\) \{.*?\n    \}\n\n    static func schedule\(''',
    '''    static func install(_ runtime: SmartAlarmRuntimeController) {\n        _ = SmartAlarmBackgroundTaskRegistrar.install(runtime)\n    }\n\n    static func schedule(''',
    flags=re.DOTALL,
)

registrar_path = "StrandiOS/App/SmartAlarmBackgroundTaskRegistrar.swift"
replace_once(
    registrar_path,
    '''/// Registers the production BGTask launch handler before the legacy scheduler enum attempts registration.\n/// iOS accepts only one handler per identifier in a process, so the legacy registration becomes a harmless\n/// `false` return while its request persistence/scheduling helpers remain the single storage seam.\n''',
    '''/// Owns the one production BGTask launch handler for the smart-alarm identifier. The scheduler enum\n/// delegates registration here and retains only request persistence/submission helpers, so expiration and\n/// every other terminal path share one exactly-once completion gate.\n''',
)
replace_once(
    registrar_path,
    '''    private static let requestKey = "smartAlarm.runtime.backgroundRequest"\n''',
    '''''',
)
replace_once(
    registrar_path,
    '''                case .malformed:\n                    completion.complete(.malformedRequest)\n                    return\n''',
    '''                case .malformed:\n                    clearStoredRequest()\n                    completion.complete(.malformedRequest)\n                    return\n''',
)
replace_once(
    registrar_path,
    '''        guard let data = defaults.data(forKey: requestKey) else { return .missing }\n''',
    '''        guard let data = defaults.data(\n            forKey: SmartAlarmRuntimeBackgroundScheduler.requestKey\n        ) else { return .missing }\n''',
)
replace_once(
    registrar_path,
    '''        return .loaded(request)\n    }\n\n    private static func evaluate(\n''',
    '''        return .loaded(request)\n    }\n\n    static func clearStoredRequest(defaults: UserDefaults = .standard) {\n        defaults.removeObject(forKey: SmartAlarmRuntimeBackgroundScheduler.requestKey)\n    }\n\n    private static func evaluate(\n''',
)

replace_once(
    "StrandiOSTests/SmartAlarmBackgroundTaskRegistrarTests.swift",
    '''        XCTAssertEqual(\n            SmartAlarmBackgroundTaskRegistrar.loadRequest(defaults: defaults),\n            .malformed\n        )\n\n        let snapshot = SmartAlarmRuntimeSnapshot(\n''',
    '''        XCTAssertEqual(\n            SmartAlarmBackgroundTaskRegistrar.loadRequest(defaults: defaults),\n            .malformed\n        )\n        SmartAlarmBackgroundTaskRegistrar.clearStoredRequest(defaults: defaults)\n        XCTAssertEqual(\n            SmartAlarmBackgroundTaskRegistrar.loadRequest(defaults: defaults),\n            .missing\n        )\n\n        let snapshot = SmartAlarmRuntimeSnapshot(\n''',
)

replace_once(
    "Tools/qa/ui_unification_contract_audit.py",
    '''        "SmartAlarmRuntimeBackgroundScheduler.clearRequest(ifMatching: request)",\n    )\n''',
    '''        "SmartAlarmRuntimeBackgroundScheduler.clearRequest(ifMatching: request)",\n        "clearStoredRequest()",\n        "SmartAlarmRuntimeBackgroundScheduler.requestKey",\n    )\n''',
)
replace_once(
    "Tools/qa/ui_unification_contract_audit.py",
    '''        "clearRequest(ifMatching: request)",\n        "removePendingNotificationRequests",\n    )\n''',
    '''        "clearRequest(ifMatching: request)",\n        "removePendingNotificationRequests",\n        "SmartAlarmBackgroundTaskRegistrar.install(runtime)",\n    )\n''',
)

print("Applied alarm QA fixes")

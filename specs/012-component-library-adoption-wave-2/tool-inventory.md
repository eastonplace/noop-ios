# Wave 2 Settings Tool Inventory

Formal pre/post parity ledger for Lane 2. Dynamic rows represent every runtime instance. Standard shapes use the promoted binding API; compound tools use `custom` with their original view, store, disabled state, confirmation, availability gate, and effect intact.

## Settings root and nested sheets

| Row / control | Type to kit | Store / binding | Destination / effect | Post |
|---|---|---|---|---|
| Real profile header | profile | local name, oldest repo day, `repo.today?.recovery` | expands detailed settings | Kept |
| Units; appearance summaries | segmented | unit/appearance prefs | display | Kept |
| Data Management; Export; Support | nav | none | DataSources, BackupSync, Support | Kept |
| Detailed-settings disclosure | custom | advanced-open pref | reveals all tools | Kept |
| Choose/change/remove photo | custom picker/buttons | `ProfileStore` | local avatar | Kept |
| Birth date; sex | custom date/segmented | profile fields | profile inputs | Kept |
| Weight; height; waist; max HR | custom steppers | SI profile fields + imperial adapters | profile inputs | Kept |
| Step counter calibration | custom stepper | `stepTicksPerStep` | 5/MG divisor | Kept |
| Steps estimate calibration | custom button | calibration fields | `StepsCalibrationSheet` | Kept |
| Measurement; temperature | custom segmented | unit prefs | display | Kept |
| Theme; chart colours; app icon | custom segmented | appearance prefs | presentation | Kept |
| Day-cycle background | custom toggle | scene pref | Today scene | Kept |
| Re-scan; disconnect strap | custom buttons | AppModel BLE actions | BLE | Kept |
| Copy; save strap log | custom buttons | live log | clipboard/file | Kept |
| Continuous HRV; overnight-only; Live Activity | custom toggles | Puffin/unit prefs | capture/UI policy | Kept |
| Strap name and Rename | custom field/button | draft + BLE manager | WHOOP 4 rename | Kept |
| Power saving; threshold; pause HRV | custom toggle/slider | Puffin power prefs | collection policy | Kept |
| Recalibrate Recovery | custom + confirm | Baselines + recompute | baseline reset | Kept |
| Test Centre | custom nav | none | `TestCentreView` | Kept |
| Hydration; workout detection; workout screen-on | custom toggles | feature prefs | feature gates | Kept |
| Live Sessions; Sleep staging V2 | custom toggles | experiment prefs | engine/UI gates | Kept |
| 5/MG probes; R22; send sequence | custom toggles/button | Puffin prefs/BLE | strap commands | Kept |
| HR broadcast; raw capture | custom toggles | broadcast/capture prefs | BLE/recorder | Kept |
| Export/reveal frames; raw+log; raw CSV | custom buttons | existing export helpers | file/Finder | Kept |
| Scheduled debug enable/time/run | custom toggle/date/button | ScheduledDebugExport | export | Kept |
| Export/import backup; export CSV | custom buttons | DataBackup/CsvExport | file/restore | Kept |
| Backup folder screen | custom nav | none | BackupSync | Kept |
| What's new; NOOP/scoring explainers | custom buttons | sheet state | sheets | Kept |
| Apple Watch about/setup | custom nav/button | setup state | watch screens | Kept |
| Storage; diagnostics | custom nav/buttons | diagnostics state | storage/sheet | Kept |
| Update check/download; project/mirror links | custom buttons/links | UpdateChecker/openURL | web | Kept |
| Diagnostics close/copy | custom buttons | onClose/captured lines | dismiss/clipboard | Kept |
| Steps calibration close/Done/manual slider | custom buttons/slider | onClose/manual coefficient | profile/dismiss | Kept |

## Settings sub-screens

| Screen: control | Type to kit | Store / binding | Effect | Post |
|---|---|---|---|---|
| Notifications: master/test | custom toggle/button | NotificationSettingsStore/AppModel | gate/haptic | Kept |
| Notifications: per-app enable/pattern/test (dynamic) | custom toggle/menu/button | app-id store fields | alert behavior | Kept |
| Notifications: worn-only; quiet-hours; start/end | custom toggles/date pickers | notification store | delivery filters | Kept |
| Data Sources: WHOOP/Apple Health/Xiaomi | custom import actions | AppModel targets | picker/import | Kept |
| Data Sources: nutrition/lifting/activity/wearable/retry | custom import actions | repo/import state | picker/import | Kept |
| Data Sources: remove Apple Health | custom destructive + confirm | source registry | source-only delete | Kept; gate slot |
| Data Sources: broadcast HR | custom toggle | broadcast pref | BLE peripheral | Kept |
| Backup: folder; auto; run now | custom button/toggle | FolderBackup | picker/snapshot | Kept |
| Backup: restore picker/snapshot/cancel (dynamic) | custom buttons | snapshot state | selection | Kept |
| Backup: replace data; retry failure | custom destructive/button | restore/retry paths | restore | Kept; gate slot |
| Storage: clean up now | custom button | AppModel storage cleanup | scratch/WAL cleanup | Kept |
| Support: help/issue/feature; modal close | link/custom | contact email/isPresented | mail/dismiss | Kept |
| Automations: wrist master | custom toggle | notif master pref | haptic gate | Kept |
| Automations: double-tap action/shortcut/test/moment clear | custom picker/field/buttons | BehaviorStore/AppModel | Shortcuts/Mac | Kept |
| Automations: wear lock; zone coaching | custom toggles | BehaviorStore | Mac/haptic | Kept |
| Automations: stress check-in/auto/quiet/resonance | custom toggles | BehaviorStore | nudges | Kept |
| Automations: inactivity enable/timing/worn/hours | custom toggles/steppers/dates | InactivityPrefs | detector | Kept |
| Automations: illness; cycle; Rhythm; battery | custom toggles/button | existing prefs/router | notifiers/screen | Kept |

## Post-adoption diff

| Check | Before | After | Losses |
|---|---:|---:|---:|
| Static control templates above | 89 | 89 | **0** |
| Per-app notification controls | 4 per app | unchanged | **0** |
| Per-snapshot restore controls | 1 per snapshot | unchanged | **0** |
| Platform-conditional tools | existing gates | unchanged | **0** |
| Destructive effects | existing effects | same effects; Lane 1 gate slots isolated | **0** |

Read-only facts remain visible inside their owning custom rows and are not mislabeled as interactive tools.

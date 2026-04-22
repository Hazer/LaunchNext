import ProjectDescription

let project = Project(
    name: "LaunchNext",
    settings: .settings(
        base: [
            "MACOSX_DEPLOYMENT_TARGET": "26.0",
            "SDKROOT": "macosx",
            "DEVELOPMENT_TEAM": "6V3LHNB5K8",
            "SWIFT_VERSION": "5.0",
            "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
            "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
            "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES",
            "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
            "GCC_C_LANGUAGE_STANDARD": "gnu17",
            "COMBINE_HIDPI_IMAGES": "YES",
            "DEAD_CODE_STRIPPING": "YES",
            "GENERATE_INFOPLIST_FILE": "YES",
            "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
            "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
            "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
            "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        ],
        configurations: [
            .debug(name: "Debug", settings: [
                "ENABLE_TESTABILITY": "YES",
                "DEBUG_INFORMATION_FORMAT": "dwarf",
                "ONLY_ACTIVE_ARCH": "YES",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            ]),
            .release(name: "Release", settings: [
                "ENABLE_NS_ASSERTIONS": "NO",
                "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                "SWIFT_COMPILATION_MODE": "wholemodule",
            ]),
        ]
    ),
    targets: [
        .target(
            name: "LaunchNext",
            destinations: .macOS,
            product: .app,
            bundleId: "io.roversx.launchnext",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "LaunchNext",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "LSUIElement": true,
                "NSHumanReadableCopyright": "© 2026 RoversX / CloseX. Licensed under GPL-3.0",
                "CFBundleAllowMixedLocalizations": true,
            ]),
            sources: ["LaunchNext/**/*.swift"],
            resources: ["cs.lproj/**", "de.lproj/**", "en.lproj/**", "es.lproj/**", "fr.lproj/**", "hi.lproj/**", "it.lproj/**", "ja.lproj/**", "ko.lproj/**", "pt-BR.lproj/**", "ru.lproj/**", "vi.lproj/**", "zh-Hans.lproj/**", "LaunchNext/Assets.xcassets"],
            scripts: [
                .pre(
                    script: """
                        set -euo pipefail
                        if [[ "${ENABLE_PREVIEWS:-NO}" == "YES" ]]; then
                            echo 'SwiftUI Preview: skip updater build'
                            exit 0
                        fi
                        UPDATER_DIR="$SRCROOT/UpdaterScripts/SwiftUpdater"
                        DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Updater"
                        SOURCE_BIN="${UPDATER_DIR}/.build/apple/Products/Release/SwiftUpdater"
                        LEGACY_BIN="${UPDATER_DIR}/.build/release/SwiftUpdater"
                        mkdir -p "${DEST_DIR}"
                        if [[ -f "${SOURCE_BIN}" ]]; then
                            cp "${SOURCE_BIN}" "${DEST_DIR}/SwiftUpdater"
                        elif [[ -f "${LEGACY_BIN}" ]]; then
                            cp "${LEGACY_BIN}" "${DEST_DIR}/SwiftUpdater"
                        else
                            echo "warning: SwiftUpdater binary not found."
                            exit 0
                        fi
                        chmod +x "${DEST_DIR}/SwiftUpdater"
                        /usr/bin/codesign --force --sign - --preserve-metadata=entitlements,requirements "${DEST_DIR}/SwiftUpdater"
                        """,
                    name: "Build SwiftUpdater",
                    basedOnDependencyAnalysis: false
                ),
            ],
            settings: .settings(base: [
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "PRODUCT_BUNDLE_IDENTIFIER": "io.roversx.launchnext",
                "CODE_SIGN_STYLE": "Automatic",
                "ENABLE_APP_SANDBOX": "NO",
                "ENABLE_HARDENED_RUNTIME": "YES",
                "ENABLE_PREVIEWS": "YES",
                "MARKETING_VERSION": "2.4.0",
                "CURRENT_PROJECT_VERSION": "20260224",
                "REGISTER_APP_GROUPS": "YES",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                "CLANG_ENABLE_MODULES": "YES",
                "SWIFT_EMIT_LOC_STRINGS": "YES",
            ])
        ),
    ]
)

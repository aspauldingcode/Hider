/*
 * Hider Private API Header
 * aspauldingcode and efforts from 2025-2026
 * For ability to hide Finder and Trash from Dock... FINALLY.
 */

#ifndef TWEAK_H
#define TWEAK_H

#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>

#ifdef __cplusplus
extern "C" {
#endif

// CoreDock Enumerations
typedef enum {
  kCoreDockOrientationIgnore = 0,
  kCoreDockOrientationTop = 1,
  kCoreDockOrientationBottom = 2,
  kCoreDockOrientationLeft = 3,
  kCoreDockOrientationRight = 4
} CoreDockOrientation;

typedef enum {
  kCoreDockPinningIgnore = 0,
  kCoreDockPinningStart = 1,
  kCoreDockPinningMiddle = 2,
  kCoreDockPinningEnd = 3
} CoreDockPinning;

typedef enum {
  kCoreDockEffectGenie = 1,
  kCoreDockEffectScale = 2,
  kCoreDockEffectSuck = 3
} CoreDockEffect;

// Core Dock Functions - Tile Size and Layout
extern float CoreDockGetTileSize(void);
extern void CoreDockSetTileSize(float tileSize);

// Dock Orientation and Pinning
extern void
CoreDockGetOrientationAndPinning(CoreDockOrientation *outOrientation,
                                 CoreDockPinning *outPinning);
extern void CoreDockSetOrientationAndPinning(CoreDockOrientation orientation,
                                             CoreDockPinning pinning);

// Dock Effects
extern void CoreDockGetEffect(CoreDockEffect *outEffect);
extern void CoreDockSetEffect(CoreDockEffect effect);

// Auto Hide
extern Boolean CoreDockGetAutoHideEnabled(void);
extern void CoreDockSetAutoHideEnabled(Boolean flag);

// Magnification
extern Boolean CoreDockIsMagnificationEnabled(void);
extern void CoreDockSetMagnificationEnabled(Boolean flag);
extern float CoreDockGetMagnificationSize(void);
extern void CoreDockSetMagnificationSize(float newSize);

// Launch Animations
extern Boolean CoreDockIsLaunchAnimationsEnabled(void);
extern void CoreDockSetLaunchAnimationsEnabled(Boolean flag);

// Workspaces/Spaces
extern Boolean CoreDockGetWorkspacesEnabled(void);
extern void CoreDockSetWorkspacesEnabled(Boolean flag);
extern int CoreDockGetWorkspacesCount(void);
extern void CoreDockSetWorkspacesCount(int count);

// Minimize in Place
extern void CoreDockSetMinimizeInPlace(Boolean enable);

// Preferences Dictionary
extern CFDictionaryRef CoreDockCopyPreferences(void);
extern void CoreDockSetPreferences(CFDictionaryRef preferenceDict);

// Trash State
extern void CoreDockSetTrashFull(Boolean full);

// Dock Status and Geometry
extern Boolean CoreDockIsDockRunning(void);
extern CGRect CoreDockGetRect(void);
extern CGRect CoreDockGetContainerRect(void);

// Custom Hider Functions for Tile Management
typedef void (*CoreDockSendNotificationFunc)(CFStringRef notification,
                                             void *unknown);
typedef CFArrayRef (*CoreDockCopyApplicationsFunc)(void);
typedef void (*CoreDockSetTileHiddenFunc)(CFStringRef bundleID, Boolean hidden);
typedef Boolean (*CoreDockIsTileHiddenFunc)(CFStringRef bundleID);
typedef void (*CoreDockRefreshTileFunc)(CFStringRef bundleID);

// Function pointers for dynamic loading
extern CoreDockSendNotificationFunc CoreDockSendNotification;
extern CoreDockCopyApplicationsFunc CoreDockCopyApplications;
extern CoreDockSetTileHiddenFunc CoreDockSetTileHidden;
extern CoreDockIsTileHiddenFunc CoreDockIsTileHidden;
extern CoreDockRefreshTileFunc CoreDockRefreshTile;

// Dock Tile Information
typedef struct {
  CFStringRef bundleID;
  CFStringRef displayName;
  CFStringRef path;
  Boolean isRunning;
  Boolean isHidden;
  int position;
} CoreDockTileInfo;

extern CFArrayRef CoreDockCopyTileInfo(void);
extern CoreDockTileInfo *CoreDockGetTileInfoForBundle(CFStringRef bundleID);

// Dock Notifications
#define kCoreDockNotificationTileAdded CFSTR("com.apple.dock.tile.added")
#define kCoreDockNotificationTileRemoved CFSTR("com.apple.dock.tile.removed")
#define kCoreDockNotificationTileChanged CFSTR("com.apple.dock.tile.changed")
#define kCoreDockNotificationDockChanged CFSTR("com.apple.dock.changed")
#define kCoreDockNotificationPreferencesChanged CFSTR("com.apple.dock.prefschanged")

// Special Bundle IDs
#define kCoreDockFinderBundleID CFSTR("com.apple.finder")
#define kCoreDockTrashBundleID CFSTR("com.apple.trash")

// Dock Preferences Keys
#define kCoreDockPrefShowHidden CFSTR("showhidden")
#define kCoreDockPrefMagnification CFSTR("magnification")
#define kCoreDockPrefTileSize CFSTR("tilesize")
#define kCoreDockPrefOrientation CFSTR("orientation")
#define kCoreDockPrefAutohide CFSTR("autohide")
#define kCoreDockPrefMinimizeInPlace CFSTR("minimize-to-application")
#define kCoreDockPrefLaunchAnim CFSTR("launchanim")
#define kCoreDockPrefShowIndicators CFSTR("show-process-indicators")

// Hider Initialization and Helper Functions

#ifdef __cplusplus
}
#endif

#endif /* TWEAK_H */

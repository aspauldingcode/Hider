/*
 * Hider.m
 * aspauldingcode
 * implementation of Hider Dock tweak.
 * Uses native Objective-C runtime for swizzling to minimize dependencies.
 */

#import "tweak.h"
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - Utils Prototypes

// Logging
void Hider_LogToFile(const char *func, int line, NSString *format, ...);

// Suppress GNU extension warning for token pasting
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu-zero-variadic-macro-arguments"
#define LOG_TO_FILE(fmt, ...)                                                  \
  do {                                                                         \
    NSString *_fmt = [NSString stringWithUTF8String:fmt];                      \
    Hider_LogToFile(__FUNCTION__, __LINE__, _fmt, ##__VA_ARGS__);              \
  } while (0)
#pragma clang diagnostic pop

// Global state
static BOOL g_finderHidden = NO;
static BOOL g_trashHidden = NO;
static BOOL g_hideSeparators = NO;
static int g_separatorMode = 2; // Default to Auto
// Set when separators transition from hidden→visible until the Dock restarts.
// Keeps separators suppressed in the current session without touching prefs.
static BOOL g_deferSeparatorRestore = NO;
static BOOL g_coreDockLoaded = NO;
static void *g_coreDockHandle = NULL;

// Tracked floor layers for targeted refresh
static CALayer *g_modernFloorLayer = nil;
static CALayer *g_legacyFloorLayer = nil;

// Tracked tile objects (unsafe_unretained — tiles live for the lifetime of the
// Dock process so no dangling-pointer risk). Used for doCommand:/performCommand:.
static __unsafe_unretained id g_finderTileObject = nil;
static __unsafe_unretained id g_trashTileObject  = nil;

// Tracked separator/spacer tile objects. NSMutableArray retains them; the Dock
// process owns them for its lifetime so there is no lifetime hazard.
static NSMutableArray *g_separatorTileObjects = nil;

// Previous state for transition detection.
static BOOL g_prevFinderHidden    = NO;
static BOOL g_prevTrashHidden     = NO;
static BOOL g_prevSeparatorsRemoved = NO;

// Helper functions
NSString *Hider_GetBundleID(id obj);
BOOL Hider_IsFinder(NSString *bundleID);
BOOL Hider_IsTrash(NSString *bundleID);
BOOL Hider_IsSeparatorTileLayer(id obj);

// Execution guard
void Hider_RunOnce(id object, const void *key, void (^block)(void));

// Layout helpers
static void Hider_ApplyEdgeTileVisibility(CALayer *parent);
void Hider_ForceLayoutRecursive(CALayer *layer);

// Layer Dumper
void Hider_DumpLayer(CALayer *layer, int depth, NSMutableString *output);
void Hider_DumpDockHierarchy(void);

#pragma mark - Utils Implementation

void Hider_LogToFile(const char *func, int line, NSString *format, ...) {
  FILE *logFile = fopen("/tmp/hider.log", "a");
  if (logFile) {
    va_list args;
    va_start(args, format);
    NSString *logMsg = [[NSString alloc] initWithFormat:format arguments:args];
    NSString *fullMsg =
        [NSString stringWithFormat:@"[%s:%d] %@", func, line, logMsg];
    fprintf(logFile, "%s\n", [fullMsg UTF8String]);
    fflush(logFile);
    fclose(logFile);
    va_end(args);
  }
}

BOOL Hider_IsFinder(NSString *bundleID) {
  return bundleID && [bundleID isEqualToString:@"com.apple.finder"];
}

BOOL Hider_IsTrash(NSString *bundleID) {
  return bundleID && [bundleID isEqualToString:@"com.apple.trash"];
}

NSString *Hider_GetBundleID(id obj) {
  if (!obj)
    return nil;

  // Guard against recursion during description/logging
  static __thread BOOL in_get_bundle_id = NO;
  if (in_get_bundle_id)
    return nil;
  in_get_bundle_id = YES;

  NSString *bundleID = nil;
  id currentObj = obj;
  int depth = 0;

  while (currentObj && depth < 10) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

    // Probe a candidate object for every known bundle-ID selector name.
    // The Dock uses several private class hierarchies (DOCKFileTile,
    // DOCKItem, DOCKApplication, …) none of which guarantee a public
    // -bundleIdentifier; try them all.
    id candidates[8] = {nil, nil, nil, nil, nil, nil, nil, nil};
    int nCandidates = 0;
    candidates[nCandidates++] = currentObj;

    if ([currentObj respondsToSelector:@selector(delegate)]) {
      id d = [currentObj performSelector:@selector(delegate)];
      if (d) candidates[nCandidates++] = d;
    }
    if ([currentObj respondsToSelector:@selector(representedObject)]) {
      id r = [currentObj performSelector:@selector(representedObject)];
      if (r) candidates[nCandidates++] = r;
    }
    SEL tileSel = NSSelectorFromString(@"tile");
    if ([currentObj respondsToSelector:tileSel]) {
      id t = [currentObj performSelector:tileSel];
      if (t) candidates[nCandidates++] = t;
    }
    SEL dockTileSel = NSSelectorFromString(@"dockTile");
    if ([currentObj respondsToSelector:dockTileSel]) {
      id t = [currentObj performSelector:dockTileSel];
      if (t) candidates[nCandidates++] = t;
    }
    SEL itemSel = NSSelectorFromString(@"item");
    if ([currentObj respondsToSelector:itemSel]) {
      id it = [currentObj performSelector:itemSel];
      if (it) candidates[nCandidates++] = it;
    }
    SEL ownerSel = NSSelectorFromString(@"owner");
    if ([currentObj respondsToSelector:ownerSel]) {
      id o = [currentObj performSelector:ownerSel];
      if (o) candidates[nCandidates++] = o;
    }
    SEL modelSel = NSSelectorFromString(@"model");
    if ([currentObj respondsToSelector:modelSel]) {
      id m = [currentObj performSelector:modelSel];
      if (m) candidates[nCandidates++] = m;
    }

    for (int ci = 0; ci < nCandidates; ci++) {
      id c = candidates[ci];
      // Standard selector
      if ([c respondsToSelector:@selector(bundleIdentifier)]) {
        bundleID = [c performSelector:@selector(bundleIdentifier)];
        if (bundleID) goto found;
      }
      // Dock private: -bundleID
      SEL bundleIDSel = NSSelectorFromString(@"bundleID");
      if ([c respondsToSelector:bundleIDSel]) {
        id bid = [c performSelector:bundleIDSel];
        if ([bid isKindOfClass:[NSString class]]) {
          bundleID = (NSString *)bid;
          if (bundleID) goto found;
        }
      }
      // Dock private: -bundle → NSBundle → bundleIdentifier
      if ([c respondsToSelector:@selector(bundle)]) {
        id bundle = [c performSelector:@selector(bundle)];
        if (bundle && [bundle respondsToSelector:@selector(bundleIdentifier)]) {
          bundleID = [bundle performSelector:@selector(bundleIdentifier)];
          if (bundleID) goto found;
        }
      }
      // Dock private: -item → intermediate → bundleIdentifier / bundleID
      if ([c respondsToSelector:itemSel]) {
        id item = [c performSelector:itemSel];
        if (item) {
          if ([item respondsToSelector:@selector(bundleIdentifier)]) {
            bundleID = [item performSelector:@selector(bundleIdentifier)];
            if (bundleID) goto found;
          }
          if ([item respondsToSelector:bundleIDSel]) {
            id bid = [item performSelector:bundleIDSel];
            if ([bid isKindOfClass:[NSString class]]) {
              bundleID = (NSString *)bid;
              if (bundleID) goto found;
            }
          }
        }
      }
      // one more hop: many Dock classes hide it under model/objectValue
      SEL objectValueSel = NSSelectorFromString(@"objectValue");
      id nested = nil;
      if ([c respondsToSelector:modelSel])
        nested = [c performSelector:modelSel];
      else if ([c respondsToSelector:objectValueSel])
        nested = [c performSelector:objectValueSel];
      if (nested) {
        if ([nested respondsToSelector:@selector(bundleIdentifier)]) {
          bundleID = [nested performSelector:@selector(bundleIdentifier)];
          if (bundleID) goto found;
        }
        if ([nested respondsToSelector:bundleIDSel]) {
          id bid = [nested performSelector:bundleIDSel];
          if ([bid isKindOfClass:[NSString class]]) {
            bundleID = (NSString *)bid;
            if (bundleID) goto found;
          }
        }
      }
      // DOCKTrashTile: always the Trash; identify by class name.
      NSString *cn = NSStringFromClass([c class]);
      if ([cn isEqualToString:@"DOCKTrashTile"]) {
        bundleID = @"com.apple.trash";
        goto found;
      }
      // Finder often appears as desktop/file tile owner classes.
      if ([cn isEqualToString:@"DOCKDesktopTile"]) {
        bundleID = @"com.apple.finder";
        goto found;
      }
      if ([cn isEqualToString:@"DOCKFileTile"] &&
          [NSStringFromClass([currentObj class]) isEqualToString:@"DOCKTileLayer"]) {
        // DOCKTileLayer owned by DOCKFileTile can be Finder when no bundle
        // selector is exposed; allow description fallback below to disambiguate.
        NSString *d = [c description];
        if ([d containsString:@"finder"] || [d containsString:@"Finder"] ||
            [d containsString:@"Desktop"]) {
          bundleID = @"com.apple.finder";
          goto found;
        }
      }
      // Description scan for known bundle-ID substrings.
      NSString *desc = [c description];
      if (desc) {
        if ([desc containsString:@"com.apple.finder"] ||
            [desc containsString:@"com.apple.Finder"]) {
          bundleID = @"com.apple.finder";
          goto found;
        }
        if ([desc containsString:@"com.apple.trash"] ||
            [desc containsString:@"Trash"]) {
          bundleID = @"com.apple.trash";
          goto found;
        }
      }
    }

#pragma clang diagnostic pop

    // Traverse up the layer / view hierarchy.
    if ([currentObj isKindOfClass:[CALayer class]]) {
      currentObj = [(CALayer *)currentObj superlayer];
    } else if ([currentObj isKindOfClass:[NSView class]]) {
      currentObj = [(NSView *)currentObj superview];
    } else {
      currentObj = nil;
    }
    depth++;
  }

found:
  in_get_bundle_id = NO;
  return bundleID;
}

BOOL Hider_IsSeparatorTileLayer(id obj) {
  if (!obj)
    return NO;
  id current = obj;
  for (int i = 0; i < 10 && current; i++) {
    NSString *name = NSStringFromClass([current class]);
    if ([name isEqualToString:@"DOCKSeparatorTile"] ||
        [name isEqualToString:@"DOCKSpacerTile"]) {
      return YES;
    }
    if ([current respondsToSelector:@selector(delegate)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      id d = [current performSelector:@selector(delegate)];
#pragma clang diagnostic pop
      if (d &&
          ([NSStringFromClass([d class])
               isEqualToString:@"DOCKSeparatorTile"] ||
           [NSStringFromClass([d class]) isEqualToString:@"DOCKSpacerTile"]))
        return YES;
    }
    if ([current isKindOfClass:[CALayer class]])
      current = [(CALayer *)current superlayer];
    else if ([current isKindOfClass:[NSView class]])
      current = [(NSView *)current superview];
    else
      break;
  }
  return NO;
}

void Hider_RunOnce(id object, const void *key, void (^block)(void)) {
  if (!object || !key || !block)
    return;

  if (!objc_getAssociatedObject(object, key)) {
    objc_setAssociatedObject(object, key, @(YES),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    block();
  }
}

#pragma mark - Floor Layer Hiding

static void Hider_HideFloorSeparators(CALayer *layer) {
  if (!layer)
    return;

  // separatorMode: 0=keep, 1=remove, 2=auto
  if (g_separatorMode == 0 && !g_hideSeparators && !g_deferSeparatorRestore) {
    return;
  }

  BOOL hideAll = g_hideSeparators || (g_separatorMode == 1) || g_deferSeparatorRestore;

  for (CALayer *sub in layer.sublayers) {
    NSString *subClass = NSStringFromClass([sub class]);
    if ([subClass containsString:@"Indicator"])
      continue;
    if (sub.frame.size.width > 0 && sub.frame.size.width < 15) {
      BOOL shouldHide = hideAll;

      if (g_separatorMode == 2) {
        if (g_trashHidden || g_deferSeparatorRestore) {
          shouldHide = YES;
        }
      }

      if (shouldHide) {
        if (!sub.hidden) {
          LOG_TO_FILE("Hiding separator by width (%f): %@",
                      sub.frame.size.width, NSStringFromClass([sub class]));
          [sub setHidden:YES];
          [sub setOpacity:0.0f];
        }
      } else {
        if (sub.hidden) {
          [sub setHidden:NO];
          [sub setOpacity:1.0f];
        }
      }
    }
  }
}

// Directly apply the current g_* visibility state to every DOCKTileLayer and
// floor separator in the subtree.  Called inside a CATransaction so changes
// are applied immediately without animation.
static void Hider_ApplyVisibilityRecursive(CALayer *layer) {
  if (!layer)
    return;

  NSString *cn = NSStringFromClass([layer class]);

  if ([cn isEqualToString:@"DOCKTileLayer"]) {
    NSString *bundleID = Hider_GetBundleID(layer);
    BOOL shouldHide = (g_hideSeparators && Hider_IsSeparatorTileLayer(layer));
    if (bundleID) {
      if (Hider_IsFinder(bundleID) && g_finderHidden) shouldHide = YES;
      else if (Hider_IsTrash(bundleID) && g_trashHidden) shouldHide = YES;
    }
    if (shouldHide) {
      layer.hidden  = YES;
      layer.opacity = 0.0f;
    }
    // DOCKTileLayer has no sublayers worth recursing into.
    return;
  }

  if ([cn containsString:@"FloorLayer"])
    Hider_HideFloorSeparators(layer);

  for (CALayer *sub in layer.sublayers)
    Hider_ApplyVisibilityRecursive(sub);
}

void Hider_ForceLayoutRecursive(CALayer *layer) {
  if (!layer)
    return;
  // Only invalidate layout — never setNeedsDisplay.  DOCKTileLayer renders
  // its content through the compositor pipeline (layer.contents), not via
  // drawInContext:.  Calling setNeedsDisplay triggers drawInContext: which
  // produces a blank frame and makes every tile invisible.
  [layer setNeedsLayout];
  for (CALayer *sub in layer.sublayers)
    Hider_ForceLayoutRecursive(sub);
}

// Walk the NSView subview tree and invalidate layout on every layer-backed
// view.  This is the correct path for SwiftUI-hosted Dock content: SwiftUI
// views live inside NSHostingView (an NSView subclass), so calling
// setNeedsLayout: on the NSView triggers SwiftUI's reconciliation pass, which
// in turn calls layoutSublayers on the backing CALayers — hitting our hook.
static void Hider_WalkNSViewsForLayout(NSView *view) {
  if (!view)
    return;
  CALayer *layer = view.layer;
  if (layer) {
    Hider_ApplyVisibilityRecursive(layer);
    [layer setNeedsLayout];
    // Never setNeedsDisplay — that triggers drawInContext: which blanks tiles.
  }
  [view setNeedsLayout:YES];
  for (NSView *sub in view.subviews)
    Hider_WalkNSViewsForLayout(sub);
}

// Use the tracked floor layer as an anchor to locate the tile container layer
// directly (avoids having to traverse from the window root).  The floor layers
// are siblings of — or one level above — the DOCKTileLayer instances, so we
// walk up the superlayer chain until we find a parent that has DOCKTileLayer
// children, then apply visibility and force layout on that subtree.
// Trigger a floor-separator pass on tracked floor layers.
// Finder/Trash removal is handled via CoreDock APIs and tile swizzles.
// Positional fallback for Finder/Trash hiding: on modern macOS, Dock's private
// ownership chains are opaque so Hider_GetBundleID returns nil for every
// Edge-tile fallback is intentionally disabled.
// On newer Dock builds this heuristic can target non-trash/non-finder tiles
// (indicators or regular app icons). Keep this symbol for easy rollback but
// do not mutate any edge tiles from here.
static void Hider_ApplyEdgeTileVisibility(CALayer *parent) {
  (void)parent;
}

static void Hider_TriggerLayoutOnTrackedLayers(void) {
  CALayer *anchor = g_modernFloorLayer ? g_modernFloorLayer : g_legacyFloorLayer;
  if (!anchor)
    return;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  Hider_HideFloorSeparators(anchor);
  if (anchor.superlayer)
    Hider_HideFloorSeparators(anchor.superlayer);
  [CATransaction commit];

  // Apply positional Finder/Trash hiding.  The floor layer's immediate parent
  // is the tile container — do NOT walk to grandparent as that can reach
  // sub-containers and misidentify regular app tiles as Finder/Trash.
  if (g_finderHidden || g_trashHidden)
    Hider_ApplyEdgeTileVisibility(anchor.superlayer);
}

void Hider_DumpLayer(CALayer *layer, int depth, NSMutableString *output) {
  if (!layer)
    return;

  NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                                       withString:@" "
                                  startingAtIndex:0];
  NSString *className = NSStringFromClass([layer class]);
  NSString *frameStr = NSStringFromRect(NSRectFromCGRect(layer.frame));
  NSString *bundleID = Hider_GetBundleID(layer);

  [output appendFormat:@"%@<%@: %p; frame = %@; bundleID = %@>\n", indent,
                       className, (void *)layer, frameStr,
                       bundleID ? bundleID : @"none"];

  for (CALayer *sublayer in layer.sublayers) {
    Hider_DumpLayer(sublayer, depth + 1, output);
  }
}

void Hider_DumpDockHierarchy(void) {
  LOG_TO_FILE("Dumping Dock Layer Hierarchy...");
  NSMutableString *output = [NSMutableString string];
  [output appendString:@"Dock CALayer Hierarchy Dump\n"];
  [output appendFormat:@"Timestamp: %@\n", [NSDate date]];
  [output appendString:@"========================================\n\n"];

  NSArray *windows = [NSApp windows];
  LOG_TO_FILE("Found %lu windows", (unsigned long)windows.count);

  for (NSWindow *window in windows) {
    NSString *className = NSStringFromClass([window class]);
    [output appendFormat:@"Window: %@ (%p) [%@]\n", window.title,
                         (void *)window, className];
    [output appendString:@"----------------------------------------\n"];

    CALayer *rootLayer = window.contentView.layer;
    if (rootLayer) {
      [output appendString:@"Root: contentView.layer\n"];
      Hider_DumpLayer(rootLayer, 0, output);
    } else {
      SEL rlSel = NSSelectorFromString(@"_rootLayer");
      if ([window respondsToSelector:rlSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        CALayer *rl = [window performSelector:rlSel];
#pragma clang diagnostic pop
        if (rl) {
          [output appendString:@"Root: _rootLayer\n"];
          Hider_DumpLayer(rl, 0, output);
        }
      }
    }
    [output appendString:@"\n"];
  }

  NSError *error = nil;
  [output writeToFile:@"/tmp/dock_layer_dump.txt"
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:&error];

  if (error) {
    LOG_TO_FILE("Failed to write dump: %@", error.localizedDescription);
  } else {
    LOG_TO_FILE("Dump successful: /tmp/dock_layer_dump.txt");
  }
}

#pragma mark - Hider Logic

#pragma mark - Preferences

static void Hider_LoadSettings(void) {
  LOG_TO_FILE("Loading settings from com.aspauldingcode.hider");

  // Synchronize CFPreferences cache from disk
  CFPreferencesAppSynchronize(CFSTR("com.aspauldingcode.hider"));

  Boolean keyExists = false;

  g_finderHidden = (BOOL)CFPreferencesGetAppBooleanValue(
      CFSTR("hideFinder"), CFSTR("com.aspauldingcode.hider"), &keyExists);
  if (!keyExists) g_finderHidden = NO;

  g_trashHidden = (BOOL)CFPreferencesGetAppBooleanValue(
      CFSTR("hideTrash"), CFSTR("com.aspauldingcode.hider"), &keyExists);
  if (!keyExists) g_trashHidden = NO;

  // Separators: always automatic (hide when Trash is hidden)
  g_hideSeparators = NO;
  g_separatorMode = 2;  // Auto

  LOG_TO_FILE("Settings: Finder=%d, Trash=%d (separators=auto)",
              g_finderHidden, g_trashHidden);
}

// Fast path for layout hooks: refresh in-memory flags from CFPreferences cache
// (no disk sync). This makes SwiftUI layout passes pick up settings immediately.
static void Hider_LoadSettingsFromCache(void) {
  Boolean keyExists = false;

  g_finderHidden = (BOOL)CFPreferencesGetAppBooleanValue(
      CFSTR("hideFinder"), CFSTR("com.aspauldingcode.hider"), &keyExists);
  if (!keyExists) g_finderHidden = NO;

  g_trashHidden = (BOOL)CFPreferencesGetAppBooleanValue(
      CFSTR("hideTrash"), CFSTR("com.aspauldingcode.hider"), &keyExists);
  if (!keyExists) g_trashHidden = NO;

  // Separators: always automatic (hide when Trash is hidden)
  g_hideSeparators = NO;
  g_separatorMode = 2;  // Auto
}

// CoreDock function pointers
CoreDockSetTileHiddenFunc CoreDockSetTileHidden = NULL;
CoreDockIsTileHiddenFunc CoreDockIsTileHidden = NULL;
CoreDockRefreshTileFunc CoreDockRefreshTile = NULL;
CoreDockSendNotificationFunc CoreDockSendNotification = NULL;

#pragma mark - CoreDock Loading

static BOOL Hider_LoadCoreDockFunctions(void) {
  if (g_coreDockLoaded)
    return YES;

  const char *coreDockPaths[] = {
      "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
      "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices",
      "/System/Library/Frameworks/ApplicationServices.framework/Versions/Current/ApplicationServices",
  };
  g_coreDockHandle = NULL;
  for (size_t i = 0; i < (sizeof(coreDockPaths) / sizeof(coreDockPaths[0])); i++) {
    g_coreDockHandle = dlopen(coreDockPaths[i], RTLD_LAZY);
    if (g_coreDockHandle) {
      LOG_TO_FILE("Loaded ApplicationServices from: %s", coreDockPaths[i]);
      break;
    }
  }
  if (!g_coreDockHandle) {
    LOG_TO_FILE("Failed to load ApplicationServices: %s", dlerror());
    return NO;
  }

  CoreDockSetTileHidden = (CoreDockSetTileHiddenFunc)dlsym(
      g_coreDockHandle, "CoreDockSetTileHidden");
  CoreDockIsTileHidden =
      (CoreDockIsTileHiddenFunc)dlsym(g_coreDockHandle, "CoreDockIsTileHidden");
  CoreDockRefreshTile =
      (CoreDockRefreshTileFunc)dlsym(g_coreDockHandle, "CoreDockRefreshTile");
  CoreDockSendNotification = (CoreDockSendNotificationFunc)dlsym(
      g_coreDockHandle, "CoreDockSendNotification");

  LOG_TO_FILE("CoreDock symbols: set=%d is=%d refresh=%d notify=%d",
              CoreDockSetTileHidden != NULL, CoreDockIsTileHidden != NULL,
              CoreDockRefreshTile != NULL, CoreDockSendNotification != NULL);

  // Modern macOS may expose only a subset. Treat CoreDock as available if any
  // relevant symbol resolved; callers already guard each function pointer.
  g_coreDockLoaded = (CoreDockSetTileHidden != NULL ||
                      CoreDockIsTileHidden != NULL ||
                      CoreDockRefreshTile != NULL ||
                      CoreDockSendNotification != NULL);
  return g_coreDockLoaded;
}

#pragma mark - Dock Preferences

// The Dock's SwiftUI view tree is rebuilt from com.apple.dock preferences.
// Writing a pref and posting the preferences-changed notification is the only
// guaranteed round-trip for both remove AND restore — layer reinsertion fights
// SwiftUI's reconciler and loses.  We use this as the primary mechanism and
// keep doCommand:1004 only as a belt-and-suspenders on the hide side.

static void Hider_PostDockPrefsChangedNotification(void) {
  Hider_LoadCoreDockFunctions();
  if (CoreDockSendNotification) {
    CoreDockSendNotification(kCoreDockNotificationPreferencesChanged, NULL);
    CoreDockSendNotification(kCoreDockNotificationDockChanged, NULL);
  }
  notify_post("com.apple.dock.preferencesCached");
}

// Write show-finder to the Dock's pref domain.
// "show-finder" is a real key the Dock reads on preference-changed notifications.
// There is no equivalent pref key for Trash — we handle Trash via doCommand:.
static void Hider_WriteFinderPref(void) {
  CFPreferencesSetAppValue(CFSTR("show-finder"),
                           g_finderHidden ? kCFBooleanFalse : kCFBooleanTrue,
                           CFSTR("com.apple.dock"));
  CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
  LOG_TO_FILE("Wrote prefs: show-finder=%d", !g_finderHidden);
}

// Separator state: snapshot persistent-apps/others arrays before removing so
// we can write the items back on restore.
static NSMutableArray *g_savedSeparatorPrefs = nil; // array of {section, index, item} dicts

static BOOL Hider_ShouldRemoveSeparators(void) {
  return g_hideSeparators ||
         (g_separatorMode == 1) ||
         (g_separatorMode == 2 && g_trashHidden) ||
         g_deferSeparatorRestore;
}

static void Hider_RemoveSeparatorsFromPrefs(void) {
  if (g_savedSeparatorPrefs)
    return; // snapshot already taken — don't overwrite with empty state

  g_savedSeparatorPrefs = [NSMutableArray array];

  for (NSString *section in @[@"persistent-apps", @"persistent-others"]) {
    CFArrayRef raw = CFPreferencesCopyAppValue((__bridge CFStringRef)section,
                                               CFSTR("com.apple.dock"));
    if (!raw) continue;
    NSArray *items = (__bridge_transfer NSArray *)raw;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:items.count];
    NSUInteger originalIndex = 0;
    for (id item in items) {
      NSString *tileType = [item isKindOfClass:[NSDictionary class]]
                               ? item[@"tile-type"]
                               : nil;
      if ([tileType isEqualToString:@"spacer-tile"] ||
          [tileType isEqualToString:@"small-spacer-tile"]) {
        [g_savedSeparatorPrefs addObject:@{
          @"section" : section,
          @"index"   : @(originalIndex),
          @"item"    : item
        }];
      } else {
        [filtered addObject:item];
      }
      originalIndex++;
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)section,
                             (__bridge CFArrayRef)filtered,
                             CFSTR("com.apple.dock"));
  }
  CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
  LOG_TO_FILE("Removed %lu separator(s) from prefs",
              (unsigned long)g_savedSeparatorPrefs.count);
}

static void Hider_RestoreSeparatorsToPrefs(void) {
  if (!g_savedSeparatorPrefs.count)
    return;

  // Group saved items by section.
  NSMutableDictionary *bySection = [NSMutableDictionary dictionary];
  for (NSDictionary *entry in g_savedSeparatorPrefs) {
    NSString *sec = entry[@"section"];
    if (!bySection[sec])
      bySection[sec] = [NSMutableArray array];
    [bySection[sec] addObject:entry];
  }

  for (NSString *sec in bySection) {
    CFArrayRef raw = CFPreferencesCopyAppValue((__bridge CFStringRef)sec,
                                               CFSTR("com.apple.dock"));
    NSMutableArray *items =
        raw ? [(__bridge_transfer NSArray *)raw mutableCopy]
            : [NSMutableArray array];

    // Insert saved spacers back at their original positions (ascending order).
    NSArray *sorted = [bySection[sec] sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
          return [(NSNumber *)a[@"index"] compare:(NSNumber *)b[@"index"]];
        }];
    for (NSDictionary *entry in sorted) {
      NSUInteger idx = (NSUInteger)[entry[@"index"] integerValue];
      if (idx > items.count) idx = items.count;
      [items insertObject:entry[@"item"] atIndex:idx];
    }

    CFPreferencesSetAppValue((__bridge CFStringRef)sec,
                             (__bridge CFArrayRef)items,
                             CFSTR("com.apple.dock"));
  }
  CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
  LOG_TO_FILE("Restored %lu separator(s) to prefs",
              (unsigned long)g_savedSeparatorPrefs.count);
  g_savedSeparatorPrefs = nil;
}

#pragma mark - Refresh

static void Hider_RefreshDock(void) {
  LOG_TO_FILE("Refreshing Dock state...");
  BOOL shouldRemoveSeparators = Hider_ShouldRemoveSeparators();
  BOOL prevShouldRemoveSeps   = g_prevSeparatorsRemoved;

  BOOL finderBecameHidden  = g_finderHidden  && !g_prevFinderHidden;
  BOOL finderBecameVisible = !g_finderHidden && g_prevFinderHidden;
  BOOL trashBecameHidden   = g_trashHidden   && !g_prevTrashHidden;
  BOOL trashBecameVisible  = !g_trashHidden  && g_prevTrashHidden;

  // ── Finder ──────────────────────────────────────────────────────────────────
  // Write "show-finder" pref so the Dock's SwiftUI model is consistent, then
  // use doCommand:1004/1003 for the immediate in-process transition.
  Hider_WriteFinderPref();

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  SEL dc = NSSelectorFromString(@"doCommand:");

  if (finderBecameHidden && g_finderTileObject) {
    LOG_TO_FILE("Finder: sending doCommand:1004 (remove)");
    if ([g_finderTileObject respondsToSelector:dc])
      ((void (*)(id, SEL, int))objc_msgSend)(g_finderTileObject, dc, 1004);
  }
  if (finderBecameVisible && g_finderTileObject) {
    LOG_TO_FILE("Finder: sending doCommand:1003 (add)");
    if ([g_finderTileObject respondsToSelector:dc])
      ((void (*)(id, SEL, int))objc_msgSend)(g_finderTileObject, dc, 1003);
  }

  // ── Trash ───────────────────────────────────────────────────────────────────
  // No pref key for Trash; use doCommand:1004/1003 exclusively.
  if (trashBecameHidden && g_trashTileObject) {
    LOG_TO_FILE("Trash: sending doCommand:1004 (remove)");
    if ([g_trashTileObject respondsToSelector:dc])
      ((void (*)(id, SEL, int))objc_msgSend)(g_trashTileObject, dc, 1004);
  }
  if (trashBecameVisible && g_trashTileObject) {
    LOG_TO_FILE("Trash: sending doCommand:1003 (add)");
    if ([g_trashTileObject respondsToSelector:dc])
      ((void (*)(id, SEL, int))objc_msgSend)(g_trashTileObject, dc, 1003);
  }
#pragma clang diagnostic pop

  // ── CoreDockSetTileHidden (belt-and-suspenders, usually NULL) ───────────────
  Hider_LoadCoreDockFunctions();
  if (CoreDockSetTileHidden) {
    CoreDockSetTileHidden(kCoreDockFinderBundleID, (Boolean)g_finderHidden);
    CoreDockSetTileHidden(kCoreDockTrashBundleID,  (Boolean)g_trashHidden);
  }

  // ── Separators ──────────────────────────────────────────────────────────────
  if (shouldRemoveSeparators && !prevShouldRemoveSeps) {
    // Snapshot + remove spacer-tile entries from plist (enables pref-based restore).
    Hider_RemoveSeparatorsFromPrefs();
    // Also fire doCommand:1004 on each tracked separator tile for immediacy.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    SEL pc = NSSelectorFromString(@"performCommand:");
    for (id tile in g_separatorTileObjects) {
      if ([tile respondsToSelector:dc]) {
        ((void (*)(id, SEL, int))objc_msgSend)(tile, dc, 1004);
      } else {
        id d = [tile respondsToSelector:@selector(delegate)]
                   ? [tile performSelector:@selector(delegate)]
                   : nil;
        if (d && [d respondsToSelector:pc])
          ((void (*)(id, SEL, int))objc_msgSend)(d, pc, 1004);
      }
    }
#pragma clang diagnostic pop
  } else if (!shouldRemoveSeparators && prevShouldRemoveSeps) {
    // Defer the plist restore — keep separators hidden in this Dock session.
    // They will be written back to com.apple.dock prefs by the prepareRestart
    // notification handler, just before killall Dock is called.
    g_deferSeparatorRestore = YES;
  }

  // ── Notify Dock to reconcile ─────────────────────────────────────────────
  Hider_PostDockPrefsChangedNotification();

  // 3. Direct anchor path: the tracked floor layers sit next to the tile
  //    container in the layer tree, giving us a fast route to DOCKTileLayers
  //    without traversing from the window root.
  Hider_TriggerLayoutOnTrackedLayers();

  // 4. Full window/NSView burst — fires at 0, 100, 300, 600 ms so we survive
  //    SwiftUI's asynchronous reconciliation passes.
  void (^applyPass)(void) = ^{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    Hider_TriggerLayoutOnTrackedLayers();

    NSArray *windows = [NSApp windows];
    for (NSWindow *window in windows) {
      CALayer *root = window.contentView.layer;
      if (!root) {
        SEL rlSel = NSSelectorFromString(@"_rootLayer");
        if ([window respondsToSelector:rlSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
          root = [window performSelector:rlSel];
#pragma clang diagnostic pop
        }
      }
      if (root) {
        Hider_ApplyVisibilityRecursive(root);
        Hider_ForceLayoutRecursive(root);
      }

      // NSView path: mark dirty then immediately flush pending layout so
      // SwiftUI reconciles without waiting for a hover/mouse event.
      if (window.contentView) {
        Hider_WalkNSViewsForLayout(window.contentView);
        [window.contentView layoutSubtreeIfNeeded];
      }
    }

    [CATransaction commit];
    // Push all pending CALayer changes to the render server immediately.
    [CATransaction flush];
  };

  dispatch_async(dispatch_get_main_queue(), applyPass);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), applyPass);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), applyPass);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), applyPass);

  g_prevFinderHidden      = g_finderHidden;
  g_prevTrashHidden       = g_trashHidden;
  g_prevSeparatorsRemoved = shouldRemoveSeparators;
}

static void Hider_HideFinderIcon(Boolean hide) {
  g_finderHidden = (BOOL)hide;
  Hider_LoadCoreDockFunctions();
  if (CoreDockSetTileHidden)
    CoreDockSetTileHidden(kCoreDockFinderBundleID, hide);
  Hider_RefreshDock();
}

static void Hider_HideTrashIcon(Boolean hide) {
  g_trashHidden = (BOOL)hide;
  Hider_LoadCoreDockFunctions();
  if (CoreDockSetTileHidden)
    CoreDockSetTileHidden(kCoreDockTrashBundleID, hide);
  Hider_RefreshDock();
}

static Boolean Hider_IsFinderIconHidden(void) {
  if (CoreDockIsTileHidden && Hider_LoadCoreDockFunctions()) {
    return CoreDockIsTileHidden(kCoreDockFinderBundleID);
  }
  return (Boolean)g_finderHidden;
}

static Boolean Hider_IsTrashIconHidden(void) {
  if (CoreDockIsTileHidden && Hider_LoadCoreDockFunctions()) {
    return CoreDockIsTileHidden(kCoreDockTrashBundleID);
  }
  return (Boolean)g_trashHidden;
}

#pragma mark - Swizzling Helpers

static void Hider_SwizzleInstanceMethod(Class cls, SEL originalSel, SEL newSel,
                                        IMP newImp) {
  Method originalMethod = class_getInstanceMethod(cls, originalSel);
  if (!originalMethod)
    return;

  class_addMethod(cls, newSel, newImp, method_getTypeEncoding(originalMethod));
  Method newMethod = class_getInstanceMethod(cls, newSel);
  method_exchangeImplementations(originalMethod, newMethod);
}

#pragma mark - DockTileLayer Swizzling

static void swizzleDOCKTileLayer(void) {
  Class cls = NSClassFromString(@"DOCKTileLayer");
  if (!cls)
    return;

  // setHidden: — upstream approach: for Finder/Trash, call performCommand:1004
  // on the delegate (REMOVE_FROM_DOCK) and force hidden=YES.
  SEL setHiddenSel = @selector(setHidden:);
  Method originalSetHidden = class_getInstanceMethod(cls, setHiddenSel);
  if (originalSetHidden) {
    __block IMP originalIMP = method_getImplementation(originalSetHidden);
    void (^block)(id, BOOL) = ^(id self, BOOL hidden) {
      NSString *bundleID = Hider_GetBundleID(self);
      BOOL isTarget = (bundleID && (Hider_IsFinder(bundleID) || Hider_IsTrash(bundleID)));
      BOOL shouldHide = (isTarget && ((Hider_IsFinder(bundleID) && g_finderHidden) ||
                                     (Hider_IsTrash(bundleID) && g_trashHidden)));

      if (shouldHide) {
        Hider_RunOnce(self, "Hider_TileLayer_Remove", ^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
          if ([self respondsToSelector:@selector(delegate)]) {
            id delegate = [self performSelector:@selector(delegate)];
            SEL pc = NSSelectorFromString(@"performCommand:");
            if (delegate && [delegate respondsToSelector:pc])
              ((void (*)(id, SEL, int))objc_msgSend)(delegate, pc, 1004);
          }
#pragma clang diagnostic pop
        });
      }

      static __thread BOOL in_swizzle = NO;
      if (in_swizzle) {
        ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel,
                                              shouldHide ? YES : hidden);
        return;
      }
      in_swizzle = YES;
      ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel,
                                            shouldHide ? YES : hidden);
      in_swizzle = NO;
    };
    Hider_SwizzleInstanceMethod(cls, setHiddenSel,
                                NSSelectorFromString(@"hider_setHidden:"),
                                imp_implementationWithBlock(block));
  }

  // setOpacity:
  // Finder/Trash: remove/add only — pass through.
  SEL setOpacitySel = @selector(setOpacity:);
  Method originalSetOpacity = class_getInstanceMethod(cls, setOpacitySel);
  if (originalSetOpacity) {
    __block IMP originalIMP = method_getImplementation(originalSetOpacity);
    void (^block)(id, float) = ^(id self, float opacity) {
      BOOL forceZero = (g_hideSeparators && Hider_IsSeparatorTileLayer(self));
      NSString *bundleID = Hider_GetBundleID(self);
      if (bundleID) {
        if (Hider_IsFinder(bundleID) && g_finderHidden) forceZero = YES;
        else if (Hider_IsTrash(bundleID) && g_trashHidden) forceZero = YES;
      }
      ((void (*)(id, SEL, float))originalIMP)(self, setOpacitySel,
                                             forceZero ? 0.0f : opacity);
    };
    Hider_SwizzleInstanceMethod(cls, setOpacitySel,
                                NSSelectorFromString(@"hider_setOpacity:"),
                                imp_implementationWithBlock(block));
  }

  // drawInContext:
  SEL drawInContextSel = @selector(drawInContext:);
  Method originalDrawInContext = class_getInstanceMethod(cls, drawInContextSel);
  if (originalDrawInContext) {
    __block IMP originalIMP = method_getImplementation(originalDrawInContext);
    void (^block)(id, CGContextRef) = ^(id self, CGContextRef ctx) {
      if (g_hideSeparators && Hider_IsSeparatorTileLayer(self)) {
        CGRect rect = CGContextGetClipBoundingBox(ctx);
        CGContextClearRect(ctx, rect);
        return;
      }
      ((void (*)(id, SEL, CGContextRef))originalIMP)(self, drawInContextSel, ctx);
    };
    Hider_SwizzleInstanceMethod(cls, drawInContextSel,
                                NSSelectorFromString(@"hider_drawInContext:"),
                                imp_implementationWithBlock(block));
  }

  // layoutSublayers — Salty's suggested hook: called every layout pass.
  // Re-read prefs from cache here so any change takes effect on the very next
  // layout event (hover, bounce, etc.) even without a manual refresh call.
  SEL layoutSublayersSel = @selector(layoutSublayers);
  Method originalLayout = class_getInstanceMethod(cls, layoutSublayersSel);
  if (originalLayout) {
    __block IMP originalLayoutIMP = method_getImplementation(originalLayout);
    void (^layoutBlock)(id) = ^(id self) {
      ((void (*)(id, SEL))originalLayoutIMP)(self, layoutSublayersSel);

      // SwiftUI-driven Dock: layoutSublayers is the authoritative render pass.
      // Refresh flags from CFPreferences cache on each pass.
      Hider_LoadSettingsFromCache();

      NSString *bundleID = Hider_GetBundleID(self);
      BOOL forceHide = (g_hideSeparators && Hider_IsSeparatorTileLayer(self));
      if (bundleID) {
        if (Hider_IsFinder(bundleID) && g_finderHidden) forceHide = YES;
        else if (Hider_IsTrash(bundleID) && g_trashHidden) forceHide = YES;
      }
      if (forceHide) {
        [(CALayer *)self setHidden:YES];
        [(CALayer *)self setOpacity:0.0f];
      }
    };
    Hider_SwizzleInstanceMethod(cls, layoutSublayersSel,
                                NSSelectorFromString(@"hider_layoutSublayers:"),
                                imp_implementationWithBlock(layoutBlock));
  }
}

#pragma mark - Generic Swizzling (CALayer/NSView fallback)

static void swizzleCALayer(void) {
  Class cls = [CALayer class];

  // setHidden:
  SEL setHiddenSel = @selector(setHidden:);
  Method originalSetHidden = class_getInstanceMethod(cls, setHiddenSel);
  __block IMP originalIMP = method_getImplementation(originalSetHidden);

  void (^block)(id, BOOL) = ^(id self, BOOL hidden) {
    static __thread BOOL in_swizzle = NO;
    if (in_swizzle) {
      ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, hidden);
      return;
    }
    in_swizzle = YES;

    if ([NSStringFromClass([self class]) isEqualToString:@"DOCKTileLayer"]) {
      NSString *bundleID = Hider_GetBundleID(self);
      BOOL forceHide = NO;
      if (bundleID) {
        if (Hider_IsFinder(bundleID) && g_finderHidden) forceHide = YES;
        else if (Hider_IsTrash(bundleID) && g_trashHidden) forceHide = YES;
      }
      if (!forceHide && g_hideSeparators && Hider_IsSeparatorTileLayer(self))
        forceHide = YES;
      if (forceHide) {
        ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, YES);
        in_swizzle = NO;
        return;
      }
    }
    if (g_hideSeparators && Hider_IsSeparatorTileLayer(self)) {
      ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, YES);
      in_swizzle = NO;
      return;
    }
    ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, hidden);
    in_swizzle = NO;
  };
  Hider_SwizzleInstanceMethod(cls, setHiddenSel,
                              NSSelectorFromString(@"hider_layer_setHidden:"),
                              imp_implementationWithBlock(block));

  // setOpacity: — needs recursion guard; called very frequently
  SEL setOpacitySel = @selector(setOpacity:);
  Method setOpacityM = class_getInstanceMethod(cls, setOpacitySel);
  if (setOpacityM) {
    __block IMP origOp = method_getImplementation(setOpacityM);
    void (^opBlock)(id, float) = ^(id self, float op) {
      static __thread BOOL in_op_swizzle = NO;
      if (in_op_swizzle) {
        ((void (*)(id, SEL, float))origOp)(self, setOpacitySel, op);
        return;
      }
      in_op_swizzle = YES;
      if (g_hideSeparators && Hider_IsSeparatorTileLayer(self))
        ((void (*)(id, SEL, float))origOp)(self, setOpacitySel, 0.0f);
      else
        ((void (*)(id, SEL, float))origOp)(self, setOpacitySel, op);
      in_op_swizzle = NO;
    };
    Hider_SwizzleInstanceMethod(
        cls, setOpacitySel, NSSelectorFromString(@"hider_layer_setOpacity:"),
        imp_implementationWithBlock(opBlock));
  }

  // drawInContext:
  SEL drawInContextSel = @selector(drawInContext:);
  Method drawInContextM = class_getInstanceMethod(cls, drawInContextSel);
  if (drawInContextM) {
    __block IMP origDraw = method_getImplementation(drawInContextM);
    void (^drawBlock)(id, CGContextRef) = ^(id self, CGContextRef ctx) {
      if (g_hideSeparators && Hider_IsSeparatorTileLayer(self)) {
        CGRect rect = CGContextGetClipBoundingBox(ctx);
        CGContextClearRect(ctx, rect);
        return;
      }
      ((void (*)(id, SEL, CGContextRef))origDraw)(self, drawInContextSel, ctx);
    };
    Hider_SwizzleInstanceMethod(
        cls, drawInContextSel,
        NSSelectorFromString(@"hider_layer_drawInContext:"),
        imp_implementationWithBlock(drawBlock));
  }

  // layoutSublayers
  SEL layoutSublayersSel = @selector(layoutSublayers);
  Method originalLayout = class_getInstanceMethod(cls, layoutSublayersSel);
  if (originalLayout) {
    __block IMP originalLayoutIMP = method_getImplementation(originalLayout);
    void (^layoutBlock)(id) = ^(id self) {
      ((void (*)(id, SEL))originalLayoutIMP)(self, layoutSublayersSel);

      if ([NSStringFromClass([self class]) isEqualToString:@"DOCKTileLayer"]) {
        NSString *bundleID = Hider_GetBundleID(self);
        BOOL forceHide = (g_hideSeparators && Hider_IsSeparatorTileLayer(self));
        if (bundleID) {
          if (Hider_IsFinder(bundleID) && g_finderHidden) forceHide = YES;
          else if (Hider_IsTrash(bundleID) && g_trashHidden) forceHide = YES;
        }
        if (forceHide) {
          [(CALayer *)self setHidden:YES];
          [(CALayer *)self setOpacity:0.0f];
        }
      } else if (g_hideSeparators && Hider_IsSeparatorTileLayer(self)) {
        [(CALayer *)self setHidden:YES];
        [(CALayer *)self setOpacity:0.0f];
      }

      NSString *cn = NSStringFromClass([self class]);
      if ([cn containsString:@"FloorLayer"] || [cn containsString:@"Container"]) {
        Hider_HideFloorSeparators((CALayer *)self);
      }
    };
    Hider_SwizzleInstanceMethod(cls, layoutSublayersSel,
                                NSSelectorFromString(@"hider_layer_layoutSublayers:"),
                                imp_implementationWithBlock(layoutBlock));
  }
}

static void swizzleNSView(void) {
  Class cls = [NSView class];

  // setHidden:
  SEL setHiddenSel = @selector(setHidden:);
  Method originalSetHidden = class_getInstanceMethod(cls, setHiddenSel);
  __block IMP originalIMP = method_getImplementation(originalSetHidden);

  void (^block)(id, BOOL) = ^(id self, BOOL hidden) {
    static __thread BOOL in_swizzle = NO;
    if (in_swizzle) {
      ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, hidden);
      return;
    }
    in_swizzle = YES;

    NSString *bundleID = Hider_GetBundleID(self);
    BOOL forceHide = (g_hideSeparators && Hider_IsSeparatorTileLayer(self));
    if (bundleID) {
      if (Hider_IsFinder(bundleID) && g_finderHidden) forceHide = YES;
      else if (Hider_IsTrash(bundleID) && g_trashHidden) forceHide = YES;
    }

    ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel,
                                          forceHide ? YES : hidden);
    in_swizzle = NO;
  };
  Hider_SwizzleInstanceMethod(cls, setHiddenSel,
                              NSSelectorFromString(@"hider_view_setHidden:"),
                              imp_implementationWithBlock(block));

  // setAlphaValue:
  SEL setAlphaSel = @selector(setAlphaValue:);
  Method setAlphaM = class_getInstanceMethod(cls, setAlphaSel);
  if (setAlphaM) {
    __block IMP origAl = method_getImplementation(setAlphaM);
    void (^alBlock)(id, CGFloat) = ^(id self, CGFloat a) {
      if (g_hideSeparators && Hider_IsSeparatorTileLayer(self))
        ((void (*)(id, SEL, CGFloat))origAl)(self, setAlphaSel, 0.0);
      else
        ((void (*)(id, SEL, CGFloat))origAl)(self, setAlphaSel, a);
    };
    Hider_SwizzleInstanceMethod(cls, setAlphaSel,
                                NSSelectorFromString(@"hider_view_setAlpha:"),
                                imp_implementationWithBlock(alBlock));
  }
}

#pragma mark - DockCore Class Swizzling

static void swizzleDOCKTrashTile(Class cls) {
  SEL updateSel = NSSelectorFromString(@"update");
  if (![cls instancesRespondToSelector:updateSel])
    updateSel = @selector(init); // Fallback

  Method originalMethod = class_getInstanceMethod(cls, updateSel);
  if (!originalMethod)
    return;
  __block IMP originalIMP = method_getImplementation(originalMethod);

  id (^block)(id) = ^id(id self) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    g_trashTileObject = self;
    // Upstream: doCommand:1004 = REMOVE_FROM_DOCK
    Hider_RunOnce(self, "Hider_Trash_Remove", ^{
      SEL dc = NSSelectorFromString(@"doCommand:");
      if (g_trashHidden && [self respondsToSelector:dc])
        ((void (*)(id, SEL, int))objc_msgSend)(self, dc, 1004);
    });
#pragma clang diagnostic pop

    if (updateSel == @selector(init)) {
      return ((id(*)(id, SEL))originalIMP)(self, updateSel);
    } else {
      ((void (*)(id, SEL))originalIMP)(self, updateSel);
      return (id)nil;
    }
  };
  class_replaceMethod(cls, updateSel, imp_implementationWithBlock(block),
                      method_getTypeEncoding(originalMethod));
}

static void swizzleDOCKDesktopTile(Class cls) {
  SEL updateSel = NSSelectorFromString(@"update");
  if (![cls instancesRespondToSelector:updateSel])
    updateSel = @selector(init);

  Method originalMethod = class_getInstanceMethod(cls, updateSel);
  if (!originalMethod)
    return;
  __block IMP originalIMP = method_getImplementation(originalMethod);

  id (^block)(id) = ^id(id self) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    g_finderTileObject = self;
    // Upstream: doCommand:1004 = REMOVE_FROM_DOCK
    Hider_RunOnce(self, "Hider_Desktop_Remove", ^{
      SEL dc = NSSelectorFromString(@"doCommand:");
      if (g_finderHidden && [self respondsToSelector:dc])
        ((void (*)(id, SEL, int))objc_msgSend)(self, dc, 1004);
    });
#pragma clang diagnostic pop

    if (updateSel == @selector(init)) {
      return ((id(*)(id, SEL))originalIMP)(self, updateSel);
    } else {
      ((void (*)(id, SEL))originalIMP)(self, updateSel);
      return (id)nil;
    }
  };
  class_replaceMethod(cls, updateSel, imp_implementationWithBlock(block),
                      method_getTypeEncoding(originalMethod));
}

static void swizzleDOCKFileTile(Class cls) {
  SEL updateSel = NSSelectorFromString(@"update");
  if (![cls instancesRespondToSelector:updateSel])
    updateSel = @selector(init);

  Method originalMethod = class_getInstanceMethod(cls, updateSel);
  if (!originalMethod)
    return;
  __block IMP originalIMP = method_getImplementation(originalMethod);

  id (^block)(id) = ^id(id self) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSString *bundleID = nil;
    if ([self respondsToSelector:@selector(bundleIdentifier)])
      bundleID = [self performSelector:@selector(bundleIdentifier)];

    if (bundleID && Hider_IsFinder(bundleID)) {
      g_finderTileObject = self;
      // Upstream: performCommand:1004 = REMOVE_FROM_DOCK
      Hider_RunOnce(self, "Hider_FileTile_Finder_Remove", ^{
        SEL pc = NSSelectorFromString(@"performCommand:");
        if (g_finderHidden && [self respondsToSelector:pc])
          ((void (*)(id, SEL, int))objc_msgSend)(self, pc, 1004);
      });
    }
#pragma clang diagnostic pop

    if (updateSel == @selector(init)) {
      return ((id(*)(id, SEL))originalIMP)(self, updateSel);
    } else {
      ((void (*)(id, SEL))originalIMP)(self, updateSel);
      return (id)nil;
    }
  };
  class_replaceMethod(cls, updateSel, imp_implementationWithBlock(block),
                      method_getTypeEncoding(originalMethod));
}

static void swizzleDOCKSpacerTile(Class cls) {
  SEL sel = NSSelectorFromString(@"update");
  if (![cls instancesRespondToSelector:sel])
    sel = NSSelectorFromString(@"updateRect");
  if (![cls instancesRespondToSelector:sel])
    sel = @selector(init);
  Method m = class_getInstanceMethod(cls, sel);
  if (!m)
    return;
  __block IMP orig = method_getImplementation(m);
  id (^block)(id) = ^id(id self) {
    // Register this tile object so Hider_RefreshDock can send doCommand:1004
    // to it when g_hideSeparators changes (driven centrally, not per-update).
    if (!g_separatorTileObjects)
      g_separatorTileObjects = [NSMutableArray array];
    if (![g_separatorTileObjects containsObject:self])
      [g_separatorTileObjects addObject:self];

    if (sel == @selector(init))
      return ((id(*)(id, SEL))orig)(self, sel);
    ((void (*)(id, SEL))orig)(self, sel);
    return (id)nil;
  };
  class_replaceMethod(cls, sel, imp_implementationWithBlock(block),
                      method_getTypeEncoding(m));

  SEL setHiddenSel = @selector(setHidden:);
  Method setHiddenM = class_getInstanceMethod(cls, setHiddenSel);
  if (setHiddenM) {
    __block IMP origSH = method_getImplementation(setHiddenM);
    Hider_SwizzleInstanceMethod(
        cls, setHiddenSel, NSSelectorFromString(@"hider_spacer_setHidden:"),
        imp_implementationWithBlock(^(id self, BOOL h) {
          BOOL hide = g_hideSeparators ||
                      (g_separatorMode == 1) ||
                      (g_separatorMode == 2 && g_trashHidden) ||
                      g_deferSeparatorRestore;
          ((void (*)(id, SEL, BOOL))origSH)(self, setHiddenSel, hide ? YES : h);
        }));
  }
  if ([cls isSubclassOfClass:[NSView class]]) {
    SEL setAlphaSel = @selector(setAlphaValue:);
    Method setAlphaM = class_getInstanceMethod(cls, setAlphaSel);
    if (setAlphaM) {
      __block IMP origSA = method_getImplementation(setAlphaM);
      Hider_SwizzleInstanceMethod(
          cls, setAlphaSel, NSSelectorFromString(@"hider_spacer_setAlpha:"),
          imp_implementationWithBlock(^(id self, CGFloat a) {
            if (g_hideSeparators || g_deferSeparatorRestore)
              ((void (*)(id, SEL, CGFloat))origSA)(self, setAlphaSel, 0.0);
            else
              ((void (*)(id, SEL, CGFloat))origSA)(self, setAlphaSel, a);
          }));
    }
    SEL drawRectSel = @selector(drawRect:);
    Method drawRectM = class_getInstanceMethod(cls, drawRectSel);
    if (drawRectM) {
      __block IMP origDR = method_getImplementation(drawRectM);
      Hider_SwizzleInstanceMethod(
          cls, drawRectSel, NSSelectorFromString(@"hider_spacer_drawRect:"),
          imp_implementationWithBlock(^(id self, NSRect r) {
            if (g_hideSeparators || g_deferSeparatorRestore) {
              /* suppress separator drawing */
            } else {
              ((void (*)(id, SEL, NSRect))origDR)(self, drawRectSel, r);
            }
          }));
    }
  }

  SEL layoutSublayersSel = @selector(layoutSublayers);
  Method mLayout = class_getInstanceMethod(cls, layoutSublayersSel);
  if (mLayout) {
    __block IMP origLayout = method_getImplementation(mLayout);
    Hider_SwizzleInstanceMethod(
        cls, layoutSublayersSel,
        NSSelectorFromString(@"hider_spacer_layoutSublayers:"),
        imp_implementationWithBlock(^(id self) {
          ((void (*)(id, SEL))origLayout)(self, layoutSublayersSel);
          if (g_hideSeparators || g_deferSeparatorRestore) {
            if ([self isKindOfClass:[CALayer class]]) {
              [(CALayer *)self setHidden:YES];
              [(CALayer *)self setOpacity:0.0f];
            } else if ([self isKindOfClass:[NSView class]]) {
              [(NSView *)self setHidden:YES];
              [(NSView *)self setAlphaValue:0.0];
            }
          }
        }));
  }
}

static void swizzleDOCKFloorLayer(Class cls) {
  if (!cls)
    return;

  SEL layoutSublayersSel = @selector(layoutSublayers);
  Method originalMethod = class_getInstanceMethod(cls, layoutSublayersSel);
  if (!originalMethod)
    return;

  __block IMP originalIMP = method_getImplementation(originalMethod);
  void (^block)(id) = ^(id self) {
    // Track for targeted refresh
    const char *name = class_getName([self class]);
    if (strstr(name, "ModernFloorLayer"))
      g_modernFloorLayer = (CALayer *)self;
    else if (strstr(name, "LegacyFloorLayer"))
      g_legacyFloorLayer = (CALayer *)self;

    // Call original first, then apply separator hiding
    ((void (*)(id, SEL))originalIMP)(self, layoutSublayersSel);
    // Keep flags in sync with latest GUI values for each SwiftUI layout pass.
    Hider_LoadSettingsFromCache();
    Hider_HideFloorSeparators((CALayer *)self);
  };

  class_replaceMethod(cls, layoutSublayersSel,
                      imp_implementationWithBlock(block),
                      method_getTypeEncoding(originalMethod));
  LOG_TO_FILE("Swizzled floor layer: %s", class_getName(cls));
}

static void swizzleDockCoreClasses(void) {
  if (NSClassFromString(@"DOCKTileLayer"))
    swizzleDOCKTileLayer();

  Class modernFloor = NSClassFromString(@"_TtC8DockCore16ModernFloorLayer");
  if (modernFloor) {
    LOG_TO_FILE("Found ModernFloorLayer");
    swizzleDOCKFloorLayer(modernFloor);
  }

  Class legacyFloor = NSClassFromString(@"_TtC8DockCore16LegacyFloorLayer");
  if (legacyFloor) {
    LOG_TO_FILE("Found LegacyFloorLayer");
    swizzleDOCKFloorLayer(legacyFloor);
  }

  unsigned int classCount = 0;
  Class *classes = objc_copyClassList(&classCount);

  for (unsigned int i = 0; i < classCount; i++) {
    const char *name = class_getName(classes[i]);
    if (strstr(name, "Dock") || strstr(name, "DOCK")) {
      if (strcmp(name, "DOCKTrashTile") == 0) {
        LOG_TO_FILE("Swizzling trash tile class: %s", name);
        swizzleDOCKTrashTile(classes[i]);
      } else if (strcmp(name, "DOCKFileTile") == 0) {
        LOG_TO_FILE("Swizzling file tile class: %s", name);
        swizzleDOCKFileTile(classes[i]);
      } else if (strcmp(name, "DOCKDesktopTile") == 0) {
        LOG_TO_FILE("Swizzling desktop tile class: %s", name);
        swizzleDOCKDesktopTile(classes[i]);
      } else if (strcmp(name, "DOCKSeparatorTile") == 0 ||
                 strcmp(name, "DOCKSpacerTile") == 0) {
        LOG_TO_FILE("Swizzling spacer/separator class: %s", name);
        swizzleDOCKSpacerTile(classes[i]);
      }
    }
  }
  free(classes);
}

#pragma mark - Initialization

static int tokenHideFinder, tokenShowFinder, tokenToggleFinder;
static int tokenHideTrash, tokenShowTrash, tokenToggleTrash;
static int tokenHideAll, tokenShowAll;
static int tokenDump, tokenPrepareRestart;

// Debounce: coalesce rapid settingsChanged bursts into one refresh
static BOOL g_pendingRefresh = NO;

__attribute__((constructor)) static void Hider_Init(void) {
  @autoreleasepool {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.apple.dock"])
      return;

    LOG_TO_FILE("Hider_Init: starting");

    Hider_LoadSettings();
    swizzleDockCoreClasses();
    swizzleCALayer();
    swizzleNSView();

    // On initial injection apply current settings so a freshly-restarted Dock
    // starts with the correct pref state (e.g. separators absent when trash is
    // hidden).  g_prev* are all NO at this point, so RefreshDock treats every
    // enabled setting as a fresh transition and removes items from prefs.
    // Stagger two passes: first at 300 ms (Dock is likely ready), second at
    // 800 ms as a belt-and-suspenders in case startup takes longer.
    void (^initRefresh)(void) = ^{
      Hider_LoadSettings();
      Hider_RefreshDock();
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), initRefresh);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), initRefresh);

    // Settings changed — debounced to prevent notification storm loops
    int settingsToken;
    notify_register_dispatch(
        "com.aspauldingcode.hider.settingsChanged", &settingsToken,
        dispatch_get_main_queue(), ^(__unused int t) {
          if (g_pendingRefresh) {
            return;
          }
          g_pendingRefresh = YES;
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                g_pendingRefresh = NO;
                LOG_TO_FILE("Settings changed — applying");
                Hider_LoadSettings();
                Hider_RefreshDock();
              });
        });

    notify_register_dispatch("com.hider.finder.hide", &tokenHideFinder,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_HideFinderIcon(YES);
                             });
    notify_register_dispatch("com.hider.finder.show", &tokenShowFinder,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_HideFinderIcon(NO);
                             });
    notify_register_dispatch("com.hider.finder.toggle", &tokenToggleFinder,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               BOOL hidden = (BOOL)Hider_IsFinderIconHidden();
                               Hider_HideFinderIcon(!hidden);
                             });

    notify_register_dispatch("com.hider.trash.hide", &tokenHideTrash,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_HideTrashIcon(YES);
                             });
    notify_register_dispatch("com.hider.trash.show", &tokenShowTrash,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_HideTrashIcon(NO);
                             });
    notify_register_dispatch("com.hider.trash.toggle", &tokenToggleTrash,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               BOOL hidden = (BOOL)Hider_IsTrashIconHidden();
                               Hider_HideTrashIcon(!hidden);
                             });

    notify_register_dispatch("com.hider.dump", &tokenDump,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_DumpDockHierarchy();
                             });

    // Restore separator prefs to com.apple.dock just before killall Dock.
    // Swift sends this notification, waits briefly, then kills the process.
    notify_register_dispatch("com.hider.prepareRestart", &tokenPrepareRestart,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               g_deferSeparatorRestore = NO;
                               // Only restore separators to prefs if they should
                               // actually be visible after the restart.  Evaluate
                               // the real conditions WITHOUT the defer flag so
                               // that e.g. "Hide Trash still ON" keeps them gone.
                               BOOL stillHidden = g_hideSeparators ||
                                                  (g_separatorMode == 1) ||
                                                  (g_separatorMode == 2 && g_trashHidden);
                               if (!stillHidden) {
                                 Hider_RestoreSeparatorsToPrefs();
                                 LOG_TO_FILE("prepareRestart: separator prefs restored");
                               } else {
                                 LOG_TO_FILE("prepareRestart: separators still hidden, skipping restore");
                               }
                               CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
                             });

    notify_register_dispatch("com.hider.hideall", &tokenHideAll,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_HideFinderIcon(YES);
                               Hider_HideTrashIcon(YES);
                             });

    notify_register_dispatch("com.hider.showall", &tokenShowAll,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               Hider_HideFinderIcon(NO);
                               Hider_HideTrashIcon(NO);
                             });

    LOG_TO_FILE("Hider_Init: complete");
  }
}

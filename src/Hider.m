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
#import <float.h>
#import <stddef.h>
#import <stdint.h>

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

// Custom hidden apps (populated from SettingsManager "hiddenApps" pref array).
// All bundle IDs stored here are normalized (lowercased + trimmed).
static NSSet   *g_hiddenAppBundleIDs   = nil;
static NSSet   *g_prevHiddenAppBundleIDs = nil;
// Tile objects for custom hidden apps: normalized-bundleID → tile model object.
// Running-app hiding is deliberately opt-in.  A panic breadcrumb left behind
// by an interrupted mutation disables it on the next Dock launch.
static BOOL g_runHideSafeMode = NO;
static int64_t g_launchGen = 0;
// Key used by Hider_RunOnce to mark that doCommand:1004 was sent for a tile.

// Associated-object keys for tagging individual tile/layer objects with
// durable per-object state that survives across swizzle hops.
// - kHiderBundleIDTag: attached to tile-model objects → their normalized
//   bundle ID. Used by layer hooks for reverse-lookup when Hider_GetBundleID
//   cannot resolve the bundle ID from the layer directly.
// - kHiderSlotSuppressed: attached to slot-container CALayers → @YES when
//   the slot is actively suppressed. Enforced in setHidden:/setOpacity:
//   swizzles so the Dock cannot restore visibility.
static const char kHiderSlotSuppressed;

// Helper functions
NSString *Hider_GetBundleID(id obj);
BOOL Hider_IsFinder(NSString *bundleID);
BOOL Hider_IsTrash(NSString *bundleID);
BOOL Hider_IsCustomHiddenApp(NSString *bundleID);
BOOL Hider_IsSeparatorTileLayer(id obj);
static void Hider_LoadCustomAppsFromPrefs(void);
static void Hider_LoadCustomAppsFromCache(void);
static void Hider_LoadSettingsFromCache(void);

// Bundle-ID normalization: lowercase + trim whitespace.
static NSString *Hider_NormalizeBundleID(NSString *bid);

// Tile registry: tag tile-model objects with their resolved bundle ID and
// populate g_customAppTileObjects for both forward and reverse lookup.

// Crash-bounded running-app hiding.
static BOOL Hider_RunHideActive(void);
static BOOL Hider_RunHideBudgetOK(void);
static BOOL Hider_IsDOCKProcessTile(id object);

// Resolve the bundle ID for a DOCKTileLayer, trying Hider_GetBundleID first,
// then the associated-object tag on the delegate, then g_customAppTileObjects
// pointer-comparison fallback.
static NSString *Hider_ResolveBundleIDForLayer(CALayer *layer);

// Resolve hidden-app bundle ID from tile delegate's PID (fallback).

// Single-point query: should this DOCKTileLayer be force-hidden?
static BOOL Hider_ShouldForceHideLayer(CALayer *layer);

// Slot-container suppression: tag a slot layer and hide it and all siblings.
static void Hider_SuppressSlot(CALayer *tileLayer);
static BOOL Hider_IsSlotSuppressed(CALayer *layer);

// Unified enforcement: discover tiles, suppress, remove across all windows.
// Hotload hidden-app list changes immediately.

// Execution guard
void Hider_RunOnce(id object, const void *key, void (^block)(void));

// Layout helpers
static void Hider_ApplyEdgeTileVisibility(CALayer *parent);
void Hider_ForceLayoutRecursive(CALayer *layer);
static void Hider_ApplyVisibilityRecursive(CALayer *layer);
static void Hider_TriggerLayoutOnTrackedLayers(void);
static void Hider_WalkNSViewsForLayout(NSView *view);

// Suppress a tile-model's visual output if it belongs to a hidden custom app.
// Remove a hidden tile immediately with retries.

// PID-based tile discovery (fallback for when Hider_GetBundleID fails)

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

static NSString *Hider_NormalizeBundleID(NSString *bid) {
  if (!bid) return nil;
  NSString *trimmed = [bid stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return [trimmed lowercaseString];
}

BOOL Hider_IsCustomHiddenApp(NSString *bundleID) {
  if (!bundleID || !g_hiddenAppBundleIDs) return NO;
  NSString *normalized = Hider_NormalizeBundleID(bundleID);
  if (!normalized) return NO;
  if (Hider_IsFinder(normalized) || Hider_IsTrash(normalized)) return NO;
  return [g_hiddenAppBundleIDs containsObject:normalized];
}

// Normalize an array of bundle-ID strings into a set.
static NSSet *Hider_NormalizeSet(NSArray *arr) {
  NSMutableSet *s = [NSMutableSet setWithCapacity:arr.count];
  for (NSString *bid in arr) {
    NSString *n = Hider_NormalizeBundleID(bid);
    if (n.length > 0) [s addObject:n];
  }
  return [s copy];
}

// Read hiddenApps plist array from our prefs domain (with disk sync).
static void Hider_LoadCustomAppsFromPrefs(void) {
  CFPropertyListRef raw = CFPreferencesCopyAppValue(
      CFSTR("hiddenApps"), CFSTR("com.aspauldingcode.hider"));
  if (raw) {
    if (CFGetTypeID(raw) == CFArrayGetTypeID()) {
      NSArray *arr = (__bridge_transfer NSArray *)raw;
      g_hiddenAppBundleIDs = Hider_NormalizeSet(arr);
    } else {
      CFRelease(raw);
      g_hiddenAppBundleIDs = [NSSet set];
    }
  } else {
    g_hiddenAppBundleIDs = [NSSet set];
  }
  LOG_TO_FILE("Custom hidden apps: %lu", (unsigned long)g_hiddenAppBundleIDs.count);
}

// Fast cache read (no disk sync) – safe to call from layout hooks.
static void Hider_LoadCustomAppsFromCache(void) {
  CFPropertyListRef raw = CFPreferencesCopyAppValue(
      CFSTR("hiddenApps"), CFSTR("com.aspauldingcode.hider"));
  if (raw) {
    if (CFGetTypeID(raw) == CFArrayGetTypeID()) {
      NSArray *arr = (__bridge_transfer NSArray *)raw;
      g_hiddenAppBundleIDs = Hider_NormalizeSet(arr);
    } else {
      CFRelease(raw);
    }
  }
  if (!g_hiddenAppBundleIDs)
    g_hiddenAppBundleIDs = [NSSet set];
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
      // URL-based: dock items always know their .app URL/path.
      SEL urlSel   = @selector(url);
      SEL furlSel  = @selector(fileURL);
      SEL URLSel   = NSSelectorFromString(@"URL");
      id urlCandidates[3] = {nil, nil, nil};
      int nURLCandidates = 0;
      if ([c respondsToSelector:urlSel])  urlCandidates[nURLCandidates++] = [c performSelector:urlSel];
      if ([c respondsToSelector:furlSel]) urlCandidates[nURLCandidates++] = [c performSelector:furlSel];
      if ([c respondsToSelector:URLSel])  urlCandidates[nURLCandidates++] = [c performSelector:URLSel];
      for (int ui = 0; ui < nURLCandidates; ui++) {
        id u = urlCandidates[ui];
        if ([u isKindOfClass:[NSURL class]]) {
          NSBundle *b = [NSBundle bundleWithURL:(NSURL *)u];
          if (b.bundleIdentifier) { bundleID = b.bundleIdentifier; goto found; }
        }
      }

      // NSRunningApplication — available for tiles of running apps.
      SEL raSel  = NSSelectorFromString(@"application");
      SEL raSel2 = NSSelectorFromString(@"runningApplication");
      id raCandidates[2] = {nil, nil};
      int nRACandidates = 0;
      if ([c respondsToSelector:raSel])  raCandidates[nRACandidates++] = [c performSelector:raSel];
      if ([c respondsToSelector:raSel2]) raCandidates[nRACandidates++] = [c performSelector:raSel2];
      for (int ri = 0; ri < nRACandidates; ri++) {
        id ra = raCandidates[ri];
        if ([ra isKindOfClass:[NSRunningApplication class]]) {
          NSString *bid = [(NSRunningApplication *)ra bundleIdentifier];
          if (bid) { bundleID = bid; goto found; }
        }
      }

      // Additional selectors used by some Dock private classes.
      SEL appBIDSel = NSSelectorFromString(@"applicationBundleIdentifier");
      if ([c respondsToSelector:appBIDSel]) {
        id v = [c performSelector:appBIDSel];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
          bundleID = (NSString *)v; goto found;
        }
      }
      SEL appIDSel = NSSelectorFromString(@"appBundleID");
      if ([c respondsToSelector:appIDSel]) {
        id v = [c performSelector:appIDSel];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
          bundleID = (NSString *)v; goto found;
        }
      }

      // Description scan — explicit Finder/Trash first, then generic.
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
        // Generic: look for bundleID="..." / bundleIdentifier=... patterns that
        // many Dock tile description strings include.
        NSArray *scanPatterns = @[@"bundleID=\"", @"bundleID=",
                                  @"bundleIdentifier=\"", @"bundleIdentifier="];
        for (NSString *pat in scanPatterns) {
          NSRange pr = [desc rangeOfString:pat options:NSCaseInsensitiveSearch];
          if (pr.location == NSNotFound) continue;
          NSUInteger vs = pr.location + pr.length;
          if (vs >= desc.length) continue;
          if ([desc characterAtIndex:vs] == '"' || [desc characterAtIndex:vs] == '\'') vs++;
          if (vs >= desc.length) continue;
          NSUInteger ve = vs;
          while (ve < desc.length) {
            unichar ch = [desc characterAtIndex:ve];
            if (ch == '"' || ch == '\'' || ch == ' ' || ch == '>' || ch == '\n') break;
            ve++;
          }
          if (ve > vs) {
            NSString *candidate = [desc substringWithRange:NSMakeRange(vs, ve - vs)];
            if ([candidate containsString:@"."] && candidate.length > 3) {
              bundleID = candidate; goto found;
            }
          }
          break; // first matching pattern is authoritative
        }
        // Last resort: scan for any "com.X.Y" reversed-domain pattern.
        NSUInteger dlen = desc.length;
        for (NSUInteger si = 0; si + 5 < dlen; si++) {
          if ([desc characterAtIndex:si]   != 'c') continue;
          if ([desc characterAtIndex:si+1] != 'o') continue;
          if ([desc characterAtIndex:si+2] != 'm') continue;
          if ([desc characterAtIndex:si+3] != '.') continue;
          NSUInteger end = si + 4;
          while (end < dlen) {
            unichar ch = [desc characterAtIndex:end];
            if (ch == '.' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                (ch >= '0' && ch <= '9') || ch == '-' || ch == '_')
              end++;
            else
              break;
          }
          if (end - si >= 7) {
            NSString *cand = [desc substringWithRange:NSMakeRange(si, end - si)];
            if ([cand componentsSeparatedByString:@"."].count >= 3) {
              bundleID = cand; goto found;
            }
          }
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

#pragma mark - Tile Registry + Enforcement Helpers

static NSString *Hider_ResolveBundleIDForLayer(CALayer *layer) {
  if (!layer) return nil;
  NSString *bid = Hider_GetBundleID(layer);
  return bid ? Hider_NormalizeBundleID(bid) : nil;
}

// Should this layer be force-hidden? True for Finder/Trash when their toggle is
// on, or a separator when hideSeparators is on.
static BOOL Hider_ShouldForceHideLayer(CALayer *layer) {
  NSString *bid = Hider_ResolveBundleIDForLayer(layer);
  if (bid) {
    if (Hider_IsFinder(bid) && g_finderHidden) return YES;
    if (Hider_IsTrash(bid) && g_trashHidden)   return YES;
    // A hidden running app is handled by prevention: its tile is refused in
    // Hider_InsertTileHook, so it never enters the model and there is no layer
    // to hide here.
  }
  if (g_hideSeparators && Hider_IsSeparatorTileLayer(layer)) return YES;
  return NO;
}

static BOOL Hider_IsSlotSuppressed(CALayer *layer) {
  if (!layer) return NO;
  return [objc_getAssociatedObject(layer, &kHiderSlotSuppressed) boolValue];
}

// Snapshot layer.sublayers to avoid mutation-while-enumerating crashes.
static NSArray<CALayer *> *Hider_SublayersSnapshot(CALayer *layer) {
  if (!layer || !layer.sublayers) return @[];
  return [layer.sublayers copy];
}

#pragma mark - Safe Running-App Hiding

static BOOL Hider_RunHideActive(void) {
  if (g_runHideSafeMode) return NO;
  // Persistent opt-in: the `hideRunningApps` bool in the Hider prefs domain
  // (settable via the app / `hiderctl runhide on` / `defaults write`). The
  // /tmp/hider-run-hide file is a transient testing override.
  Boolean keyExists = false;
  Boolean pref = CFPreferencesGetAppBooleanValue(
      CFSTR("hideRunningApps"), CFSTR("com.aspauldingcode.hider"), &keyExists);
  if (keyExists && pref) return YES;
  return [[NSFileManager defaultManager]
      fileExistsAtPath:@"/tmp/hider-run-hide"];
}

// Running-app hiding: a hidden running app gets no Dock tile at all — no icon,
// no gap/slot, no hit-testing, no tooltip. Every process tile (a fresh launch, or
// an app already running when the Dock starts) enters DockBar's Swift [Tile]
// array through the single main-thread chokepoint
// -[DockBar insertTile:atIndex:forReason:]. For a hidden app we don't forward
// that insert, so its tile never enters the model. A re-add re-enters the hook
// and is skipped again, so the tile stays out.
static void (*g_orig_insertTile)(id, SEL, id, NSInteger, id) = NULL;

static BOOL Hider_ShouldRefuseTile(id tile) {
  if (!Hider_IsDOCKProcessTile(tile)) return NO;  // never touch Finder/Trash/etc.
  @try {
    NSString *bid = Hider_NormalizeBundleID(Hider_GetBundleID(tile));
    return bid.length > 0 && Hider_IsCustomHiddenApp(bid);
  } @catch (__unused NSException *e) {
    return NO;
  }
}

// Count of the DockBar's bridged tiles snapshot (-1 on failure, for logging).
static NSUInteger Hider_TilesCount(id dock) {
  @try {
    id t = [dock valueForKey:@"tiles"];
    if ([t isKindOfClass:[NSArray class]]) return [(NSArray *)t count];
  } @catch (__unused NSException *e) {}
  return (NSUInteger)-1;
}

// insertTile:atIndex:forReason: is the single main-thread insertion chokepoint
// for both paths a hidden running app enters the Dock: a fresh launch (reason
// -[DockBar _handleLaunchNotification:data:]) and an app already running when the
// Dock starts (reason -[DockBar addProcessForASN:...]). For a hidden app we don't
// forward the insert, so the tile never enters the `tiles` array: no icon, no gap,
// no hit-test, no tooltip. The tile object still exists (addProcessForASN's caller
// gets its non-optional Swift return); it is just never in the model.
static void Hider_InsertTileHook(id self, SEL _cmd, id tile, NSInteger index,
                                 id reason) {
  if (Hider_RunHideActive() && Hider_ShouldRefuseTile(tile) &&
      Hider_RunHideBudgetOK()) {
    NSString *bid = nil;
    @try { bid = Hider_NormalizeBundleID(Hider_GetBundleID(tile)); }
    @catch (__unused NSException *e) {}
    LOG_TO_FILE("insertTile: SKIP insertion for hidden %@ (reason %@)",
                bid ? bid : @"?", reason);
    return;  // do NOT forward to the original insertTile
  }
  // Index clamp (crash fix). Because we skip inserts for hidden apps, the `tiles`
  // array is SHORTER than the count DockCore assumes when it computes atIndex for
  // a later tile. Forwarding an insert with index > count makes DockCore's Swift
  // `array.insert(at:)` hit a precondition and CRASH the Dock (EXC_BREAKPOINT via
  // addProcessForASN's separator-index bookkeeping). Clamp the forwarded index to
  // the current array bounds [0, count] so a desynced index appends instead of
  // trapping. Only touches the value when it is out of range, so normal inserts
  // are unaffected. Guarded by run-hide so the non-hiding path is byte-identical.
  NSInteger safeIndex = index;
  if (Hider_RunHideActive()) {
    NSUInteger cnt = Hider_TilesCount(self);
    if (cnt != (NSUInteger)-1) {
      if (safeIndex > (NSInteger)cnt) safeIndex = (NSInteger)cnt;
      if (safeIndex < 0) safeIndex = 0;
      if (safeIndex != index)
        LOG_TO_FILE("insertTile: clamped desynced index %ld -> %ld (count %lu)",
                    (long)index, (long)safeIndex, (unsigned long)cnt);
    }
  }
  if (g_orig_insertTile) g_orig_insertTile(self, _cmd, tile, safeIndex, reason);
}

static void Hider_SwizzleDockBarAddTile(void) {
  Class db = NSClassFromString(@"DockBar");
  if (!db) return;
  // insertTile:atIndex:forReason: is the single main-thread insertion chokepoint
  // for both launched and already-running hidden apps. It is where prevention
  // (skip the insert) happens.
  if (!g_orig_insertTile) {
    Method m = class_getInstanceMethod(
        db, NSSelectorFromString(@"insertTile:atIndex:forReason:"));
    if (m) {
      g_orig_insertTile =
          (void (*)(id, SEL, id, NSInteger, id))method_getImplementation(m);
      method_setImplementation(m, (IMP)Hider_InsertTileHook);
      LOG_TO_FILE("Hooked DockBar insertTile:atIndex:forReason:");
    }
  }
}


// Hang-proof circuit breaker. Any running-hide code path calls this before
// doing work; it counts operations per 1-second window and, if the rate spikes
// (a layout fight / feedback loop — the failure that HANGS the Dock, which the
// crash breadcrumb cannot catch because the process never exits), trips safe
// mode, restores every hidden tile, and returns NO so all further work stops.
// The Dock then settles and finishes launching WITHOUT a wedge — no sudo
// recovery needed. Rate-based so a long normal session never falsely trips.
static int g_runHideOpsWindow = 0;
static int g_runHideHotWindows = 0;
static CFTimeInterval g_runHideWindowStart = 0;
static void Hider_TripBreaker(const char *why, int n) {
  if (g_runHideSafeMode) return;
  g_runHideSafeMode = YES;
  LOG_TO_FILE("Running-hide CIRCUIT BREAKER tripped (%s=%d) — disabling", why, n);
  [[NSFileManager defaultManager]
      removeItemAtPath:@"/tmp/hider-run-hide" error:NULL];
}
static BOOL Hider_RunHideBudgetOK(void) {
  CFTimeInterval now = CACurrentMediaTime();
  if (now - g_runHideWindowStart > 1.0) {
    // Window boundary: log the rate (visibility: transient burst vs sustained
    // fight) and count consecutive "hot" windows. Trip only on a SUSTAINED
    // fight (tolerates launch-animation bursts).
    if (g_runHideOpsWindow > 50)
      LOG_TO_FILE("run-hide ops/window = %d (hot streak %d)",
                  g_runHideOpsWindow, g_runHideHotWindows);
    if (g_runHideOpsWindow > 400) g_runHideHotWindows++;
    else g_runHideHotWindows = 0;
    g_runHideWindowStart = now;
    g_runHideOpsWindow = 0;
    if (g_runHideHotWindows >= 3) { Hider_TripBreaker("sustained", g_runHideHotWindows); return NO; }
  }
  g_runHideOpsWindow++;
  // Hard hang-guard: a synchronous feedback loop that blocks the run loop would
  // pile ops into one window; cap it so the loop is broken and the Dock settles.
  if (g_runHideOpsWindow > 6000) { Hider_TripBreaker("hardcap", g_runHideOpsWindow); return NO; }
  return YES;
}

// Crash-loop breaker. Called before EVERY layer mutation (not once): keeps the
// breadcrumb present on disk throughout active mutation and for ~6s after the
// LAST mutation, so a hard fault (EXC_BAD_ACCESS/SIGBUS — NOT catchable by
// @try/@catch) at any point during our activity leaves the breadcrumb, and the
// next Dock launch (Hider_Init) detects it and enters safe mode. The clear is
// generation-gated so only the most recent arm's timer fires; scheduling is
// throttled to once/2s so a busy layout pass does not queue thousands of timers.
static BOOL Hider_IsDOCKProcessTile(id object) {
  if (!object) return NO;
  Class processTileClass = NSClassFromString(@"DOCKProcessTile");
  if (!processTileClass) return NO;
  @try {
    return [object isKindOfClass:processTileClass];
  } @catch (__unused NSException *exception) {
    return NO;
  }
}


// Hide sibling indicator/label layers that visually belong to the same tile.
// Modern Dock keeps DOCKIndicatorLayer/DOCKLabelLayer as siblings of tiles.
static void Hider_HideNeighborDecorations(CALayer *referenceLayer) {
  if (!referenceLayer || !referenceLayer.superlayer) return;
  CALayer *parent = referenceLayer.superlayer;
  CGFloat refMinX = CGRectGetMinX(referenceLayer.frame);
  CGFloat refMaxX = CGRectGetMaxX(referenceLayer.frame);
  CGFloat refMidX = CGRectGetMidX(referenceLayer.frame);
  BOOL refFrameValid = !CGRectIsEmpty(referenceLayer.frame);

  for (CALayer *sib in Hider_SublayersSnapshot(parent)) {
    if (sib == referenceLayer) continue;
    NSString *cn = NSStringFromClass([sib class]);
    BOOL isDecoration =
        [cn containsString:@"Indicator"] ||
        [cn containsString:@"LabelLayer"] ||
        [cn containsString:@"StatusLabel"];
    if (!isDecoration) continue;

    CGFloat sx = CGRectGetMidX(sib.frame);
    BOOL sibFrameValid = !CGRectIsEmpty(sib.frame);
    BOOL nearByX =
        (!refFrameValid || !sibFrameValid) ||
        (sx >= (refMinX - 90.0f) && sx <= (refMaxX + 90.0f)) ||
        (fabs(sx - refMidX) <= 96.0f);
    if (!nearByX) continue;

    [sib removeAllAnimations];
    sib.opacity = 0.0f;
    sib.hidden  = YES;
  }
}


// Recursively suppress indicator/label layers below a subtree root.
// Used after hiding a tile/slot to catch deferred indicator rebuilds.
static void Hider_HideIndicatorsRecursive(CALayer *root) {
  if (!root) return;
  NSString *cn = NSStringFromClass([root class]);
  BOOL isDecoration =
      [cn containsString:@"Indicator"] ||
      [cn containsString:@"LabelLayer"] ||
      [cn containsString:@"StatusLabel"];
  if (isDecoration) {
    [root removeAllAnimations];
    root.opacity = 0.0f;
    root.hidden  = YES;
  }
  for (CALayer *sub in Hider_SublayersSnapshot(root))
    Hider_HideIndicatorsRecursive(sub);
}

static void Hider_SuppressSlot(CALayer *tileLayer) {
  if (!tileLayer) return;
  CALayer *slot = tileLayer.superlayer;
  if (!slot) return;

  // If tile is attached directly under a floor-layer path, suppress the tile
  // itself (and nearby decorations) rather than early-returning.
  BOOL slotLooksLikeFloor = (slot == g_modernFloorLayer || slot == g_legacyFloorLayer ||
                             [NSStringFromClass([slot class]) containsString:@"FloorLayer"]);
  if (slotLooksLikeFloor) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [tileLayer removeAllAnimations];
    tileLayer.opacity = 0.0f;
    tileLayer.hidden  = YES;
    for (CALayer *sub in Hider_SublayersSnapshot(tileLayer)) {
      [sub removeAllAnimations];
      sub.opacity = 0.0f;
      sub.hidden  = YES;
    }
    Hider_HideIndicatorsRecursive(tileLayer);
    Hider_HideNeighborDecorations(tileLayer);
    [CATransaction commit];
    return;
  }

  objc_setAssociatedObject(slot, &kHiderSlotSuppressed, @YES,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  slot.opacity = 0.0f;
  slot.hidden  = YES;
  for (CALayer *sibling in Hider_SublayersSnapshot(slot)) {
    [sibling removeAllAnimations];
    sibling.opacity = 0.0f;
    sibling.hidden  = YES;
  }
  Hider_HideIndicatorsRecursive(slot);
  Hider_HideNeighborDecorations(tileLayer);
  [CATransaction commit];
}

// Collect root layers from every reachable source:
//   1. [NSApp windows]  (may be empty on modern Dock)
//   2. _orderedWindows  (private NSApplication API)
//   3. g_modernFloorLayer / g_legacyFloorLayer root chain
//   4. Layer of every tracked tile in g_customAppTileObjects
// De-duplicated by pointer identity.
static NSArray<CALayer *> *Hider_CollectRootLayers(void) {
  NSMutableSet *seen = [NSMutableSet set];
  NSMutableArray<CALayer *> *roots = [NSMutableArray array];

  void (^addRoot)(CALayer *) = ^(CALayer *r) {
    if (!r) return;
    while (r.superlayer) r = r.superlayer;
    NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)r];
    if (![seen containsObject:ptr]) {
      [seen addObject:ptr];
      [roots addObject:r];
    }
  };

  // Source 1: public NSApp windows.
  for (NSWindow *w in [NSApp windows]) {
    addRoot(w.contentView.layer);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    SEL rlSel = NSSelectorFromString(@"_rootLayer");
    if ([w respondsToSelector:rlSel])
      addRoot([w performSelector:rlSel]);
#pragma clang diagnostic pop
  }

  // Source 2: private _orderedWindows (catches Dock windows hidden from public API).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  SEL owSel = NSSelectorFromString(@"_orderedWindows");
  if ([[NSApplication sharedApplication] respondsToSelector:owSel]) {
    NSArray *privWins = [[NSApplication sharedApplication] performSelector:owSel];
    for (id w in privWins) {
      if ([w isKindOfClass:[NSWindow class]]) {
        addRoot(((NSWindow *)w).contentView.layer);
        SEL rlSel = NSSelectorFromString(@"_rootLayer");
        if ([w respondsToSelector:rlSel])
          addRoot([w performSelector:rlSel]);
      }
    }
  }
#pragma clang diagnostic pop

  // Source 3: tracked floor layers → walk up to root.
  addRoot(g_modernFloorLayer);
  addRoot(g_legacyFloorLayer);

  // Source 4: Finder / Trash tile objects → layer → root.
  void (^addTileRoot)(id) = ^(id tile) {
    if (!tile) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if ([tile isKindOfClass:[CALayer class]])
      addRoot((CALayer *)tile);
    else if ([tile respondsToSelector:@selector(layer)])
      addRoot([tile performSelector:@selector(layer)]);
#pragma clang diagnostic pop
  };
  addTileRoot(g_finderTileObject);
  addTileRoot(g_trashTileObject);

  // Source 6: when no roots yet, recursively walk key/main window view tree.
  // Catches Dock layouts where floor layers or window contentView aren't ready.
  if (roots.count == 0) {
    NSMutableArray *stack = [NSMutableArray array];
    NSWindow *kw = [NSApp keyWindow];
    NSWindow *mw = [NSApp mainWindow];
    if (kw && kw.contentView) [stack addObject:kw.contentView];
    if (mw && mw != kw && mw.contentView) [stack addObject:mw.contentView];
    while (stack.count > 0) {
      NSView *v = [stack lastObject];
      [stack removeLastObject];
      if (v.layer) addRoot(v.layer);
      for (NSView *sub in [v.subviews copy])
        [stack addObject:sub];
    }
  }

  return roots;
}

// Force an immediate, animation-free relayout so the Finder/Trash/separator
// layer-visibility rules (Hider_ApplyVisibilityRecursive → ShouldForceHideLayer
// / HideFloorSeparators) re-apply. The trash-hide sequence calls this after
// removing the trash tile so the now-rightmost separator gets hidden in the
// same frame. Running apps need no work here — prevention keeps their tiles out
// of the model entirely.
static void Hider_ApplyLayerVisibility(void) {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];

  Hider_TriggerLayoutOnTrackedLayers();

  for (CALayer *root in Hider_CollectRootLayers()) {
    Hider_ApplyVisibilityRecursive(root);
    Hider_ForceLayoutRecursive(root);
  }

  [CATransaction commit];
  [CATransaction flush];

  // NSView layout burst so SwiftUI reconciles.
  for (NSWindow *w in [NSApp windows]) {
    if (w.contentView) {
      Hider_WalkNSViewsForLayout(w.contentView);
      [w.contentView layoutSubtreeIfNeeded];
    }
  }
}

// Immediately apply hidden-app settings to both:
//   1) persistent Dock tiles (via Hider_RefreshDock caller), and
//   2) already-running apps that may currently own transient/running tiles.
// Called from settings-changed flow with short retries for SwiftUI/Dock timing.
#pragma mark - Floor Layer Hiding

static void Hider_HideFloorSeparators(CALayer *layer) {
  if (!layer)
    return;

  // separatorMode: 0=keep, 1=remove, 2=auto
  if (g_separatorMode == 0 && !g_hideSeparators && !g_deferSeparatorRestore) {
    return;
  }

  BOOL hideAll = g_hideSeparators || (g_separatorMode == 1);
  BOOL hideRightmostOnly = (g_separatorMode == 2) &&
                          (g_trashHidden || g_deferSeparatorRestore);

  // In auto mode with trash hidden: only hide the rightmost separator (the one
  // left of the Trash).  Find it by max position (rightmost in layout).
  CALayer *rightmostSeparator = nil;
  if (hideRightmostOnly) {
    CGFloat maxRight = -CGFLOAT_MAX;
    for (CALayer *sub in Hider_SublayersSnapshot(layer)) {
      NSString *subClass = NSStringFromClass([sub class]);
      if ([subClass containsString:@"Indicator"])
        continue;
      if (sub.frame.size.width > 0 && sub.frame.size.width < 15) {
        CGFloat right = sub.frame.origin.x + sub.frame.size.width;
        if (right > maxRight) {
          maxRight = right;
          rightmostSeparator = sub;
        }
      }
    }
  }

  for (CALayer *sub in Hider_SublayersSnapshot(layer)) {
    NSString *subClass = NSStringFromClass([sub class]);
    if ([subClass containsString:@"Indicator"])
      continue;
    if (sub.frame.size.width > 0 && sub.frame.size.width < 15) {
      BOOL shouldHide = hideAll ? YES : (hideRightmostOnly && (sub == rightmostSeparator));
      if (hideRightmostOnly && !shouldHide) {
        if (sub.hidden) {
          [sub setHidden:NO];
          [sub setOpacity:1.0f];
        }
        continue;
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
    if (Hider_ShouldForceHideLayer(layer)) {
      [layer removeAllAnimations];
      layer.hidden  = YES;
      layer.opacity = 0.0f;
      Hider_SuppressSlot(layer);
      Hider_HideNeighborDecorations(layer);
    } else if (Hider_IsSlotSuppressed(layer) ||
               Hider_IsSlotSuppressed(layer.superlayer)) {
      // Already suppressed by PID discovery — keep it hidden.
      [layer removeAllAnimations];
      layer.hidden  = YES;
      layer.opacity = 0.0f;
      Hider_HideNeighborDecorations(layer);
    }
    return;
  }

  if ([cn containsString:@"FloorLayer"])
    Hider_HideFloorSeparators(layer);

  for (CALayer *sub in Hider_SublayersSnapshot(layer))
    Hider_ApplyVisibilityRecursive(sub);
}

// Walk the layer tree looking for a DOCKTileLayer whose tile model matches
// the running application by process ID.  When found:
//   1. Register tile model in g_customAppTileObjects (so reverse-lookup works
//      forever after — including in setHidden: and layoutSublayers).
//   2. Immediately suppress the layer's visual output.
// This is the authoritative fallback when Hider_GetBundleID fails for the
// tile's model object (e.g. a private Swift Dock class with no ObjC selectors).
// Immediately zero out the visual output of a tile object and cancel all
// in-flight animations on its layer tree.
//
// MUST be called AFTER the original -update/-init IMP so that any animation
// the Dock added during that call is already present on the layer (and can
// therefore be removed with removeAllAnimations).  Calling it before the IMP
// is useless — the IMP re-enables the layer and queues new animations.
//
// The removeAllAnimations call kills the bounce-in CAAnimation before the
// run-loop ever renders its first frame, which is what lets doCommand:1004
// be called later without the Dock crashing on a live animation.
void Hider_ForceLayoutRecursive(CALayer *layer) {
  if (!layer)
    return;
  // Only invalidate layout — never setNeedsDisplay.  DOCKTileLayer renders
  // its content through the compositor pipeline (layer.contents), not via
  // drawInContext:.  Calling setNeedsDisplay triggers drawInContext: which
  // produces a blank frame and makes every tile invisible.
  [layer setNeedsLayout];
  for (CALayer *sub in Hider_SublayersSnapshot(layer))
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

  for (CALayer *sublayer in Hider_SublayersSnapshot(layer)) {
    Hider_DumpLayer(sublayer, depth + 1, output);
  }
}

void Hider_DumpDockHierarchy(void) {
  LOG_TO_FILE("Dumping Dock Layer Hierarchy...");
  NSMutableString *output = [NSMutableString string];
  [output appendString:@"Dock CALayer Hierarchy Dump\n"];
  [output appendFormat:@"Timestamp: %@\n", [NSDate date]];
  [output appendString:@"========================================\n\n"];

  // Use the unified root-layer collection so we see the same tree as enforcement.
  NSArray<CALayer *> *roots = Hider_CollectRootLayers();
  [output appendFormat:@"Root layers found: %lu\n\n", (unsigned long)roots.count];
  LOG_TO_FILE("Dump: found %lu root layers", (unsigned long)roots.count);

  for (NSUInteger ri = 0; ri < roots.count; ri++) {
    CALayer *rootLayer = roots[ri];
    [output appendFormat:@"Root %lu: %@ (%p)\n", (unsigned long)ri,
                         NSStringFromClass([rootLayer class]),
                         (void *)rootLayer];
    [output appendString:@"----------------------------------------\n"];
    Hider_DumpLayer(rootLayer, 0, output);
    [output appendString:@"\n"];
  }

  [output appendFormat:@"g_hiddenAppBundleIDs: %@\n", g_hiddenAppBundleIDs];

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

  // Separators: independent toggle (decoupled from Trash) via the
  // hideSeparators pref. Mode 1 = explicitly remove separators; 0 = keep.
  g_hideSeparators = (BOOL)CFPreferencesGetAppBooleanValue(
      CFSTR("hideSeparators"), CFSTR("com.aspauldingcode.hider"), &keyExists);
  if (!keyExists) g_hideSeparators = NO;
  g_separatorMode = g_hideSeparators ? 1 : 0;

  // Custom hidden apps
  Hider_LoadCustomAppsFromPrefs();

  LOG_TO_FILE("Settings: Finder=%d, Trash=%d, customApps=%lu (separators=auto)",
              g_finderHidden, g_trashHidden,
              (unsigned long)g_hiddenAppBundleIDs.count);
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

  // Separators: independent toggle (decoupled from Trash) via the
  // hideSeparators pref. Mode 1 = explicitly remove separators; 0 = keep.
  g_hideSeparators = (BOOL)CFPreferencesGetAppBooleanValue(
      CFSTR("hideSeparators"), CFSTR("com.aspauldingcode.hider"), &keyExists);
  if (!keyExists) g_hideSeparators = NO;
  g_separatorMode = g_hideSeparators ? 1 : 0;

  // Update custom hidden-apps set from cache (no disk sync, allocation-light
  // because CFPreferences caches the plist in memory).
  Hider_LoadCustomAppsFromCache();
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
  // Darwin notification (older macOS path)
  notify_post("com.apple.dock.preferencesCached");
  // Distributed notification — the most reliable way to tell the Dock to
  // re-read its preferences from disk; works even when CoreDock is unavailable.
  [[NSDistributedNotificationCenter defaultCenter]
      postNotificationName:@"com.apple.dock.prefschanged"
                    object:nil
                  userInfo:nil
        deliverImmediately:YES];
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
  // Independent of Trash now: separators are removed only when the user turns on
  // the dedicated hideSeparators toggle (g_hideSeparators / mode 1), never as a
  // side effect of hiding Trash.
  return g_hideSeparators ||
         (g_separatorMode == 1) ||
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
  // Auto mode (g_separatorMode == 2, triggered by g_trashHidden): only the
  // built-in DOCKSeparatorTile (rightmost, left of Trash) is hidden and
  // removed from the dock.  User-added spacer tiles are never modified.
  // Explicit mode (g_separatorMode == 1) retains the full prefs-removal path.
  if (shouldRemoveSeparators && !prevShouldRemoveSeps) {
    if (g_separatorMode == 1 || g_hideSeparators) {
      Hider_RemoveSeparatorsFromPrefs();
    }
  } else if (!shouldRemoveSeparators && prevShouldRemoveSeps) {
    // Keep the floor separator / DOCKSeparatorTile hidden in this session
    // until the user restarts the Dock.
    g_deferSeparatorRestore = YES;
  }

  // ── Custom hidden apps ────────────────────────────────────────────────────
  // Step 1: remove hidden apps from com.apple.dock persistent-apps so the Dock
  // model no longer contains them after the prefs-changed notification below.
  if (g_hiddenAppBundleIDs.count > 0) {
    CFArrayRef rawApps = CFPreferencesCopyAppValue(
        CFSTR("persistent-apps"), CFSTR("com.apple.dock"));
    if (rawApps) {
      NSArray *dockItems = (__bridge_transfer NSArray *)rawApps;
      NSMutableArray *filtered =
          [NSMutableArray arrayWithCapacity:dockItems.count];
      for (id item in dockItems) {
        NSString *bid = nil;
        if ([item isKindOfClass:[NSDictionary class]]) {
          NSDictionary *td = item[@"tile-data"];
          bid = td[@"bundle-identifier"];
        }
        NSString *normalizedBid = bid ? Hider_NormalizeBundleID(bid) : nil;
        if (normalizedBid && [g_hiddenAppBundleIDs containsObject:normalizedBid]) {
          LOG_TO_FILE("Removing hidden app from persistent-apps: %@", bid);
          continue;
        }
        [filtered addObject:item];
      }
      if (filtered.count != dockItems.count) {
        CFPreferencesSetAppValue(CFSTR("persistent-apps"),
                                 (__bridge CFArrayRef)filtered,
                                 CFSTR("com.apple.dock"));
        CFPreferencesAppSynchronize(CFSTR("com.apple.dock"));
      }
    }
  }

  // Running apps in the hidden set need no per-refresh suppression here: they
  // are removed from persistent-apps above (Step 1) and PREVENTION refuses
  // their tile on the Dock rebuild this refresh triggers. Nothing to enforce.

  // ── Notify Dock to reconcile ─────────────────────────────────────────────
  Hider_PostDockPrefsChangedNotification();

  // Staggered sequence when hiding trash: 1) trash invisible (layout above),
  // 2) remove trash tile, 3) rightmost separator invisible (layout), 4) remove
  // rightmost separator tile only.
  if (trashBecameHidden && g_trashTileObject) {
    id trashTile = g_trashTileObject;
    const int step2Ms = 60;
    const int step4Ms = 120;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(step2Ms * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      SEL d = NSSelectorFromString(@"doCommand:");
      SEL pc = NSSelectorFromString(@"performCommand:");
      // Capture trash frame in a common coordinate system before removing.
      // Use trash's window contentView so all tiles convert to the same space.
      NSView *refView = nil;
      if ([trashTile isKindOfClass:[NSView class]]) {
        refView = [(NSView *)trashTile window].contentView;
      } else if ([trashTile isKindOfClass:[CALayer class]]) {
        id del = [(CALayer *)trashTile delegate];
        if ([del isKindOfClass:[NSView class]])
          refView = [(NSView *)del window].contentView;
      }
      CGRect trashFrame = CGRectZero;
      if ([trashTile isKindOfClass:[NSView class]] && refView) {
        trashFrame = [(NSView *)trashTile convertRect:[(NSView *)trashTile bounds] toView:refView];
      } else if ([trashTile isKindOfClass:[CALayer class]] && refView) {
        CALayer *trashLayer = (CALayer *)trashTile;
        id del = trashLayer.delegate;
        if ([del isKindOfClass:[NSView class]])
          trashFrame = [(NSView *)del convertRect:trashLayer.bounds toView:refView];
      }
      BOOL useHorizontal = (trashFrame.size.width >= trashFrame.size.height);
      // 2. Remove trash dock tile
      if ([trashTile respondsToSelector:d])
        ((void (*)(id, SEL, int))objc_msgSend)(trashTile, d, 1004);
      // 3. Trigger layout so rightmost separator gets hidden
      Hider_ApplyLayerVisibility();
      // 4. Remove only the rightmost live DOCKSeparatorTile.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((step4Ms - step2Ms) * NSEC_PER_MSEC)),
                     dispatch_get_main_queue(), ^{
                       id rightmost = nil;
                       CGFloat maxRight = -CGFLOAT_MAX;
                       for (id tile in g_separatorTileObjects) {
                         if (![NSStringFromClass([tile class]) isEqualToString:@"DOCKSeparatorTile"])
                           continue;
                         NSView *tileView = nil;
                         if ([tile isKindOfClass:[NSView class]]) {
                           tileView = (NSView *)tile;
                         } else if ([tile isKindOfClass:[CALayer class]]) {
                           id del = [(CALayer *)tile delegate];
                           if ([del isKindOfClass:[NSView class]])
                             tileView = (NSView *)del;
                         }
                         if (!tileView || !refView || tileView.window != refView.window)
                           continue;
                         CGRect frame = [tileView convertRect:tileView.bounds toView:refView];
                         if (CGRectIsEmpty(frame))
                           continue;
                         CGFloat key = useHorizontal ? CGRectGetMaxX(frame)
                                                     : CGRectGetMaxY(frame);
                         if (key > maxRight) {
                           maxRight = key;
                           rightmost = tile;
                         }
                       }
                       if (!rightmost) {
                         for (id tile in [g_separatorTileObjects reverseObjectEnumerator]) {
                           if ([NSStringFromClass([tile class]) isEqualToString:@"DOCKSeparatorTile"]) {
                             rightmost = tile;
                             break;
                           }
                         }
                       }
                       if (rightmost) {
                         if ([rightmost respondsToSelector:d])
                           ((void (*)(id, SEL, int))objc_msgSend)(rightmost, d, 1004);
                         else {
                           id del = [rightmost respondsToSelector:@selector(delegate)]
                                       ? [rightmost performSelector:@selector(delegate)]
                                       : nil;
                           if (del && [del respondsToSelector:pc])
                             ((void (*)(id, SEL, int))objc_msgSend)(del, pc, 1004);
                         }
                       }
                     });
                   });
#pragma clang diagnostic pop
  }

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

  // setHidden: — use Hider_ShouldForceHideLayer for unified logic.
  SEL setHiddenSel = @selector(setHidden:);
  Method originalSetHidden = class_getInstanceMethod(cls, setHiddenSel);
  if (originalSetHidden) {
    __block IMP originalIMP = method_getImplementation(originalSetHidden);
    void (^block)(id, BOOL) = ^(id self, BOOL hidden) {
      BOOL shouldHide = Hider_ShouldForceHideLayer((CALayer *)self);

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
        Hider_SuppressSlot((CALayer *)self);
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

  // setOpacity: — use Hider_ShouldForceHideLayer (includes reverse-lookup).
  SEL setOpacitySel = @selector(setOpacity:);
  Method originalSetOpacity = class_getInstanceMethod(cls, setOpacitySel);
  if (originalSetOpacity) {
    __block IMP originalIMP = method_getImplementation(originalSetOpacity);
    void (^block)(id, float) = ^(id self, float opacity) {
      BOOL forceZero = Hider_ShouldForceHideLayer((CALayer *)self);
      ((void (*)(id, SEL, float))originalIMP)(self, setOpacitySel,
                                             forceZero ? 0.0f : opacity);
    };
    Hider_SwizzleInstanceMethod(cls, setOpacitySel,
                                NSSelectorFromString(@"hider_setOpacity:"),
                                imp_implementationWithBlock(block));
  }

  // drawInContext: — suppress drawing for force-hidden tiles and separators.
  SEL drawInContextSel = @selector(drawInContext:);
  Method originalDrawInContext = class_getInstanceMethod(cls, drawInContextSel);
  if (originalDrawInContext) {
    __block IMP originalIMP = method_getImplementation(originalDrawInContext);
    void (^block)(id, CGContextRef) = ^(id self, CGContextRef ctx) {
      if (Hider_ShouldForceHideLayer((CALayer *)self)) {
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

  // layoutSublayers — authoritative render pass.
  SEL layoutSublayersSel = @selector(layoutSublayers);
  Method originalLayout = class_getInstanceMethod(cls, layoutSublayersSel);
  if (originalLayout) {
    __block IMP originalLayoutIMP = method_getImplementation(originalLayout);
    void (^layoutBlock)(id) = ^(id self) {
      ((void (*)(id, SEL))originalLayoutIMP)(self, layoutSublayersSel);
      Hider_LoadSettingsFromCache();

      if (Hider_ShouldForceHideLayer((CALayer *)self)) {
        [(CALayer *)self setHidden:YES];
        [(CALayer *)self setOpacity:0.0f];
        Hider_SuppressSlot((CALayer *)self);
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

    // Enforce suppressed slot containers (indicator dot hiding).
    if ([self isKindOfClass:[CALayer class]] && Hider_IsSlotSuppressed((CALayer *)self)) {
      ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, YES);
      in_swizzle = NO;
      return;
    }

    if ([NSStringFromClass([self class]) isEqualToString:@"DOCKTileLayer"]) {
      if (Hider_ShouldForceHideLayer((CALayer *)self)) {
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

  // setOpacity: — enforce slot suppression + custom-app zero.
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
      // Suppressed slot containers must stay at zero.
      if ([self isKindOfClass:[CALayer class]] && Hider_IsSlotSuppressed((CALayer *)self)) {
        ((void (*)(id, SEL, float))origOp)(self, setOpacitySel, 0.0f);
        in_op_swizzle = NO;
        return;
      }
      // DOCKTileLayer: use unified query (includes reverse-lookup).
      if ([NSStringFromClass([self class]) isEqualToString:@"DOCKTileLayer"]) {
        if (Hider_ShouldForceHideLayer((CALayer *)self)) {
          ((void (*)(id, SEL, float))origOp)(self, setOpacitySel, 0.0f);
          in_op_swizzle = NO;
          return;
        }
      }
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
      if ([self isKindOfClass:[CALayer class]] && Hider_ShouldForceHideLayer((CALayer *)self)) {
        CGRect rect = CGContextGetClipBoundingBox(ctx);
        CGContextClearRect(ctx, rect);
        return;
      }
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

  // layoutSublayers — unified with Hider_ShouldForceHideLayer + slot suppression.
  SEL layoutSublayersSel = @selector(layoutSublayers);
  Method originalLayout = class_getInstanceMethod(cls, layoutSublayersSel);
  if (originalLayout) {
    __block IMP originalLayoutIMP = method_getImplementation(originalLayout);
    void (^layoutBlock)(id) = ^(id self) {
      ((void (*)(id, SEL))originalLayoutIMP)(self, layoutSublayersSel);

      NSString *cn = NSStringFromClass([self class]);
      if ([cn isEqualToString:@"DOCKTileLayer"]) {
        if (Hider_ShouldForceHideLayer((CALayer *)self)) {
          [(CALayer *)self setHidden:YES];
          [(CALayer *)self setOpacity:0.0f];
          Hider_SuppressSlot((CALayer *)self);
        }
      } else if (g_hideSeparators && Hider_IsSeparatorTileLayer(self)) {
        [(CALayer *)self setHidden:YES];
        [(CALayer *)self setOpacity:0.0f];
      }

      if ([cn containsString:@"FloorLayer"] || [cn containsString:@"Container"]) {
        Hider_HideFloorSeparators((CALayer *)self);
      }
    };
    Hider_SwizzleInstanceMethod(cls, layoutSublayersSel,
                                NSSelectorFromString(@"hider_layer_layoutSublayers:"),
                                imp_implementationWithBlock(layoutBlock));
  }

  // addAnimation:forKey: — block animations that would bring a suppressed
  // slot or hidden DOCKTileLayer back to visible state.
  SEL addAnimSel = @selector(addAnimation:forKey:);
  Method addAnimM = class_getInstanceMethod(cls, addAnimSel);
  if (addAnimM) {
    __block IMP origAddAnim = method_getImplementation(addAnimM);
    void (^addAnimBlock)(id, CAAnimation *, NSString *) =
        ^(id self, CAAnimation *anim, NSString *key) {
      if ([self isKindOfClass:[CALayer class]]) {
        CALayer *layer = (CALayer *)self;
        if (Hider_IsSlotSuppressed(layer)) return;
        if ([NSStringFromClass([layer class]) isEqualToString:@"DOCKTileLayer"] &&
            Hider_ShouldForceHideLayer(layer)) {
          return;
        }
      }
      ((void (*)(id, SEL, CAAnimation *, NSString *))origAddAnim)(
          self, addAnimSel, anim, key);
    };
    Hider_SwizzleInstanceMethod(
        cls, addAnimSel, NSSelectorFromString(@"hider_layer_addAnimation:forKey:"),
        imp_implementationWithBlock(addAnimBlock));
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
      if (Hider_IsFinder(bundleID) && g_finderHidden)    forceHide = YES;
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
      BOOL forceZero = (g_hideSeparators && Hider_IsSeparatorTileLayer(self));
      if (!forceZero) {
        NSString *bid = Hider_GetBundleID(self);
        if (bid) {
          if (Hider_IsFinder(bid) && g_finderHidden)       forceZero = YES;
          else if (Hider_IsTrash(bid) && g_trashHidden)    forceZero = YES;
        }
      }
      if (forceZero)
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
    NSString *bundleID = Hider_GetBundleID(self);

    if (bundleID && Hider_IsFinder(bundleID)) {
      g_finderTileObject = self;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      Hider_RunOnce(self, "Hider_FileTile_Finder_Remove", ^{
        SEL pc = NSSelectorFromString(@"performCommand:");
        if (g_finderHidden && [self respondsToSelector:pc])
          ((void (*)(id, SEL, int))objc_msgSend)(self, pc, 1004);
      });
#pragma clang diagnostic pop
    }

    // Call the original IMP first — it may add animations to the tile layer.
    id result = nil;
    if (updateSel == @selector(init)) {
      result = ((id(*)(id, SEL))originalIMP)(self, updateSel);
    } else {
      ((void (*)(id, SEL))originalIMP)(self, updateSel);
    }

    // Retry bundle-ID probe after originalIMP when the tile is fully set up.
    if (!bundleID) {
      bundleID = Hider_GetBundleID(self);
      if (bundleID && Hider_IsFinder(bundleID))
        g_finderTileObject = self;
    }

    return result;
  };
  class_replaceMethod(cls, updateSel, imp_implementationWithBlock(block),
                      method_getTypeEncoding(originalMethod));
}

static void swizzleDOCKSpacerTile(Class cls) {
  // Determine once at swizzle time: DOCKSeparatorTile is the built-in
  // irremovable section divider between persistent-apps and persistent-others
  // (left of Trash). DOCKSpacerTile is a user-added spacer — never touched.
  BOOL isSeparatorTile = strcmp(class_getName(cls), "DOCKSeparatorTile") == 0;

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
          if (!isSeparatorTile) {
            ((void (*)(id, SEL, BOOL))origSH)(self, setHiddenSel, h);
            return;
          }
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
            if (isSeparatorTile &&
                (g_hideSeparators ||
                 (g_separatorMode == 2 && g_trashHidden) ||
                 g_deferSeparatorRestore))
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
            if (isSeparatorTile &&
                (g_hideSeparators ||
                 (g_separatorMode == 2 && g_trashHidden) ||
                 g_deferSeparatorRestore)) {
              /* suppress built-in separator drawing */
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
          if (isSeparatorTile &&
              (g_hideSeparators ||
               (g_separatorMode == 2 && g_trashHidden) ||
               g_deferSeparatorRestore)) {
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

// Request tile removal with immediate+retry passes.
// This is centralized so every detection path (update/init, bundleIdentifier,
// fileURL, lifecycle state hooks) can trigger the same robust remove flow.
// Helper: if `tile` is a hidden custom app, immediately suppress and remove.
// Uses three resolution paths: associated-object tag → Hider_GetBundleID →
// PID-based fallback via Hider_ResolveBundleIDByPID.
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

// Crash-loop guard. A crash on our code (e.g. an insertTile prevention trap
// during a relaunch's addProcessForASN storm) makes launchd relaunch the Dock,
// which re-runs us, which can crash again — a wedge that leaves the Dock down.
// We must catch that WITHOUT false-positiving on INTENTIONAL relaunches (a
// hide/unhide, or a burst of toggles, auto-relaunches the Dock — sometimes
// several times in quick succession, faster than any survival window).
// So the controller (GUI/CLI) drops /tmp/hider-intentional-restart right before
// it kills the Dock: if this launch follows that marker it is intentional, so we
// consume the marker, RESET the counter, and exempt the launch. A real crash
// leaves no marker, so it still counts; each launch bumps /tmp/hider-launch-count
// and a 12s survival timer clears it, and at the limit we enter safe mode and
// disable the opt-in so the Dock comes up clean. Returns YES if it tripped.
static BOOL Hider_CrashLoopGuard(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *countPath = @"/tmp/hider-launch-count";
  NSString *markerPath = @"/tmp/hider-intentional-restart";
  if ([fm fileExistsAtPath:markerPath]) {
    NSDate *when = [[fm attributesOfItemAtPath:markerPath error:NULL]
        fileModificationDate];
    [fm removeItemAtPath:markerPath error:NULL];  // one-shot: consume it
    if (when && [[NSDate date] timeIntervalSinceDate:when] < 30.0) {
      [fm removeItemAtPath:countPath error:NULL];  // intentional -> reset
      return NO;
    }
  }
  NSInteger count =
      [[NSString stringWithContentsOfFile:countPath
                                 encoding:NSUTF8StringEncoding
                                    error:NULL] integerValue] +
      1;
  [[NSString stringWithFormat:@"%ld", (long)count]
      writeToFile:countPath
       atomically:YES
         encoding:NSUTF8StringEncoding
            error:NULL];
  if (count >= 3) {
    g_runHideSafeMode = YES;
    CFPreferencesSetAppValue(CFSTR("hideRunningApps"), kCFBooleanFalse,
                             CFSTR("com.aspauldingcode.hider"));
    CFPreferencesAppSynchronize(CFSTR("com.aspauldingcode.hider"));
    [fm removeItemAtPath:@"/tmp/hider-run-hide" error:NULL];
    [fm removeItemAtPath:countPath error:NULL];
    LOG_TO_FILE("CRASH-LOOP GUARD: %ld launches without surviving -> SAFE MODE, "
                "running-app hiding disabled",
                (long)count);
    return YES;
  }
  int64_t gen = ++g_launchGen;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (gen != g_launchGen) return;  // superseded
                   [[NSFileManager defaultManager] removeItemAtPath:countPath
                                                              error:NULL];
                 });
  return NO;
}

__attribute__((constructor)) static void Hider_Init(void) {
  @autoreleasepool {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.apple.dock"])
      return;

    Hider_CrashLoopGuard();

    LOG_TO_FILE("Hider_Init: starting");

    Hider_LoadSettings();
    swizzleDockCoreClasses();
    swizzleCALayer();
    swizzleNSView();
    Hider_SwizzleDockBarAddTile();  // prevention: refuse tiles for hidden apps

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
                // RefreshDock applies Finder/Trash/separator prefs AND re-runs
                // the hidden-app enforcement pass. Running apps are hidden by
                // PREVENTION on the Dock rebuild that every supported apply path
                // triggers, so no separate hotload is needed here.
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

    // Hidden RUNNING apps need no NSWorkspace launch/activate/deactivate
    // observers: PREVENTION (the insertTile hook) refuses a hidden app's tile
    // on every path it could enter the model — a fresh launch
    // (_handleLaunchNotification) and a Dock rebuild (addProcessForASN) — so the
    // tile never exists to re-show on activation. Verified: launching a hidden
    // app while the Dock is up logs an insertTile SKIP for both reasons and the
    // tile never appears.

    LOG_TO_FILE("Hider_Init: complete");
  }
}

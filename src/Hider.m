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

// Custom hidden apps (populated from SettingsManager "hiddenApps" pref array).
// All bundle IDs stored here are normalized (lowercased + trimmed).
static NSSet   *g_hiddenAppBundleIDs   = nil;
static NSSet   *g_prevHiddenAppBundleIDs = nil;
// Tile objects for custom hidden apps: normalized-bundleID → tile model object.
static NSMutableDictionary *g_customAppTileObjects = nil;
// Key used by Hider_RunOnce to mark that doCommand:1004 was sent for a tile.
static const char kHiderCustomAppRemoveKey = '\0';

// Associated-object keys for tagging individual tile/layer objects with
// durable per-object state that survives across swizzle hops.
// - kHiderBundleIDTag: attached to tile-model objects → their normalized
//   bundle ID. Used by layer hooks for reverse-lookup when Hider_GetBundleID
//   cannot resolve the bundle ID from the layer directly.
// - kHiderSlotSuppressed: attached to slot-container CALayers → @YES when
//   the slot is actively suppressed. Enforced in setHidden:/setOpacity:
//   swizzles so the Dock cannot restore visibility.
static const char kHiderBundleIDTag;
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
static void Hider_RegisterTile(id tile, NSString *bid);

// Resolve the bundle ID for a DOCKTileLayer, trying Hider_GetBundleID first,
// then the associated-object tag on the delegate, then g_customAppTileObjects
// pointer-comparison fallback.
static NSString *Hider_ResolveBundleIDForLayer(CALayer *layer);

// Resolve hidden-app bundle ID from tile delegate's PID (fallback).
static NSString *Hider_ResolveBundleIDByPID(id delegate);

// Single-point query: should this DOCKTileLayer be force-hidden?
static BOOL Hider_ShouldForceHideLayer(CALayer *layer);

// Slot-container suppression: tag a slot layer and hide it and all siblings.
static void Hider_SuppressSlot(CALayer *tileLayer);
static void Hider_UnsuppressSlot(CALayer *slot);
static BOOL Hider_IsSlotSuppressed(CALayer *layer);

// Unified enforcement: discover tiles, suppress, remove across all windows.
static void Hider_EnforceHiddenApps(NSString * _Nullable singleBID, pid_t pid);
// Hotload hidden-app list changes immediately.
static void Hider_HotloadHiddenAppsNow(void);

// Execution guard
void Hider_RunOnce(id object, const void *key, void (^block)(void));

// Layout helpers
static void Hider_ApplyEdgeTileVisibility(CALayer *parent);
void Hider_ForceLayoutRecursive(CALayer *layer);
static void Hider_ApplyVisibilityRecursive(CALayer *layer);
static void Hider_SuppressTileRender(id tile);
static void Hider_TriggerLayoutOnTrackedLayers(void);
static void Hider_WalkNSViewsForLayout(NSView *view);

// Suppress a tile-model's visual output if it belongs to a hidden custom app.
static void Hider_SuppressIfHidden(id tile);
// Remove a hidden tile immediately with retries.
static void Hider_RequestTileRemoval(id tile);

// PID-based tile discovery (fallback for when Hider_GetBundleID fails)
static void Hider_DiscoverTileByPID(CALayer *layer, NSString *bid, pid_t pid);

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

static void Hider_RegisterTile(id tile, NSString *bid) {
  if (!tile || !bid) return;
  NSString *normalized = Hider_NormalizeBundleID(bid);
  if (!normalized || normalized.length == 0) return;

  // Tag the tile model with its bundleID for layer-hook reverse-lookup.
  objc_setAssociatedObject(tile, &kHiderBundleIDTag, normalized,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  if (!g_customAppTileObjects)
    g_customAppTileObjects = [NSMutableDictionary dictionary];
  g_customAppTileObjects[normalized] = tile;
}

static NSString *Hider_ResolveBundleIDForLayer(CALayer *layer) {
  if (!layer) return nil;

  // Fast path: direct probe.
  NSString *bid = Hider_GetBundleID(layer);
  if (bid) return Hider_NormalizeBundleID(bid);

  // Reverse-lookup via associated-object tag on the delegate.
  id delegate = layer.delegate;
  if (delegate) {
    bid = objc_getAssociatedObject(delegate, &kHiderBundleIDTag);
    if (bid) return bid;
  }

  // Pointer-comparison fallback through g_customAppTileObjects.
  if (delegate && g_customAppTileObjects && g_hiddenAppBundleIDs.count > 0) {
    NSSet *hiddenSnap = [g_hiddenAppBundleIDs copy];
    for (NSString *trackedBid in hiddenSnap) {
      if (g_customAppTileObjects[trackedBid] == delegate)
        return trackedBid;
    }
  }
  return nil;
}

// Resolve a hidden-app's bundle ID from a tile-model object's PID.
// When Hider_GetBundleID and associated-object tags all fail, this is the
// last resort: extract the process ID from the delegate, look it up via
// NSRunningApplication, and check against the hidden-app list.
// On success the tile is registered for future fast-path lookups.
static NSString *Hider_ResolveBundleIDByPID(id delegate) {
  if (!delegate || g_hiddenAppBundleIDs.count == 0) return nil;

  // Guard against recursion — some selectors may trigger layout/setHidden
  // which calls back into Hider_ShouldForceHideLayer.
  static __thread BOOL in_resolve_pid = NO;
  if (in_resolve_pid) return nil;
  in_resolve_pid = YES;

  pid_t tilePID = 0;
  SEL pidSels[] = {
    NSSelectorFromString(@"processIdentifier"),
    NSSelectorFromString(@"pid"),
    NSSelectorFromString(@"_pid"),
  };
  for (int i = 0; i < 3 && tilePID <= 0; i++) {
    if ([delegate respondsToSelector:pidSels[i]])
      tilePID = (pid_t)((int (*)(id, SEL))objc_msgSend)(delegate, pidSels[i]);
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  if (tilePID <= 0) {
    SEL appSel = NSSelectorFromString(@"application");
    if ([delegate respondsToSelector:appSel]) {
      id ra = [delegate performSelector:appSel];
      if ([ra isKindOfClass:[NSRunningApplication class]])
        tilePID = [(NSRunningApplication *)ra processIdentifier];
    }
  }
  if (tilePID <= 0) {
    SEL raSel = NSSelectorFromString(@"runningApplication");
    if ([delegate respondsToSelector:raSel]) {
      id ra = [delegate performSelector:raSel];
      if ([ra isKindOfClass:[NSRunningApplication class]])
        tilePID = [(NSRunningApplication *)ra processIdentifier];
    }
  }
  if (tilePID <= 0) {
    SEL itemSel = NSSelectorFromString(@"item");
    SEL modelSel = NSSelectorFromString(@"model");
    id nested = nil;
    if ([delegate respondsToSelector:itemSel])
      nested = [delegate performSelector:itemSel];
    else if ([delegate respondsToSelector:modelSel])
      nested = [delegate performSelector:modelSel];
    if (nested) {
      for (int i = 0; i < 3 && tilePID <= 0; i++) {
        if ([nested respondsToSelector:pidSels[i]])
          tilePID = (pid_t)((int (*)(id, SEL))objc_msgSend)(nested, pidSels[i]);
      }
    }
  }
#pragma clang diagnostic pop

  if (tilePID <= 0) {
    in_resolve_pid = NO;
    return nil;
  }

  NSRunningApplication *ra =
      [NSRunningApplication runningApplicationWithProcessIdentifier:tilePID];
  if (!ra || !ra.bundleIdentifier) {
    in_resolve_pid = NO;
    return nil;
  }

  NSString *normalized = Hider_NormalizeBundleID(ra.bundleIdentifier);
  if (!normalized || !Hider_IsCustomHiddenApp(normalized)) {
    in_resolve_pid = NO;
    return nil;
  }

  LOG_TO_FILE("ResolveBundleIDByPID: %s pid=%d → %@",
              class_getName([delegate class]), (int)tilePID, normalized);
  Hider_RegisterTile(delegate, normalized);
  in_resolve_pid = NO;
  return normalized;
}

static BOOL Hider_ShouldForceHideLayer(CALayer *layer) {
  NSString *bid = Hider_ResolveBundleIDForLayer(layer);
  if (bid) {
    if (Hider_IsFinder(bid) && g_finderHidden) return YES;
    if (Hider_IsTrash(bid) && g_trashHidden)   return YES;
    if (Hider_IsCustomHiddenApp(bid))           return YES;
  }
  if (g_hideSeparators && Hider_IsSeparatorTileLayer(layer)) return YES;

  // PID fallback: when all bundle-ID resolution failed, extract the PID
  // from the tile delegate and check against running hidden apps.  This is
  // the path that catches DOCKProcessTile instances (running-only apps)
  // whose tile model doesn't expose a bundle ID via standard selectors.
  if (!bid && g_hiddenAppBundleIDs.count > 0) {
    id delegate = layer.delegate;
    if (delegate) {
      // Throttle logging to avoid spam — only log once per delegate pointer.
      static NSMutableSet *s_loggedDelegates = nil;
      if (!s_loggedDelegates) s_loggedDelegates = [NSMutableSet set];
      NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)delegate];
      if (![s_loggedDelegates containsObject:ptr]) {
        [s_loggedDelegates addObject:ptr];
        LOG_TO_FILE("ShouldForceHide PID fallback: delegate=%s for DOCKTileLayer %p",
                    class_getName([delegate class]), (__bridge void *)layer);
      }

      NSString *pidBid = Hider_ResolveBundleIDByPID(delegate);
      if (pidBid) {
        Hider_SuppressSlot(layer);
        return YES;
      }
    }
  }

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

static void Hider_UnsuppressSlot(CALayer *slot) {
  if (!slot) return;
  objc_setAssociatedObject(slot, &kHiderSlotSuppressed, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  slot.opacity = 1.0f;
  slot.hidden  = NO;
  for (CALayer *sub in Hider_SublayersSnapshot(slot)) {
    sub.opacity = 1.0f;
    sub.hidden  = NO;
  }
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

  // Source 4: every tile in g_customAppTileObjects → layer → root.
  if (g_customAppTileObjects) {
    NSArray *trackedBIDs = [g_customAppTileObjects allKeys];
    for (NSString *bid in trackedBIDs) {
      id tile = g_customAppTileObjects[bid];
      if (!tile) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      if ([tile isKindOfClass:[CALayer class]])
        addRoot((CALayer *)tile);
      else if ([tile respondsToSelector:@selector(layer)])
        addRoot([tile performSelector:@selector(layer)]);
#pragma clang diagnostic pop
    }
  }

  // Source 5: Finder / Trash tile objects → layer → root.
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

// Unified enforcement: discover tiles, suppress renders, apply visibility.
// Called from init, settings change, and launch observer.
static void Hider_EnforceHiddenApps(NSString * _Nullable singleBID, pid_t pid) {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];

  Hider_TriggerLayoutOnTrackedLayers();

  // ── Step 1: Suppress every already-tracked hidden-app tile directly. ─────
  // This fires before root-layer discovery so tiles we already know about
  // are hidden instantly regardless of layer-tree reachability.
  if (g_customAppTileObjects) {
    NSSet *snap = [g_hiddenAppBundleIDs copy];
    for (NSString *bid in snap) {
      id tile = g_customAppTileObjects[bid];
      if (tile) Hider_SuppressTileRender(tile);
    }
  }

  // ── Step 2: Collect root layers from every reachable source. ─────────────
  NSArray<CALayer *> *roots = Hider_CollectRootLayers();

  if (roots.count > 0) {
    // Build PID discovery list for untracked running hidden apps.
    NSMutableArray *discoveryBIDs = [NSMutableArray array];
    NSMutableArray *discoveryPIDs = [NSMutableArray array];

    if (singleBID && pid > 0) {
      [discoveryBIDs addObject:singleBID];
      [discoveryPIDs addObject:@(pid)];
    }

    if (g_hiddenAppBundleIDs.count > 0) {
      NSArray *running = [[NSWorkspace sharedWorkspace] runningApplications];
      for (NSRunningApplication *ra in running) {
        NSString *raBID = ra.bundleIdentifier;
        if (!raBID) continue;
        NSString *normalized = Hider_NormalizeBundleID(raBID);
        if (!normalized || ![g_hiddenAppBundleIDs containsObject:normalized])
          continue;
        if (g_customAppTileObjects[normalized] &&
            !(singleBID && [normalized isEqualToString:singleBID]))
          continue;
        pid_t raPID = ra.processIdentifier;
        if (raPID <= 0) continue;
        [discoveryBIDs addObject:normalized];
        [discoveryPIDs addObject:@(raPID)];
      }
    }

    for (CALayer *root in roots) {
      for (NSUInteger di = 0; di < discoveryBIDs.count; di++) {
        Hider_DiscoverTileByPID(root, discoveryBIDs[di],
                                (pid_t)[discoveryPIDs[di] intValue]);
      }
      Hider_ApplyVisibilityRecursive(root);
      Hider_ForceLayoutRecursive(root);
    }
  }

  // ── Step 3: Re-suppress after discovery may have registered new tiles. ───
  if (g_customAppTileObjects) {
    NSSet *snap = [g_hiddenAppBundleIDs copy];
    for (NSString *bid in snap) {
      id tile = g_customAppTileObjects[bid];
      if (tile) Hider_SuppressTileRender(tile);
    }
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
static void Hider_HotloadHiddenAppsNow(void) {
  Hider_LoadSettingsFromCache();
  if (g_hiddenAppBundleIDs.count == 0) {
    Hider_EnforceHiddenApps(nil, 0);
    return;
  }

  NSArray *running = [[NSWorkspace sharedWorkspace] runningApplications];
  for (NSRunningApplication *app in running) {
    NSString *bid = Hider_NormalizeBundleID(app.bundleIdentifier);
    if (!bid || ![g_hiddenAppBundleIDs containsObject:bid]) continue;
    pid_t appPID = app.processIdentifier;
    Hider_EnforceHiddenApps(bid, appPID);
  }

  // Also run a broad pass for any tile identities that were just rebuilt.
  Hider_EnforceHiddenApps(nil, 0);
}

// Force one hidden-running-app pass: enforce + explicit tile suppression/removal.
// This is stronger than Hider_HotloadHiddenAppsNow alone because it asks for
// tile removal on every pass if a tile object is known.
static void Hider_ForceHideRunningAppNow(NSString * _Nullable bid, pid_t pid) {
  Hider_EnforceHiddenApps(bid, pid);
  if (!bid || bid.length == 0) return;
  id tile = g_customAppTileObjects[bid];
  if (!tile) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  SEL ls = @selector(layer);
  if ([tile respondsToSelector:ls]) {
    id layerObj = [tile performSelector:ls];
    if ([layerObj isKindOfClass:[CALayer class]]) {
      CALayer *l = (CALayer *)layerObj;
      Hider_HideNeighborDecorations(l);
      Hider_HideIndicatorsRecursive(l.superlayer ? l.superlayer : l);
    }
  }
#pragma clang diagnostic pop
  Hider_SuppressTileRender(tile);
  Hider_RequestTileRemoval(tile);
}

// Force a broad hidden-app pass over all running hidden apps, including direct
// remove requests for any tile objects currently known.
static void Hider_ForceHotloadHiddenTilesNow(void) {
  Hider_HotloadHiddenAppsNow();
  if (!g_customAppTileObjects || g_hiddenAppBundleIDs.count == 0) return;
  NSSet *hiddenSnap = [g_hiddenAppBundleIDs copy];
  for (NSString *bid in hiddenSnap) {
    id tile = g_customAppTileObjects[bid];
    if (!tile) continue;
    Hider_SuppressTileRender(tile);
    Hider_RequestTileRemoval(tile);
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
static void Hider_DiscoverTileByPID(CALayer *layer, NSString *bid, pid_t pid) {
  if (!layer || pid <= 0 || !bid) return;

  NSString *cn = NSStringFromClass([layer class]);
  if ([cn isEqualToString:@"DOCKTileLayer"]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id delegate = layer.delegate;
    if (delegate) {
      BOOL match = NO;
      // Try -processIdentifier / -pid / -_pid directly on the tile model.
      SEL pidSel = NSSelectorFromString(@"processIdentifier");
      SEL pidSel2 = NSSelectorFromString(@"pid");
      SEL pidSel3 = NSSelectorFromString(@"_pid");
      SEL pidSels[] = {pidSel, pidSel2, pidSel3};
      for (int psi = 0; psi < 3 && !match; psi++) {
        if ([delegate respondsToSelector:pidSels[psi]]) {
          pid_t p = (pid_t)((int (*)(id, SEL))objc_msgSend)(delegate, pidSels[psi]);
          if (p == pid) match = YES;
        }
      }
      // Try via -application (returns NSRunningApplication).
      if (!match) {
        SEL appSel = NSSelectorFromString(@"application");
        if ([delegate respondsToSelector:appSel]) {
          id ra = [delegate performSelector:appSel];
          if ([ra isKindOfClass:[NSRunningApplication class]] &&
              [(NSRunningApplication *)ra processIdentifier] == pid)
            match = YES;
        }
      }
      // Try via -runningApplication.
      if (!match) {
        SEL raSel = NSSelectorFromString(@"runningApplication");
        if ([delegate respondsToSelector:raSel]) {
          id ra = [delegate performSelector:raSel];
          if ([ra isKindOfClass:[NSRunningApplication class]] &&
              [(NSRunningApplication *)ra processIdentifier] == pid)
            match = YES;
        }
      }
      // Try delegate.item / delegate.model -> processIdentifier / pid.
      if (!match) {
        SEL itemSel = NSSelectorFromString(@"item");
        SEL modelSel = NSSelectorFromString(@"model");
        id nested = nil;
        if ([delegate respondsToSelector:itemSel])
          nested = [delegate performSelector:itemSel];
        else if ([delegate respondsToSelector:modelSel])
          nested = [delegate performSelector:modelSel];
        if (nested) {
          for (int psi = 0; psi < 3 && !match; psi++) {
            if ([nested respondsToSelector:pidSels[psi]]) {
              pid_t p = (pid_t)((int (*)(id, SEL))objc_msgSend)(nested, pidSels[psi]);
              if (p == pid) match = YES;
            }
          }
        }
      }

      if (!match) {
        LOG_TO_FILE("PID no-match: delegate=%s for pid=%d bid=%@",
                    class_getName([delegate class]), (int)pid, bid);
      }

      if (match) {
        LOG_TO_FILE("PID match: registering tile delegate=%s for %@",
                    class_getName([delegate class]), bid);
        Hider_RegisterTile(delegate, bid);
        [layer removeAllAnimations];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.hidden  = YES;
        layer.opacity = 0.0f;
        for (CALayer *sub in Hider_SublayersSnapshot(layer)) {
          [sub removeAllAnimations];
          sub.hidden  = YES;
          sub.opacity = 0.0f;
        }
        [CATransaction commit];
        Hider_SuppressSlot(layer);
        // Request tile removal so the Dock actually removes it from layout.
        id tileForRemoval = delegate;
        SEL dc = NSSelectorFromString(@"doCommand:");
        SEL pc = NSSelectorFromString(@"performCommand:");
        if (![delegate respondsToSelector:dc] && ![delegate respondsToSelector:pc]) {
          id nested = nil;
          SEL itemSel = @selector(item);
          SEL modelSel = NSSelectorFromString(@"model");
          if ([delegate respondsToSelector:itemSel])
            nested = [delegate performSelector:itemSel];
          else if ([delegate respondsToSelector:modelSel])
            nested = [delegate performSelector:modelSel];
          if (nested && ([nested respondsToSelector:dc] || [nested respondsToSelector:pc]))
            tileForRemoval = nested;
        }
        Hider_RequestTileRemoval(tileForRemoval);
      }
    }
#pragma clang diagnostic pop
    return; // DOCKTileLayer has no sublayers to recurse into
  }

  for (CALayer *sub in Hider_SublayersSnapshot(layer))
    Hider_DiscoverTileByPID(sub, bid, pid);
}

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
static void Hider_SuppressTileRender(id tile) {
  if (!tile) return;

  void (^hideLayer)(CALayer *) = ^(CALayer *l) {
    if (!l) return;
    [l removeAllAnimations];
    for (CALayer *sub in Hider_SublayersSnapshot(l))
      [sub removeAllAnimations];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    l.hidden  = YES;
    l.opacity = 0.0f;
    for (CALayer *sub in Hider_SublayersSnapshot(l)) {
      sub.hidden  = YES;
      sub.opacity = 0.0f;
    }
    [CATransaction commit];
    Hider_SuppressSlot(l);
  };

  if ([tile isKindOfClass:[CALayer class]]) {
    hideLayer((CALayer *)tile);
    return;
  }
  if ([tile isKindOfClass:[NSView class]]) {
    NSView *v = (NSView *)tile;
    [v setHidden:YES];
    [v setAlphaValue:0.0];
    hideLayer(v.layer);
    return;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  SEL ls = @selector(layer);
  if ([tile respondsToSelector:ls]) {
    id l = [tile performSelector:ls];
    if ([l isKindOfClass:[CALayer class]])
      hideLayer((CALayer *)l);
  }
#pragma clang diagnostic pop
}

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

  // Also dump tracked tile info.
  [output appendString:@"=== Tracked Tiles ===\n"];
  [output appendFormat:@"g_customAppTileObjects count: %lu\n",
                       (unsigned long)g_customAppTileObjects.count];
  NSArray *trackedBIDs = [g_customAppTileObjects allKeys];
  for (NSString *bid in trackedBIDs) {
    id tile = g_customAppTileObjects[bid];
    [output appendFormat:@"  %@ → %@ (%p)\n", bid,
                         NSStringFromClass([tile class]), (void *)tile];
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

  // Separators: always automatic (hide when Trash is hidden)
  g_hideSeparators = NO;
  g_separatorMode = 2;  // Auto

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

  // Separators: always automatic (hide when Trash is hidden)
  g_hideSeparators = NO;
  g_separatorMode = 2;  // Auto

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
    // Apply to every custom-hidden app using the same CoreDock API.
    NSSet *hiddenSnap = [g_hiddenAppBundleIDs copy];
    for (NSString *bid in hiddenSnap) {
      CoreDockSetTileHidden((__bridge CFStringRef)bid, YES);
    }
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

  // Step 2: un-suppress apps that were removed from the hidden list.
  if (g_prevHiddenAppBundleIDs && g_customAppTileObjects) {
    NSSet *prevSnap = [g_prevHiddenAppBundleIDs copy];
    for (NSString *bid in prevSnap) {
      if (![g_hiddenAppBundleIDs containsObject:bid]) {
        id tile = g_customAppTileObjects[bid];
        if (!tile) continue;
        // Clear the associated bundle-ID tag so layer hooks stop blocking.
        objc_setAssociatedObject(tile, &kHiderBundleIDTag, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Allow one fresh removal command if this tile is hidden again later.
        objc_setAssociatedObject(tile, &kHiderCustomAppRemoveKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        SEL ls = @selector(layer);
        if ([tile respondsToSelector:ls]) {
          CALayer *l = [tile performSelector:ls];
          if ([l isKindOfClass:[CALayer class]]) {
            CALayer *slot = l.superlayer;
            if (slot) Hider_UnsuppressSlot(slot);
          }
        }
#pragma clang diagnostic pop
        [g_customAppTileObjects removeObjectForKey:bid];
      }
    }
  }

  // Step 3: suppress + schedule removal for every hidden app.
  if (g_hiddenAppBundleIDs.count > 0 && g_customAppTileObjects) {
    NSSet *hiddenSnap = [g_hiddenAppBundleIDs copy];
    for (NSString *bid in hiddenSnap) {
      id tile = g_customAppTileObjects[bid];
      if (tile) Hider_SuppressTileRender(tile);
    }
  }

  if (g_hiddenAppBundleIDs.count > 0) {
    NSSet *hiddenSnap = [g_hiddenAppBundleIDs copy];
    void (^removeTiles)(void) = ^{
      if (!g_customAppTileObjects) return;
      for (NSString *bid in hiddenSnap) {
        id tile = g_customAppTileObjects[bid];
        if (!tile) continue;
        LOG_TO_FILE("Hider_RefreshDock: removing tile for %@", bid);
        Hider_RequestTileRemoval(tile);
      }
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), removeTiles);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), removeTiles);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), removeTiles);
  }
  g_prevHiddenAppBundleIDs = [g_hiddenAppBundleIDs copy];

  // ── Notify Dock to reconcile ─────────────────────────────────────────────
  Hider_PostDockPrefsChangedNotification();

  // Unified enforcement passes at 0, 100, 300, 600 ms.
  void (^applyPass)(void) = ^{
    Hider_EnforceHiddenApps(nil, 0);
  };

  dispatch_async(dispatch_get_main_queue(), applyPass);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), applyPass);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), applyPass);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), applyPass);

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
      applyPass();
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

      if ([NSStringFromClass([self class]) isEqualToString:@"DOCKTileLayer"]) {
        if (Hider_ShouldForceHideLayer((CALayer *)self)) {
          [(CALayer *)self setHidden:YES];
          [(CALayer *)self setOpacity:0.0f];
          Hider_SuppressSlot((CALayer *)self);
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
      else if (Hider_IsCustomHiddenApp(bundleID))         forceHide = YES;
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
          else if (Hider_IsCustomHiddenApp(bid))            forceZero = YES;
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
    if (!bundleID) bundleID = Hider_ResolveBundleIDByPID(self);

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
    } else if (bundleID && !Hider_IsTrash(bundleID)) {
      Hider_RegisterTile(self, bundleID);

      if (Hider_IsCustomHiddenApp(bundleID)) {
        Hider_SuppressTileRender(self);
        Hider_RequestTileRemoval(self);
      }
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
      if (!bundleID) bundleID = Hider_ResolveBundleIDByPID(self);
      if (bundleID && Hider_IsFinder(bundleID)) {
        g_finderTileObject = self;
      } else if (bundleID && !Hider_IsTrash(bundleID)) {
        Hider_RegisterTile(self, bundleID);
        if (Hider_IsCustomHiddenApp(bundleID)) {
          Hider_SuppressTileRender(self);
          Hider_RequestTileRemoval(self);
        }
      }
    }

    if (bundleID && Hider_IsCustomHiddenApp(bundleID))
      Hider_SuppressIfHidden(self);

    return result;
  };
  class_replaceMethod(cls, updateSel, imp_implementationWithBlock(block),
                      method_getTypeEncoding(originalMethod));

  // ── DOCKFileTile lifecycle swizzles ─────────────────────────────────────
  // Same treatment as swizzleGenericAppTile: intercept every state setter and
  // void lifecycle method so the Dock cannot re-show a hidden tile when the
  // app becomes active or running.
  NSArray *ftBoolSetterNames = @[
    @"setActive:", @"setRunning:", @"setLaunching:",
    @"setShowsIndicator:", @"setIsRunning:", @"setIsActive:",
    @"setNeedsRedraw:", @"setShowIndicator:",
    @"setHighlighted:", @"setVisible:",
  ];
  for (NSString *selName in ftBoolSetterNames) {
    SEL sel = NSSelectorFromString(selName);
    if (![cls instancesRespondToSelector:sel]) continue;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) continue;
    __block IMP origIMP = method_getImplementation(method);
    __block SEL capturedSel = sel;

    void (^stateBlock)(id, BOOL) = ^(id self, BOOL val) {
      ((void (*)(id, SEL, BOOL))origIMP)(self, capturedSel, val);
      Hider_SuppressIfHidden(self);
    };

    NSString *newSelName = [NSString stringWithFormat:@"hider_ft_%@", selName];
    Hider_SwizzleInstanceMethod(cls, sel, NSSelectorFromString(newSelName),
                                imp_implementationWithBlock(stateBlock));
  }

  NSArray *ftVoidMethodNames = @[
    @"updateRunningIndicator", @"_updateRunningIndicator",
    @"updateIndicator", @"_updateIndicator",
    @"updateVisibility", @"_updateVisibility",
    @"display", @"_display",
    @"updateIconImage", @"_updateIconImage",
    @"redisplay",
  ];
  for (NSString *selName in ftVoidMethodNames) {
    SEL sel = NSSelectorFromString(selName);
    if (![cls instancesRespondToSelector:sel]) continue;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) continue;
    __block IMP origIMP = method_getImplementation(method);
    __block SEL capturedSel = sel;

    void (^voidBlock)(id) = ^(id self) {
      ((void (*)(id, SEL))origIMP)(self, capturedSel);
      Hider_SuppressIfHidden(self);
    };

    NSString *newSelName = [NSString stringWithFormat:@"hider_ft_v_%@", selName];
    Hider_SwizzleInstanceMethod(cls, sel, NSSelectorFromString(newSelName),
                                imp_implementationWithBlock(voidBlock));
  }
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
static void Hider_RequestTileRemoval(id tile) {
  if (!tile) return;
  Hider_RunOnce(tile, &kHiderCustomAppRemoveKey, ^{
    __weak id weakTile = tile;
    int64_t delays[] = {0, 80, 250, 900};
    for (int i = 0; i < 4; i++) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delays[i] * (int64_t)NSEC_PER_MSEC),
                     dispatch_get_main_queue(), ^{
                       id t = weakTile;
                       if (!t) return;
                       Hider_SuppressTileRender(t);
                       // Keep retry passes visual-only; emit remove command once
                       // so each icon produces at most one whoosh.
                       if (i != 0) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                       SEL dc = NSSelectorFromString(@"doCommand:");
                       SEL pc = NSSelectorFromString(@"performCommand:");
                       if ([t respondsToSelector:dc])
                         ((void (*)(id, SEL, int))objc_msgSend)(t, dc, 1004);
                       else if ([t respondsToSelector:pc])
                         ((void (*)(id, SEL, int))objc_msgSend)(t, pc, 1004);
#pragma clang diagnostic pop
                     });
    }
  });
}

// Helper: if `tile` is a hidden custom app, immediately suppress and remove.
// Uses three resolution paths: associated-object tag → Hider_GetBundleID →
// PID-based fallback via Hider_ResolveBundleIDByPID.
static void Hider_SuppressIfHidden(id tile) {
  if (!tile) return;
  NSString *bid = objc_getAssociatedObject(tile, &kHiderBundleIDTag);
  if (!bid) bid = Hider_NormalizeBundleID(Hider_GetBundleID(tile));
  if (!bid) bid = Hider_ResolveBundleIDByPID(tile);
  if (!bid || !Hider_IsCustomHiddenApp(bid)) return;
  Hider_RegisterTile(tile, bid);
  Hider_SuppressTileRender(tile);
  Hider_RequestTileRemoval(tile);
}

// swizzleGenericAppTile – intercepts any DOCK tile class that isn't Finder /
// Trash / separator.  Tracks every tile unconditionally (mirrors how
// g_finderTileObject is always populated) and sends doCommand:1004 when
// the tile's bundle ID is in the custom-hidden set.
//
// In addition to the -update/-init swizzle, this function also hooks every
// lifecycle selector the Dock uses to transition tiles between inactive,
// running, active, and launching states.  Without these hooks, the Dock's
// own state machinery re-shows the tile icon whenever the app becomes active
// or starts running — even if we previously suppressed it.
static void swizzleGenericAppTile(Class cls) {
  SEL updateSel = NSSelectorFromString(@"update");
  if (![cls instancesRespondToSelector:updateSel])
    updateSel = @selector(init);

  Method m = class_getInstanceMethod(cls, updateSel);
  if (!m)
    return;
  __block IMP orig = method_getImplementation(m);

  id (^block)(id) = ^id(id self) {
    NSString *bundleID = Hider_GetBundleID(self);
    // PID fallback when Hider_GetBundleID can't resolve the bundle ID.
    if (!bundleID) bundleID = Hider_ResolveBundleIDByPID(self);

    if (bundleID && !Hider_IsFinder(bundleID) && !Hider_IsTrash(bundleID)) {
      Hider_RegisterTile(self, bundleID);
      // Pre-original: only attempt suppression when layer already exists.
      if (Hider_IsCustomHiddenApp(bundleID)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        SEL ls = @selector(layer);
        if ([self respondsToSelector:ls]) {
          id l = [self performSelector:ls];
          if ([l isKindOfClass:[CALayer class]])
            Hider_SuppressTileRender(self);
        }
#pragma clang diagnostic pop
      }
    }

    id result = nil;
    if (updateSel == @selector(init))
      result = ((id(*)(id, SEL))orig)(self, updateSel);
    else
      ((void (*)(id, SEL))orig)(self, updateSel);

    // Post-original: resolve identity again and enforce in same stack frame.
    bundleID = Hider_GetBundleID(self);
    if (!bundleID) bundleID = Hider_ResolveBundleIDByPID(self);
    if (bundleID && !Hider_IsFinder(bundleID) && !Hider_IsTrash(bundleID)) {
      Hider_RegisterTile(self, bundleID);
      if (Hider_IsCustomHiddenApp(bundleID)) {
        Hider_SuppressTileRender(self);
        Hider_RequestTileRemoval(self);
      }
    }

    if (bundleID && Hider_IsCustomHiddenApp(bundleID))
      Hider_SuppressIfHidden(self);

    return result;
  };
  class_replaceMethod(cls, updateSel, imp_implementationWithBlock(block),
                      method_getTypeEncoding(m));

  // Identity getters (critical for DOCKProcessTile): when Dock resolves tile
  // identity via bundleIdentifier/fileURL, immediately apply hide/removal.
  SEL bundleIDSel = @selector(bundleIdentifier);
  if ([cls instancesRespondToSelector:bundleIDSel]) {
    Method bidMethod = class_getInstanceMethod(cls, bundleIDSel);
    if (bidMethod) {
      __block IMP origBid = method_getImplementation(bidMethod);
      id (^bidBlock)(id) = ^id(id self) {
        id value = ((id (*)(id, SEL))origBid)(self, bundleIDSel);
        if ([value isKindOfClass:[NSString class]]) {
          NSString *bid = Hider_NormalizeBundleID((NSString *)value);
          if (bid.length > 0) {
            Hider_RegisterTile(self, bid);
            if (Hider_IsCustomHiddenApp(bid)) {
              Hider_SuppressTileRender(self);
              Hider_RequestTileRemoval(self);
            }
          }
        }
        return value;
      };
      Hider_SwizzleInstanceMethod(
          cls, bundleIDSel, NSSelectorFromString(@"hider_generic_bundleIdentifier"),
          imp_implementationWithBlock(bidBlock));
    }
  }

  SEL fileURLSel = @selector(fileURL);
  if ([cls instancesRespondToSelector:fileURLSel]) {
    Method urlMethod = class_getInstanceMethod(cls, fileURLSel);
    if (urlMethod) {
      __block IMP origURL = method_getImplementation(urlMethod);
      id (^urlBlock)(id) = ^id(id self) {
        id value = ((id (*)(id, SEL))origURL)(self, fileURLSel);
        if ([value isKindOfClass:[NSURL class]]) {
          NSBundle *b = [NSBundle bundleWithURL:(NSURL *)value];
          NSString *bid = Hider_NormalizeBundleID(b.bundleIdentifier);
          if (bid.length > 0) {
            Hider_RegisterTile(self, bid);
            if (Hider_IsCustomHiddenApp(bid)) {
              Hider_SuppressTileRender(self);
              Hider_RequestTileRemoval(self);
            }
          }
        }
        return value;
      };
      Hider_SwizzleInstanceMethod(
          cls, fileURLSel, NSSelectorFromString(@"hider_generic_fileURL"),
          imp_implementationWithBlock(urlBlock));
    }
  }

  // ── Lifecycle swizzles ──────────────────────────────────────────────────
  // Hook every BOOL-taking state setter that the Dock uses to bring a tile
  // back to life when the app becomes active/running/launching.  After
  // calling through to the original, we immediately re-suppress the tile.
  NSArray *boolSetterNames = @[
    @"setActive:", @"setRunning:", @"setLaunching:",
    @"setShowsIndicator:", @"setIsRunning:", @"setIsActive:",
    @"setNeedsRedraw:", @"setShowIndicator:",
    @"setHighlighted:", @"setVisible:",
  ];
  for (NSString *selName in boolSetterNames) {
    SEL sel = NSSelectorFromString(selName);
    if (![cls instancesRespondToSelector:sel]) continue;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) continue;
    __block IMP origIMP = method_getImplementation(method);
    __block SEL capturedSel = sel;

    void (^stateBlock)(id, BOOL) = ^(id self, BOOL val) {
      ((void (*)(id, SEL, BOOL))origIMP)(self, capturedSel, val);
      Hider_SuppressIfHidden(self);
    };

    NSString *newSelName = [NSString stringWithFormat:@"hider_generic_%@", selName];
    Hider_SwizzleInstanceMethod(cls, sel, NSSelectorFromString(newSelName),
                                imp_implementationWithBlock(stateBlock));
  }

  // Hook void-returning no-arg lifecycle methods that rebuild tile visuals.
  NSArray *voidMethodNames = @[
    @"updateRunningIndicator", @"_updateRunningIndicator",
    @"updateIndicator", @"_updateIndicator",
    @"updateVisibility", @"_updateVisibility",
    @"display", @"_display",
    @"updateIconImage", @"_updateIconImage",
    @"redisplay",
  ];
  for (NSString *selName in voidMethodNames) {
    SEL sel = NSSelectorFromString(selName);
    if (![cls instancesRespondToSelector:sel]) continue;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) continue;
    __block IMP origIMP = method_getImplementation(method);
    __block SEL capturedSel = sel;

    void (^voidBlock)(id) = ^(id self) {
      ((void (*)(id, SEL))origIMP)(self, capturedSel);
      Hider_SuppressIfHidden(self);
    };

    NSString *newSelName = [NSString stringWithFormat:@"hider_generic_v_%@", selName];
    Hider_SwizzleInstanceMethod(cls, sel, NSSelectorFromString(newSelName),
                                imp_implementationWithBlock(voidBlock));
  }

  // One-time: dump interesting selectors for DOCKProcessTile so we can see
  // how it exposes PID/bundleID at runtime.
  if (strcmp(class_getName(cls), "DOCKProcessTile") == 0) {
    NSArray *probeNames = @[
      @"processIdentifier", @"pid", @"_pid",
      @"bundleIdentifier", @"bundleID", @"_bundleID",
      @"application", @"runningApplication",
      @"item", @"model", @"objectValue",
      @"url", @"fileURL", @"URL",
      @"setActive:", @"setRunning:", @"setLaunching:",
      @"update", @"init",
      @"applicationBundleIdentifier", @"appBundleID",
    ];
    NSMutableString *found = [NSMutableString string];
    for (NSString *s in probeNames) {
      if ([cls instancesRespondToSelector:NSSelectorFromString(s)])
        [found appendFormat:@" %@", s];
    }
    LOG_TO_FILE("DOCKProcessTile selectors:%@", found);
  }

  LOG_TO_FILE("swizzleGenericAppTile: %s", class_getName(cls));
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
      } else if (strstr(name, "Tile") != NULL &&
                 !strstr(name, "TileLayer")) {
        // Catch all remaining DOCK tile classes — DOCKApplicationTile,
        // DOCKURLTile, DOCKRunningAppTile, etc. — for custom hidden-app
        // tracking.  The already-handled classes above are excluded by the
        // if/else chain so there is no double-swizzle risk.
        LOG_TO_FILE("Swizzling generic tile class: %s", name);
        swizzleGenericAppTile(classes[i]);
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

                // Hidden-app list must hotload immediately (same expectation as
                // Finder/Trash toggles): apply now + short retries to catch
                // async Dock model/layout churn.
                void (^hotloadPass)(void) = ^{
                  Hider_ForceHotloadHiddenTilesNow();
                };
                dispatch_async(dispatch_get_main_queue(), hotloadPass);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), hotloadPass);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), hotloadPass);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), hotloadPass);
              });
        });

    // Hidden app added — apply immediately (no debounce), same as Finder/Trash hide.
    int hiddenAppAddedToken;
    notify_register_dispatch(
        "com.aspauldingcode.hider.hiddenAppAdded", &hiddenAppAddedToken,
        dispatch_get_main_queue(), ^(__unused int t) {
          LOG_TO_FILE("Hidden app added — applying immediately");
          Hider_LoadSettings();
          // Mirror Finder/Trash immediate refresh path.
          Hider_HideFinderIcon((Boolean)g_finderHidden);
          Hider_HideTrashIcon((Boolean)g_trashHidden);
          // Retry passes mirror launch handling so already-running apps are
          // hidden even when Dock model/layers are still converging.
          void (^hotloadPass)(void) = ^{
            Hider_ForceHotloadHiddenTilesNow();
          };
          dispatch_async(dispatch_get_main_queue(), hotloadPass);
          int64_t retryMs[] = {25, 75, 150, 300, 600, 1000};
          for (int i = 0; i < 6; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, retryMs[i] * (int64_t)NSEC_PER_MSEC),
                           dispatch_get_main_queue(), hotloadPass);
          }
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

    // Watch for app launches: hidden apps must be suppressed immediately.
    // Uses Hider_EnforceHiddenApps (which does PID discovery + _rootLayer
    // fallback + layer suppression + slot tagging) on an aggressive schedule
    // so the icon never visually appears, even briefly.
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceDidLaunchApplicationNotification
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
          NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
          NSString *bid = app.bundleIdentifier;
          Hider_LoadSettingsFromCache();
          if (!bid || !Hider_IsCustomHiddenApp(bid)) return;

          LOG_TO_FILE("Hidden app launched: %@", bid);
          NSString *normalized = Hider_NormalizeBundleID(bid);
          pid_t appPID = app.processIdentifier;

          // Synchronous pass first, then progressive retries.
          Hider_ForceHideRunningAppNow(normalized, appPID);
          int64_t delays[] = {0, 25, 75, 200, 500, 900, 1500};
          for (int di = 0; di < 7; di++) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, delays[di] * (int64_t)NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{
                  Hider_ForceHideRunningAppNow(normalized, appPID);
                });
          }

          // Tile removal — after any launch animation is complete.
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                Hider_ForceHideRunningAppNow(normalized, appPID);
              });
        }];

    // Watch for app activations: when a hidden app becomes the active
    // (frontmost) app, the Dock normally re-shows its tile and indicator.
    // Re-suppress immediately so the tile never visually reappears.
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceDidActivateApplicationNotification
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
          NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
          NSString *bid = app.bundleIdentifier;
          Hider_LoadSettingsFromCache();
          if (!bid || !Hider_IsCustomHiddenApp(bid)) return;

          LOG_TO_FILE("Hidden app activated: %@", bid);
          NSString *normalized = Hider_NormalizeBundleID(bid);
          pid_t appPID = app.processIdentifier;

          int64_t delays[] = {0, 50, 150, 400};
          for (int di = 0; di < 4; di++) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, delays[di] * (int64_t)NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{
                  Hider_ForceHideRunningAppNow(normalized, appPID);
                });
          }
        }];

    // Watch for app deactivations: the Dock updates indicator state when an
    // app resigns active status.  Re-suppress so indicator dots don't creep
    // back in for hidden apps.
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceDidDeactivateApplicationNotification
        object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
          NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
          NSString *bid = app.bundleIdentifier;
          Hider_LoadSettingsFromCache();
          if (!bid || !Hider_IsCustomHiddenApp(bid)) return;

          NSString *normalized = Hider_NormalizeBundleID(bid);
          pid_t appPID = app.processIdentifier;
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
              dispatch_get_main_queue(), ^{
                Hider_ForceHideRunningAppNow(normalized, appPID);
              });
        }];

    LOG_TO_FILE("Hider_Init: complete");
  }
}

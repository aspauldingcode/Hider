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
static BOOL g_coreDockLoaded = NO;
static void *g_coreDockHandle = NULL;

// Helper functions
NSString *Hider_GetBundleID(id obj);
BOOL Hider_IsFinder(NSString *bundleID);
BOOL Hider_IsTrash(NSString *bundleID);
BOOL Hider_IsSeparatorTileLayer(id obj);

// Execution guard
void Hider_RunOnce(id object, const void *key, void (^block)(void));

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
    // Try delegate's bundleIdentifier
    if ([currentObj respondsToSelector:@selector(delegate)]) {
      id delegate = [currentObj performSelector:@selector(delegate)];
      if (delegate &&
          [delegate respondsToSelector:@selector(bundleIdentifier)]) {
        bundleID = [delegate performSelector:@selector(bundleIdentifier)];
        if (bundleID)
          goto found;
      }
    }

    // Try representedObject
    if ([currentObj respondsToSelector:@selector(representedObject)]) {
      id representedObject =
          [currentObj performSelector:@selector(representedObject)];
      if (representedObject &&
          [representedObject respondsToSelector:@selector(bundleIdentifier)]) {
        bundleID =
            [representedObject performSelector:@selector(bundleIdentifier)];
        if (bundleID)
          goto found;
      }
    }

    // Try description matching
    NSString *desc = [currentObj description];
    if (desc) {
      if ([desc containsString:@"com.apple.finder"]) {
        bundleID = @"com.apple.finder";
        goto found;
      } else if ([desc containsString:@"com.apple.trash"] ||
                 [desc containsString:@"Trash"]) {
        bundleID = @"com.apple.trash";
        goto found;
      }
    }

    // Traverse up
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
      id d = [current performSelector:@selector(delegate)];
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

#pragma mark - Floor Layer Hiding

static void Hider_HideFloorSeparators(CALayer *layer) {
  if (!layer)
    return;

  // separatorMode: 0=keep, 1=remove, 2=auto
  if (g_separatorMode == 0 && !g_hideSeparators) {
    return; 
  }

  BOOL hideAll = g_hideSeparators || (g_separatorMode == 1);
  
  // Automatic logic suggested by Salty (@ogui-775):
  // "if a user removes trash icon, the separator which would separate the trash icon 
  // and the other icons would be removed, and if all items are removed from dock, 
  // no separators will be there."
  
  if (g_separatorMode == 2) {
    // If all items removed (Finder and Trash can be hidden, plus maybe others?)
    // For now we focus on the separator between apps and trash/folders
    if (g_trashHidden) {
       // Logic to find the specific separator adjacent to trash.
       // Usually Dock has one or two main separators.
       // We'll hide small width layers as a catch-all if they meet the condition.
    }
  }

  for (CALayer *sub in layer.sublayers) {
    if (sub.frame.size.width > 0 && sub.frame.size.width < 15) {
      BOOL shouldHide = hideAll;
      
      if (g_separatorMode == 2) {
          // In Auto mode, we hide separators if they seem "extra"
          // If trash is hidden, we hide the separator.
          if (g_trashHidden) {
              shouldHide = YES;
          }
      }
      
      if (shouldHide) {
        if (!sub.hidden) {
          LOG_TO_FILE("Hiding separator by width (%f): %@", sub.frame.size.width,
                      NSStringFromClass([sub class]));
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

void Hider_RunOnce(id object, const void *key, void (^block)(void)) {
  if (!object || !key || !block)
    return;

  if (!objc_getAssociatedObject(object, key)) {
    objc_setAssociatedObject(object, key, @(YES),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    block();
  }
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
  LOG_TO_FILE("Found %lu windows via [NSApp windows]",
              (unsigned long)windows.count);

  NSMutableArray *allWindows = [NSMutableArray arrayWithArray:windows];

  // Try to find more windows via windowNumbers
  if ([NSWindow respondsToSelector:@selector(windowNumbersWithOptions:)]) {
    NSArray *nums =
        [NSWindow performSelector:@selector(windowNumbersWithOptions:)
                       withObject:@0];
    for (NSNumber *n in nums) {
      NSWindow *w = [NSApp windowWithWindowNumber:[n integerValue]];
      if (w && ![allWindows containsObject:w]) {
        [allWindows addObject:w];
      }
    }
  }

  LOG_TO_FILE("Total windows to dump: %lu", (unsigned long)allWindows.count);

  for (NSWindow *window in allWindows) {
    NSString *className = NSStringFromClass([window class]);
    [output appendFormat:@"Window: %@ (%p) [%@]\n", window.title,
                         (void *)window, className];
    [output appendString:@"----------------------------------------\n"];

    // Check contentView layer
    CALayer *rootLayer = window.contentView.layer;
    if (rootLayer) {
      [output appendString:@"Root: contentView.layer\n"];
      Hider_DumpLayer(rootLayer, 0, output);
    } else {
      // Try the rootLayer of the window itself if it exists (private)
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

    // Also try to find layers in subviews
    if (!rootLayer && window.contentView) {
      [output appendString:@"  No root CALayer found. Searching subviews...\n"];
      NSMutableArray *queue =
          [NSMutableArray arrayWithObject:window.contentView];
      while (queue.count > 0) {
        NSView *v = [queue firstObject];
        [queue removeObjectAtIndex:0];
        if (v.layer) {
          [output appendFormat:@"Found layer in view %@ (%p):\n",
                               NSStringFromClass([v class]), (void *)v];
          Hider_DumpLayer(v.layer, 1, output);
        }
        if (v.subviews.count > 0) {
          [queue addObjectsFromArray:v.subviews];
        }
      }
    }

    [output appendString:@"\n"];
  }

  NSError *error = nil;
  // Use a more accessible path too
  [output writeToFile:@"/tmp/dock_layer_dump.txt"
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:&error];

  // Also write to current directory if possible, but we don't know it easily.
  // We'll stick to /tmp for now as it's standard for tweaks.

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
  
  // Use CFPreferences to read from our domain
  CFPreferencesAppSynchronize(CFSTR("com.aspauldingcode.hider"));
  
  Boolean keyExists = false;
  
  g_finderHidden = (BOOL)CFPreferencesGetAppBooleanValue(CFSTR("hideFinder"), CFSTR("com.aspauldingcode.hider"), &keyExists);
  if (!keyExists) g_finderHidden = NO;
  
  g_trashHidden = (BOOL)CFPreferencesGetAppBooleanValue(CFSTR("hideTrash"), CFSTR("com.aspauldingcode.hider"), &keyExists);
  if (!keyExists) g_trashHidden = NO;
  
  g_hideSeparators = (BOOL)CFPreferencesGetAppBooleanValue(CFSTR("hideSeparators"), CFSTR("com.aspauldingcode.hider"), &keyExists);
  if (!keyExists) g_hideSeparators = NO;
  
  CFIndex mode = CFPreferencesGetAppIntegerValue(CFSTR("separatorMode"), CFSTR("com.aspauldingcode.hider"), &keyExists);
  if (!keyExists) g_separatorMode = 2; // Auto
  else g_separatorMode = (int)mode;
  
  LOG_TO_FILE("Settings: Finder=%d, Trash=%d, Separators=%d, Mode=%d", 
              g_finderHidden, g_trashHidden, g_hideSeparators, g_separatorMode);
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

  g_coreDockHandle = dlopen("/System/Library/Frameworks/"
                            "ApplicationServices.framework/ApplicationServices",
                            RTLD_LAZY);
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

  g_coreDockLoaded =
      (CoreDockSetTileHidden != NULL && CoreDockIsTileHidden != NULL);
  return g_coreDockLoaded;
}

#pragma mark - Helper Functions

static void Hider_RefreshDock(void) {
  LOG_TO_FILE("Refreshing Dock state...");
  if (!Hider_LoadCoreDockFunctions())
    return;
    
  // Explicitly set visibility via CoreDock
  if (CoreDockSetTileHidden) {
    CoreDockSetTileHidden(kCoreDockFinderBundleID, (Boolean)g_finderHidden);
    CoreDockSetTileHidden(kCoreDockTrashBundleID, (Boolean)g_trashHidden);
  }

  // Notify Dock of preference changes
  if (CoreDockSendNotification) {
    CoreDockSendNotification(kCoreDockNotificationDockChanged, NULL);
    CoreDockSendNotification(kCoreDockNotificationPreferencesChanged, NULL);
  }
    
  if (CoreDockRefreshTile) {
    CoreDockRefreshTile(kCoreDockFinderBundleID);
    CoreDockRefreshTile(kCoreDockTrashBundleID);
    // Refresh all tiles just in case
    CoreDockRefreshTile(NULL);
  }

  // Immediate force layout pass on all layers in all windows
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        void (^forceLayout)(CALayer *) = ^(CALayer *l) {
            [l setNeedsLayout];
            [l setNeedsDisplay];
            for (CALayer *sub in l.sublayers) {
                [sub setNeedsLayout];
                [sub setNeedsDisplay];
                if ([NSStringFromClass([sub class]) containsString:@"Floor"]) {
                    Hider_HideFloorSeparators(sub);
                }
            }
        };
        forceLayout(root);
      }
    }
  });
}

static void Hider_HideFinderIcon(Boolean hide) {
  g_finderHidden = (BOOL)hide;
  if (!Hider_LoadCoreDockFunctions())
    return;
  if (CoreDockSetTileHidden)
    CoreDockSetTileHidden(kCoreDockFinderBundleID, hide);
  Hider_RefreshDock();
}

static void Hider_HideTrashIcon(Boolean hide) {
  g_trashHidden = (BOOL)hide;
  if (!Hider_LoadCoreDockFunctions())
    return;
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

  // setHidden:
  SEL setHiddenSel = @selector(setHidden:);
  Method originalSetHidden = class_getInstanceMethod(cls, setHiddenSel);
  if (originalSetHidden) {
    __block IMP originalIMP = method_getImplementation(originalSetHidden);
    void (^block)(id, BOOL) = ^(id self, BOOL hidden) {
      Hider_RunOnce(self, "Hider_setHidden_Recurse", ^{
        NSString *bundleID = Hider_GetBundleID(self);
        if (bundleID && (Hider_IsFinder(bundleID) || Hider_IsTrash(bundleID))) {
          // Force removal command if needed
          if ([self respondsToSelector:@selector(delegate)]) {
            id delegate = [self performSelector:@selector(delegate)];
            SEL performCommandSel = NSSelectorFromString(@"performCommand:");
            if (delegate && [delegate respondsToSelector:performCommandSel]) {
              // 1004 = REMOVE_FROM_DOCK
              // We use performSelector with integer via objc_msgSend
              ((void (*)(id, SEL, int))objc_msgSend)(delegate,
                                                     performCommandSel, 1004);
            }
          }
          // Force hide call
          ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, YES);
          return;
        }
      });

      // Recursion guard for re-entrant calls
      static __thread BOOL in_swizzle = NO;
      if (in_swizzle) {
        ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, hidden);
        return;
      }
      in_swizzle = YES;

      NSString *bundleID = Hider_GetBundleID(self);
      BOOL forceHide =
          (bundleID && (Hider_IsFinder(bundleID) || Hider_IsTrash(bundleID))) ||
          Hider_IsSeparatorTileLayer(self);
      if (forceHide)
        ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, YES);
      else
        ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, hidden);
      in_swizzle = NO;
    };
    Hider_SwizzleInstanceMethod(cls, setHiddenSel,
                                NSSelectorFromString(@"hider_setHidden:"),
                                imp_implementationWithBlock(block));
  }

  // setOpacity:
  SEL setOpacitySel = @selector(setOpacity:);
  Method originalSetOpacity = class_getInstanceMethod(cls, setOpacitySel);
  if (originalSetOpacity) {
    __block IMP originalIMP = method_getImplementation(originalSetOpacity);
    void (^block)(id, float) = ^(id self, float opacity) {
      NSString *bundleID = Hider_GetBundleID(self);
      BOOL forceZero =
          (bundleID && (Hider_IsFinder(bundleID) || Hider_IsTrash(bundleID))) ||
          Hider_IsSeparatorTileLayer(self);
      if (forceZero)
        ((void (*)(id, SEL, float))originalIMP)(self, setOpacitySel, 0.0f);
      else
        ((void (*)(id, SEL, float))originalIMP)(self, setOpacitySel, opacity);
    };
    Hider_SwizzleInstanceMethod(cls, setOpacitySel,
                                NSSelectorFromString(@"hider_setOpacity:"),
                                imp_implementationWithBlock(block));
  }

  // drawInContext: (CG based hiding)
  SEL drawInContextSel = @selector(drawInContext:);
  Method originalDrawInContext = class_getInstanceMethod(cls, drawInContextSel);
  if (originalDrawInContext) {
    __block IMP originalIMP = method_getImplementation(originalDrawInContext);
    void (^block)(id, CGContextRef) = ^(id self, CGContextRef ctx) {
      if (Hider_IsSeparatorTileLayer(self)) {
        // Use CG to clear the context completely
        CGRect rect = CGContextGetClipBoundingBox(ctx);
        CGContextClearRect(ctx, rect);
        return;
      }
      ((void (*)(id, SEL, CGContextRef))originalIMP)(self, drawInContextSel,
                                                     ctx);
    };
    Hider_SwizzleInstanceMethod(cls, drawInContextSel,
                                NSSelectorFromString(@"hider_drawInContext:"),
                                imp_implementationWithBlock(block));
  }

  // layoutSublayers
  SEL layoutSublayersSel = @selector(layoutSublayers);
  Method originalLayout = class_getInstanceMethod(cls, layoutSublayersSel);
  if (originalLayout) {
    __block IMP originalLayoutIMP = method_getImplementation(originalLayout);
    void (^layoutBlock)(id) = ^(id self) {
      ((void (*)(id, SEL))originalLayoutIMP)(self, layoutSublayersSel);

      NSString *bundleID = Hider_GetBundleID(self);
      BOOL forceHide =
          (bundleID && (Hider_IsFinder(bundleID) && g_finderHidden)) ||
          (bundleID && (Hider_IsTrash(bundleID) && g_trashHidden)) ||
          (g_hideSeparators && Hider_IsSeparatorTileLayer(self));
          
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
      if ((bundleID && (Hider_IsFinder(bundleID) || Hider_IsTrash(bundleID))) ||
          Hider_IsSeparatorTileLayer(self)) {
        ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, YES);
        in_swizzle = NO;
        return;
      }
    }
    if (Hider_IsSeparatorTileLayer(self)) {
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

  SEL setOpacitySel = @selector(setOpacity:);
  Method setOpacityM = class_getInstanceMethod(cls, setOpacitySel);
  if (setOpacityM) {
    __block IMP origOp = method_getImplementation(setOpacityM);
    void (^opBlock)(id, float) = ^(id self, float op) {
      if (Hider_IsSeparatorTileLayer(self))
        ((void (*)(id, SEL, float))origOp)(self, setOpacitySel, 0.0f);
      else
        ((void (*)(id, SEL, float))origOp)(self, setOpacitySel, op);
    };
    Hider_SwizzleInstanceMethod(
        cls, setOpacitySel, NSSelectorFromString(@"hider_layer_setOpacity:"),
        imp_implementationWithBlock(opBlock));
  }

  // drawInContext: (CALayer fallback)
  SEL drawInContextSel = @selector(drawInContext:);
  Method drawInContextM = class_getInstanceMethod(cls, drawInContextSel);
  if (drawInContextM) {
    __block IMP origDraw = method_getImplementation(drawInContextM);
    void (^drawBlock)(id, CGContextRef) = ^(id self, CGContextRef ctx) {
      if (Hider_IsSeparatorTileLayer(self)) {
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

  // layoutSublayers (CALayer)
  SEL layoutSublayersSel = @selector(layoutSublayers);
  Method originalLayout = class_getInstanceMethod(cls, layoutSublayersSel);
  if (originalLayout) {
    __block IMP originalLayoutIMP = method_getImplementation(originalLayout);
    void (^layoutBlock)(id) = ^(id self) {
      ((void (*)(id, SEL))originalLayoutIMP)(self, layoutSublayersSel);

      if ([NSStringFromClass([self class]) isEqualToString:@"DOCKTileLayer"]) {
        NSString *bundleID = Hider_GetBundleID(self);
        BOOL forceHide =
            (bundleID && (Hider_IsFinder(bundleID) && g_finderHidden)) ||
            (bundleID && (Hider_IsTrash(bundleID) && g_trashHidden)) ||
            (g_hideSeparators && Hider_IsSeparatorTileLayer(self));
            
        if (forceHide) {
          [(CALayer *)self setHidden:YES];
          [(CALayer *)self setOpacity:0.0f];
        }
      } else if (g_hideSeparators && Hider_IsSeparatorTileLayer(self)) {
        [(CALayer *)self setHidden:YES];
        [(CALayer *)self setOpacity:0.0f];
      }

      // If this is a floor layer or container, refresh separators
      if ([NSStringFromClass([self class]) containsString:@"FloorLayer"] ||
          [NSStringFromClass([self class]) containsString:@"Container"]) {
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
    if ((bundleID && (Hider_IsFinder(bundleID) || Hider_IsTrash(bundleID))) ||
        Hider_IsSeparatorTileLayer(self)) {
      ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, YES);
      in_swizzle = NO;
      return;
    }
    ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, hidden);
    in_swizzle = NO;
  };
  Hider_SwizzleInstanceMethod(cls, setHiddenSel,
                              NSSelectorFromString(@"hider_view_setHidden:"),
                              imp_implementationWithBlock(block));

  SEL setAlphaSel = @selector(setAlphaValue:);
  Method setAlphaM = class_getInstanceMethod(cls, setAlphaSel);
  if (setAlphaM) {
    __block IMP origAl = method_getImplementation(setAlphaM);
    void (^alBlock)(id, CGFloat) = ^(id self, CGFloat a) {
      if (Hider_IsSeparatorTileLayer(self))
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

  // Corrected block signature: returns id, takes id
  id (^block)(id) = ^id(id self) {
    Hider_RunOnce(self, "Hider_Trash_Update", ^{
      SEL doCommandSel = NSSelectorFromString(@"doCommand:");
      if (g_trashHidden && [self respondsToSelector:doCommandSel]) {
        ((void (*)(id, SEL, int))objc_msgSend)(self, doCommandSel, 1004);
      }
    });

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

  // Corrected block signature: returns id, takes id
  id (^block)(id) = ^id(id self) {
    Hider_RunOnce(self, "Hider_Desktop_Update", ^{
      SEL doCommandSel = NSSelectorFromString(@"doCommand:");
      if (g_finderHidden && [self respondsToSelector:doCommandSel]) {
        ((void (*)(id, SEL, int))objc_msgSend)(self, doCommandSel, 1004);
      }
    });

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

  // Corrected block signature: returns id, takes id
  id (^block)(id) = ^id(id self) {
    NSString *bundleID = nil;
    if ([self respondsToSelector:@selector(bundleIdentifier)]) {
      bundleID = [self performSelector:@selector(bundleIdentifier)];
    }

    if (bundleID && Hider_IsFinder(bundleID) && g_finderHidden) {
      Hider_RunOnce(self, "Hider_FileTile_Finder", ^{
        SEL performCommandSel = NSSelectorFromString(@"performCommand:");
        if ([self respondsToSelector:performCommandSel]) {
          ((void (*)(id, SEL, int))objc_msgSend)(self, performCommandSel, 1004);
        }
      });
    }

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
    Hider_RunOnce(self, "Hider_Spacer_Remove", ^{
      /* Remove the view from hierarchy to clean up orphaned visuals */
      if ([self respondsToSelector:@selector(removeFromSuperview)])
        [self performSelector:@selector(removeFromSuperview)];
      if ([self respondsToSelector:@selector(layer)]) {
        id layer = [self performSelector:@selector(layer)];
        if (layer && [layer respondsToSelector:@selector(removeFromSuperlayer)])
          [layer performSelector:@selector(removeFromSuperlayer)];
      }

      SEL dc = NSSelectorFromString(@"doCommand:");
      SEL pc = NSSelectorFromString(@"performCommand:");
      if ([self respondsToSelector:dc])
        ((void (*)(id, SEL, int))objc_msgSend)(self, dc, 1004);
      else {
        id d = [self respondsToSelector:@selector(delegate)]
                   ? [self performSelector:@selector(delegate)]
                   : nil;
        if (d && [d respondsToSelector:pc])
          ((void (*)(id, SEL, int))objc_msgSend)(d, pc, 1004);
      }
      if (Hider_LoadCoreDockFunctions() && CoreDockSendNotification)
        CoreDockSendNotification(kCoreDockNotificationDockChanged, NULL);
    });
    if (sel == @selector(init))
      return ((id(*)(id, SEL))orig)(self, sel);
    ((void (*)(id, SEL))orig)(self, sel);
    return (id)nil;
  };
  class_replaceMethod(cls, sel, imp_implementationWithBlock(block),
                      method_getTypeEncoding(m));

  /* Force separator tiles and their views to stay hidden and zero-size */
  SEL setHiddenSel = @selector(setHidden:);
  Method setHiddenM = class_getInstanceMethod(cls, setHiddenSel);
  if (setHiddenM) {
    __block IMP origSH = method_getImplementation(setHiddenM);
    Hider_SwizzleInstanceMethod(
        cls, setHiddenSel, NSSelectorFromString(@"hider_spacer_setHidden:"),
        imp_implementationWithBlock(^(id self, BOOL h) {
          (void)h;
          ((void (*)(id, SEL, BOOL))origSH)(self, setHiddenSel, YES);
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
            (void)a;
            ((void (*)(id, SEL, CGFloat))origSA)(self, setAlphaSel, 0.0);
          }));
    }
    /* Prevent separator from drawing */
    SEL drawRectSel = @selector(drawRect:);
    if (class_getInstanceMethod(cls, drawRectSel)) {
      Hider_SwizzleInstanceMethod(
          cls, drawRectSel, NSSelectorFromString(@"hider_spacer_drawRect:"),
          imp_implementationWithBlock(^(id self, NSRect r) {
            (void)self;
            (void)r;
            /* no-op: don't draw separator */
          }));
    }
  }

  // layoutSublayers (Spacer)
  SEL layoutSublayersSel = @selector(layoutSublayers);
  Method mLayout = class_getInstanceMethod(cls, layoutSublayersSel);
  if (mLayout) {
    __block IMP origLayout = method_getImplementation(mLayout);
    Hider_SwizzleInstanceMethod(
        cls, layoutSublayersSel, NSSelectorFromString(@"hider_spacer_layoutSublayers:"),
        imp_implementationWithBlock(^(id self) {
          ((void (*)(id, SEL))origLayout)(self, layoutSublayersSel);
          if (g_hideSeparators) {
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
    // Call original implementation first
    ((void (*)(id, SEL))originalIMP)(self, layoutSublayersSel);

    // Hide separators
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

  // Direct approach for Swift floor layers
  Class modernFloor = NSClassFromString(@"_TtC8DockCore16ModernFloorLayer");
  if (modernFloor) {
    LOG_TO_FILE("Found ModernFloorLayer via NSClassFromString");
    swizzleDOCKFloorLayer(modernFloor);
  } else {
    LOG_TO_FILE("ModernFloorLayer NOT found via NSClassFromString");
  }

  Class legacyFloor = NSClassFromString(@"_TtC8DockCore16LegacyFloorLayer");
  if (legacyFloor) {
    LOG_TO_FILE("Found LegacyFloorLayer via NSClassFromString");
    swizzleDOCKFloorLayer(legacyFloor);
  }

  unsigned int classCount = 0;
  Class *classes = objc_copyClassList(&classCount);
  LOG_TO_FILE("Scanning %u classes for Dock tiles...", classCount);

  for (unsigned int i = 0; i < classCount; i++) {
    const char *name = class_getName(classes[i]);
    if (strstr(name, "Dock") || strstr(name, "DOCK")) {
      if (strcmp(name, "DOCKTrashTile") == 0)
        swizzleDOCKTrashTile(classes[i]);
      else if (strcmp(name, "DOCKFileTile") == 0)
        swizzleDOCKFileTile(classes[i]);
      else if (strcmp(name, "DOCKProcessTile") == 0) {
        // We don't have a swizzleDOCKProcessTile yet, but keeping for completeness
      } else if (strcmp(name, "DOCKDesktopTile") == 0)
        swizzleDOCKDesktopTile(classes[i]);
      else if (strcmp(name, "DOCKSeparatorTile") == 0 ||
               strcmp(name, "DOCKSpacerTile") == 0)
        swizzleDOCKSpacerTile(classes[i]);
    }
  }
  free(classes);
}

#pragma mark - Initialization

static int tokenHideFinder, tokenShowFinder, tokenToggleFinder;
static int tokenHideTrash, tokenShowTrash, tokenToggleTrash;
static int tokenHideAll, tokenShowAll;
static int tokenDump;

__attribute__((constructor)) static void Hider_Init(void) {
  @autoreleasepool {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.apple.dock"])
      return;

    LOG_TO_FILE("Initialization: Hider Dock Tweak");

    Hider_LoadSettings();

    swizzleDockCoreClasses();

    // Fallback generic swizzles
    swizzleCALayer();
    swizzleNSView();

    // Register for settings change notification
    int settingsToken;
    notify_register_dispatch("com.aspauldingcode.hider.settingsChanged", &settingsToken,
                             dispatch_get_main_queue(), ^(__unused int t) {
                               LOG_TO_FILE("Settings changed notification received");
                               Hider_LoadSettings();
                               Hider_RefreshDock();
                             });

    // Existing notifications kept for backward compatibility or direct triggers
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

    LOG_TO_FILE("Initialization Complete");
  }
}

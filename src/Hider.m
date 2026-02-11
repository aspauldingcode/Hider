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

// Helper functions
NSString *Hider_GetBundleID(id obj);
BOOL Hider_IsFinder(NSString *bundleID);
BOOL Hider_IsTrash(NSString *bundleID);

// Execution guard
void Hider_RunOnce(id object, const void *key, void (^block)(void));

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

void Hider_RunOnce(id object, const void *key, void (^block)(void)) {
  if (!object || !key || !block)
    return;

  if (!objc_getAssociatedObject(object, key)) {
    objc_setAssociatedObject(object, key, @(YES),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    block();
  }
}

#pragma mark - Hider Logic

// Global state
static BOOL g_finderHidden = YES;
static BOOL g_trashHidden = YES;
static BOOL g_coreDockLoaded = NO;
static void *g_coreDockHandle = NULL;

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
  if (!Hider_LoadCoreDockFunctions())
    return;
  if (CoreDockSendNotification)
    CoreDockSendNotification(kCoreDockNotificationDockChanged, NULL);
  if (CoreDockRefreshTile) {
    CoreDockRefreshTile(kCoreDockFinderBundleID);
    CoreDockRefreshTile(kCoreDockTrashBundleID);
  }
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
      if (bundleID && (Hider_IsFinder(bundleID) || Hider_IsTrash(bundleID))) {
        ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, YES);
      } else {
        ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, hidden);
      }
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
      if (bundleID && (Hider_IsFinder(bundleID) || Hider_IsTrash(bundleID))) {
        ((void (*)(id, SEL, float))originalIMP)(self, setOpacitySel, 0.0f);
      } else {
        ((void (*)(id, SEL, float))originalIMP)(self, setOpacitySel, opacity);
      }
    };
    Hider_SwizzleInstanceMethod(cls, setOpacitySel,
                                NSSelectorFromString(@"hider_setOpacity:"),
                                imp_implementationWithBlock(block));
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
      if (bundleID && (Hider_IsFinder(bundleID) || Hider_IsTrash(bundleID))) {
        ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, YES);
        in_swizzle = NO;
        return;
      }
    }
    ((void (*)(id, SEL, BOOL))originalIMP)(self, setHiddenSel, hidden);
    in_swizzle = NO;
  };
  Hider_SwizzleInstanceMethod(cls, setHiddenSel,
                              NSSelectorFromString(@"hider_layer_setHidden:"),
                              imp_implementationWithBlock(block));
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
    if (bundleID && (Hider_IsFinder(bundleID) || Hider_IsTrash(bundleID))) {
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

static void swizzleDockCoreClasses(void) {
  if (NSClassFromString(@"DOCKTileLayer"))
    swizzleDOCKTileLayer();

  unsigned int classCount = 0;
  Class *classes = objc_copyClassList(&classCount);
  for (unsigned int i = 0; i < classCount; i++) {
    const char *name = class_getName(classes[i]);
    if (strstr(name, "Dock") || strstr(name, "DOCK")) {
      if (strcmp(name, "DOCKTrashTile") == 0)
        swizzleDOCKTrashTile(classes[i]);
      else if (strcmp(name, "DOCKFileTile") == 0)
        swizzleDOCKFileTile(classes[i]);
      else if (strcmp(name, "DOCKProcessTile") == 0)
        swizzleDOCKFileTile(classes[i]);
      else if (strcmp(name, "DOCKDesktopTile") == 0)
        swizzleDOCKDesktopTile(classes[i]);
    }
  }
  free(classes);
}

#pragma mark - Initialization

static int tokenHideFinder, tokenShowFinder, tokenToggleFinder;
static int tokenHideTrash, tokenShowTrash, tokenToggleTrash;
static int tokenHideAll, tokenShowAll;

__attribute__((constructor)) static void Hider_Init(void) {
  @autoreleasepool {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.apple.dock"])
      return;

    LOG_TO_FILE("Initialization: Hider Dock Tweak");

    // Initial state
    g_finderHidden = (BOOL)Hider_IsFinderIconHidden();
    g_trashHidden = (BOOL)Hider_IsTrashIconHidden();

    // Specific Dock swizzles
    swizzleDockCoreClasses();

    // Fallback generic swizzles
    swizzleCALayer();
    swizzleNSView();

    // Notifications
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
